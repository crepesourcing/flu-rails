require "securerandom"

RSpec.describe Flu::EventPublisher do
  subject(:publisher) { described_class.new(configuration) }

  let(:configuration) do
    configuration                           = Flu::Configuration.new
    configuration.logger                    = Logger.new(IO::NULL)
    configuration.rabbitmq_exchange_name    = "events"
    configuration.rabbitmq_exchange_durable = true
    configuration
  end

  let(:event) do
    Flu::Event.new(SecureRandom.uuid, "ninja_app", :entity_change, "create ninja", { "name" => "Hanzo" })
  end

  # Every session Bunny was asked to open. What happens over a real one is the integration specs' job.
  let(:sessions) { [] }

  before(:each) { allow(Bunny).to receive(:new) { open_session } }

  let(:channels) { [] }

  def open_session
    session = instance_double(Bunny::Session,
                              start:                            nil,
                              open?:                            true,
                              close:                            nil,
                              status:                           :open,
                              closed?:                          false,
                              automatically_recover?:           true,
                              recovering_from_network_failure?: false)
    allow(session).to receive(:create_channel) do
      # bunny-3.1.0 session.rb:393, and the whole reason a down connection has to be caught earlier
      raise RuntimeError, "this connection is not open." unless session.open?
      open_channel
    end
    record_recovery_callbacks(session)
    sessions.push(session)
    session
  end

  # Bunny calls the first back before each recovery attempt, and the second once it has recovered.
  let(:recovery_callbacks) { Hash.new { |callbacks, session| callbacks[session] = {} } }

  def record_recovery_callbacks(session)
    allow(session).to receive(:before_recovery_attempt_starts) { |&block| recovery_callbacks[session][:started] = block }
    allow(session).to receive(:after_recovery_completed) { |&block| recovery_callbacks[session][:completed] = block }
  end

  def open_channel
    channel = instance_double(Bunny::Channel, open?: true, close: nil)
    allow(channel).to receive(:topic) { instance_double(Bunny::Exchange, channel: channel, publish: nil) }
    channels.push(channel)
    channel
  end

  # What Bunny does to a connection it lost: it closes the channels and reopens everything later.
  def lose_the_connection
    allow(sessions.last).to receive(:open?).and_return(false)
    allow(sessions.last).to receive(:status).and_return(:disconnected)
    allow(sessions.last).to receive(:recovering_from_network_failure?).and_return(true)
    channels.each { |channel| allow(channel).to receive(:open?).and_return(false) }
  end

  # What Bunny does once the broker is back: it announces the attempt, reopens the connection, then
  # the channels it had on it, and announces it is done.
  def reopen_the_connection
    recovery_callbacks[sessions.last][:started].call
    allow(sessions.last).to receive(:open?).and_return(true)
    allow(sessions.last).to receive(:status).and_return(:open)
    allow(sessions.last).to receive(:recovering_from_network_failure?).and_return(false)
  end

  def finish_reopening_the_channels
    channels.each { |channel| allow(channel).to receive(:open?).and_return(true) }
    recovery_callbacks[sessions.last][:completed].call
  end

  # What Bunny leaves behind once it has run out of recovery attempts: a closed session it will
  # never reopen, which is then this publisher's to reopen.
  def abandon_the_connection
    lose_the_connection
    allow(sessions.last).to receive(:recovering_from_network_failure?).and_return(false)
    allow(sessions.last).to receive(:closed?).and_return(true)
    allow(sessions.last).to receive(:status).and_return(:closed)
  end

  # A session Bunny built but could not start: 'Bunny.new' answers before a single packet is sent.
  def refusing_session
    session = instance_double(Bunny::Session,
                              open?:                            false,
                              status:                           :not_connected,
                              closed?:                          false,
                              automatically_recover?:           true,
                              recovering_from_network_failure?: false)
    allow(session).to receive(:start).and_raise(Bunny::TCPConnectionFailedForAllHosts)
    record_recovery_callbacks(session)
    sessions.push(session)
    session
  end

  # The pid is all the publisher has to tell a child from the process that connected.
  def simulate_fork
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
  end

  describe "#publish" do
    context "when the publisher was never connected" do
      it "should raise a Flu error rather than a NoMethodError on nil" do
        expect { publisher.publish(event) }.to raise_error(Flu::NotConnectedError)
      end

      it "should say what has to be done about it" do
        expect { publisher.publish(event) }.to raise_error(/'connect' was never called/)
      end

      it "should mention the option that turns the automatic connection off" do
        expect { publisher.publish(event) }.to raise_error(/auto_connect_to_exchange/)
      end

      # A publisher that never connected has no pid recorded. Reading that absence as a fork connects
      # behind 'auto_connect_to_exchange = false', and retries forever when no broker answers.
      it "should not read the pid it never recorded as a fork and connect on its own" do
        expect(Bunny).to_not receive(:new)
        expect { publisher.publish(event) }.to raise_error(Flu::NotConnectedError)
      end
    end
  end

  describe "#publish when the connection is down" do
    before(:each) do
      publisher.connect
      publisher.publish(event)
      lose_the_connection
    end

    it "should raise a Flu error rather than the bare RuntimeError of 'create_channel'" do
      expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
    end

    it "should say that the connection comes back on its own" do
      expect { publisher.publish(event) }.to raise_error(/works again once it has/)
    end

    it "should not try to open a channel on it" do
      expect(sessions.last).to_not receive(:create_channel)
      expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
    end
  end

  # Bunny reopens the connection first, then the channels it had on it. In between, the connection
  # is open and the channels are not, and a channel opened there was one more on the broker for
  # good: the one Bunny was reopening was held by no thread from then on.
  describe "#publish while Bunny is reopening the channels" do
    before(:each) do
      publisher.connect
      publisher.publish(event)
      lose_the_connection
      reopen_the_connection
    end

    def publish_meanwhile
      publisher.publish(event)
    rescue Flu::ConnectionLostError
      nil
    end

    it "should raise a Flu error rather than open another channel" do
      expect(sessions.last).to_not receive(:create_channel)
      expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
    end

    it "should say that publishing works again once Bunny is done" do
      expect { publisher.publish(event) }.to raise_error(/works again once it has/)
    end

    it "should publish on the reopened channel once Bunny is done" do
      publish_meanwhile
      finish_reopening_the_channels
      publisher.publish(event)
      expect(channels.size).to eq 1
    end

    # Bunny marks the channels open, then announces it is done. A thread that read its channel
    # closed before the mark, and the announcement after, would open one more.
    it "should not open another channel when Bunny finishes during the publication" do
      allow(channels.first).to receive(:open?) { finish_reopening_the_channels; false }
      publish_meanwhile
      expect(channels.size).to eq 1
    end

    # A child process inherits the flag of a connection its parent was reopening, and opens one of
    # its own.
    it "should not hold a thread from opening a channel on the connection that replaced it" do
      simulate_fork
      publisher.publish(event)
      expect { Thread.new { publisher.publish(event) }.join }.to_not raise_error
    end

    # Bunny holds one callback of each, and the publisher's took their place.
    context "when the application gave Bunny recovery callbacks of its own in 'bunny_options'" do
      let(:calls) { [] }
      let(:configuration) do
        super().tap do |configuration|
          configuration.bunny_options = { recovery_attempt_started: -> { calls << :started },
                                          recovery_completed:       -> { calls << :completed } }
        end
      end

      it "should call them as Bunny would have" do
        finish_reopening_the_channels
        expect(calls).to eq [:started, :completed]
      end
    end
  end

  # Bunny reopens a connection only for as long as it is recovering it. Once it has run out of
  # recovery attempts, the connection it leaves behind is closed for good, and the publisher was the
  # only one left to reopen it -- which it did not, so every event from then on was lost.
  describe "#publish when Bunny has given up on the connection" do
    before(:each) do
      publisher.connect
      publisher.publish(event)
      abandon_the_connection
    end

    it "should open a new connection" do
      publisher.publish(event)
      expect(sessions.size).to eq 2
    end

    it "should publish the event" do
      expect { publisher.publish(event) }.to_not raise_error
    end

    it "should report itself connected again" do
      publisher.publish(event)
      expect(publisher).to be_connected
    end

    it "should not reopen a connection Bunny is still recovering" do
      lose_the_connection
      expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
      expect(sessions.size).to eq 1
    end

    # A broker that hangs rather than refuses costs a full Bunny 'connect_timeout' per attempt.
    it "should not pay for an attempt on every publication while the broker is unreachable" do
      allow(Bunny).to receive(:new) { refusing_session }
      3.times { expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError) }
      expect(sessions.size).to eq 2
    end
  end

  # 'connect' runs from the railtie's 'to_prepare', which runs on every code reload: waiting on a
  # broker that never answers held the reload interlock, and the request behind it, for good.
  describe "#connect when the broker does not answer" do
    before(:each) { allow(Bunny).to receive(:new) { refusing_session } }

    it "should give up after 'max_connect_wait' seconds" do
      configuration.max_connect_wait = 0
      expect { publisher.connect }.to raise_error(Flu::ConnectionLostError)
    end

    it "should say how long it waited" do
      configuration.max_connect_wait = 0
      expect { publisher.connect }.to raise_error(/within 0 seconds/)
    end

    it "should wait for as long as it takes when 'max_connect_wait' is nil" do
      configuration.max_connect_wait = nil
      allow(publisher).to receive(:sleep)
      attempts = 0
      allow(Bunny).to receive(:new) do
        attempts += 1
        attempts < 3 ? refusing_session : open_session
      end
      publisher.connect
      expect(publisher).to be_connected
    end

    it "should leave a publisher that connects on its next publication" do
      configuration.max_connect_wait = 0
      expect { publisher.connect }.to raise_error(Flu::ConnectionLostError)
      allow(Bunny).to receive(:new) { open_session }
      publisher.publish(event)
      expect(publisher).to be_connected
    end
  end

  # The connection can also drop between the moment the cached channel is found open and the moment
  # the frames are written on it.
  describe "#publish when the connection drops as the frames are written" do
    let!(:exchange) do
      publisher.connect
      publisher.send(:exchange)
    end

    it "should report Bunny's error as the same Flu error" do
      allow(exchange).to receive(:publish).and_raise(Bunny::ConnectionClosedError.new([]))
      expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
    end

    it "should keep Bunny's error as its cause" do
      allow(exchange).to receive(:publish).and_raise(Bunny::ConnectionClosedError.new([]))
      expect { publisher.publish(event) }.to raise_error { |error| expect(error.cause).to be_a Bunny::ConnectionClosedError }
    end

    # A channel the broker closed on its own -- a redeclared exchange, a precondition it refused --
    # says more about what happened than any error this gem could raise in its place.
    it "should leave the errors that are not about the connection alone" do
      allow(exchange).to receive(:publish).and_raise(Bunny::ChannelAlreadyClosed.new("closed", channels.last))
      expect { publisher.publish(event) }.to raise_error(Bunny::ChannelAlreadyClosed)
    end
  end

  describe "#connect" do
    # Both saw 'connected?' as false and connected: the second overwrote the first, left open on the
    # broker with nothing holding it to close it.
    it "should open a single connection when several threads connect at once" do
      attempts = Queue.new
      allow(Bunny).to receive(:new) do
        attempts.push(Thread.current)
        sleep 0.05 # Wide enough for the other threads to reach 'connect' while this one is in it
        open_session
      end

      4.times.map { Thread.new { publisher.connect } }.each(&:join)

      expect(attempts.size).to eq 1
    end
  end

  describe "after a fork" do
    # What a forked worker inherits: a connection, and a channel cached on the thread that forks.
    let!(:inherited_exchange) do
      publisher.connect
      publisher.send(:exchange)
    end

    before(:each) { simulate_fork }

    it "should not report itself connected" do
      expect(publisher).to_not be_connected
    end

    it "should open a connection of its own to publish" do
      publisher.publish(event)
      expect(sessions.size).to eq 2
    end

    it "should hold that new connection" do
      publisher.publish(event)
      expect(publisher.instance_variable_get(:@connection)).to be sessions.last
    end

    # The pid is recorded once for the publisher, but channels are cached per thread: another thread
    # reconnecting first makes the fork look handled, while this one still holds the parent's channel.
    it "should not publish on the channel the forking thread cached in the parent" do
      Thread.new { publisher.publish(event) }.join

      expect(inherited_exchange).to_not receive(:publish)
      publisher.publish(event)
    end

    it "should publish on a channel of the connection opened after the fork" do
      Thread.new { publisher.publish(event) }.join
      publisher.publish(event)

      expect(publisher.send(:exchange).channel).to_not be inherited_exchange.channel
    end

    context "when the broker cannot be reached from the child" do
      before(:each) { allow(Bunny).to receive(:new) { refusing_session } }

      it "should not publish on the inherited channel" do
        expect(inherited_exchange).to_not receive(:publish)
        expect { publisher.publish(event) }.to raise_error(Flu::ConnectionLostError)
      end
    end

    # The socket under an inherited connection is the parent's: closing it here closes it there too.
    it "should not close the connection it inherited" do
      expect(sessions.first).to_not receive(:close)
      publisher.disconnect
    end

    it "should let go of it all the same" do
      publisher.disconnect
      expect(publisher.instance_variable_get(:@connection)).to be_nil
    end

    it "should raise on the next publication rather than reconnecting behind the disconnection" do
      publisher.disconnect
      expect { publisher.publish(event) }.to raise_error(Flu::NotConnectedError)
    end
  end

  # A channel stays open on the broker after its thread ends, unless something closes it. RabbitMQ
  # allows 2047 per connection: a server that keeps creating and ending threads hit that limit
  # after a day, and could not publish from any new thread from then on.
  describe "the channel of a thread that has ended" do
    before(:each) { publisher.connect }

    def channel_of_a_thread_that_ended
      Thread.new { publisher.publish(event); publisher.send(:exchange).channel }.value
    end

    it "should be closed when another thread opens one" do
      ended = channel_of_a_thread_that_ended
      Thread.new { publisher.publish(event) }.join
      expect(ended).to have_received(:close)
    end

    it "should leave the channels of the threads still alive open" do
      channel_of_a_thread_that_ended
      Thread.new { publisher.publish(event) }.join
      expect(channels.first).to_not have_received(:close)
    end

    it "should not be closed again once the connection was" do
      ended = channel_of_a_thread_that_ended
      publisher.disconnect
      publisher.connect
      Thread.new { publisher.publish(event) }.join
      expect(ended).to_not have_received(:close)
    end

    it "should not cost the publication that closes it when the broker closed it first" do
      ended = channel_of_a_thread_that_ended
      allow(ended).to receive(:close).and_raise(Bunny::ChannelAlreadyClosed.new("closed", ended))
      expect { Thread.new { publisher.publish(event) }.join }.to_not raise_error
    end

    # A channel inherited from the parent process runs on the parent's socket: closing it here
    # would close it for the parent too.
    it "should not be closed when it was inherited from the parent process" do
      inherited = channel_of_a_thread_that_ended
      simulate_fork
      publisher.publish(event)
      Thread.new { publisher.publish(event) }.join
      expect(inherited).to_not have_received(:close)
    end
  end

  # 'Thread.current[]' is per fiber, not per thread. A channel stored there was opened once per
  # fiber, and never closed: every publication from an Enumerator or a streaming body leaked one.
  describe "#publish from a fiber" do
    before(:each) { publisher.connect }

    it "should publish on the channel of the thread rather than open one per fiber" do
      2.times { Fiber.new { publisher.publish(event) }.resume }
      expect(channels.size).to eq 1
    end
  end

  describe "Flu::NotConnectedError" do
    it "should be a Flu::Error" do
      expect(Flu::NotConnectedError.new).to be_a Flu::Error
    end

    it "should be a StandardError" do
      expect(Flu::NotConnectedError.new).to be_a StandardError
    end
  end

  describe "Flu::ConnectionLostError" do
    it "should be a Flu::Error" do
      expect(Flu::ConnectionLostError.new).to be_a Flu::Error
    end

    it "should be distinguishable from a publisher that was never connected" do
      expect(Flu::ConnectionLostError.new).to_not be_a Flu::NotConnectedError
    end
  end
end
