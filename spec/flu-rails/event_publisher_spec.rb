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
    session = instance_double(Bunny::Session, start: nil, open?: true, close: nil)
    allow(session).to receive(:create_channel) do
      # bunny-3.1.0 session.rb:393, and the whole reason a down connection has to be caught earlier
      raise RuntimeError, "this connection is not open." unless session.open?
      open_channel
    end
    sessions.push(session)
    session
  end

  def open_channel
    channel = instance_double(Bunny::Channel, open?: true)
    allow(channel).to receive(:topic) { instance_double(Bunny::Exchange, channel: channel, publish: nil) }
    channels.push(channel)
    channel
  end

  # What Bunny does to a connection it lost: it closes the channels and reopens everything later.
  def lose_the_connection
    allow(sessions.last).to receive(:open?).and_return(false)
    channels.each { |channel| allow(channel).to receive(:open?).and_return(false) }
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
