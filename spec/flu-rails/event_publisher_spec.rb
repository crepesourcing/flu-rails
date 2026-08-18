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

  def open_session
    session = instance_double(Bunny::Session, start: nil, open?: true, close: nil)
    allow(session).to receive(:create_channel) { open_channel }
    sessions.push(session)
    session
  end

  def open_channel
    channel = instance_double(Bunny::Channel, open?: true)
    allow(channel).to receive(:topic) { instance_double(Bunny::Exchange, channel: channel, publish: nil) }
    channel
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
end
