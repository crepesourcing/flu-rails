require "securerandom"

RSpec.describe Flu::EventPublisher, :rabbitmq do
  include_context "a rabbitmq broker"

  subject(:publisher) { described_class.new(configuration) }

  let(:event) do
    Flu::Event.new(SecureRandom.uuid,
                   "ninja_app",
                   :entity_change,
                   "create ninja",
                   { "name" => "Hanzo", "dynastyId" => 42 })
  end

  after(:each) do
    connection = publisher.instance_variable_get(:@connection)
    connection.close if connection&.open?
  end

  describe "#connect" do
    it "should declare the configured exchange" do
      publisher.connect
      expect(management_client.exchange_info("/", configuration.rabbitmq_exchange_name)).to_not be_nil
    end

    it "should declare it as a topic exchange" do
      publisher.connect
      expect(management_client.exchange_info("/", configuration.rabbitmq_exchange_name).type).to eq "topic"
    end

    it "should declare a durable exchange" do
      publisher.connect
      expect(management_client.exchange_info("/", configuration.rabbitmq_exchange_name).durable).to be true
    end

    context "when the exchange is configured as transient" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_exchange_durable: false) }

      it "should declare a transient exchange" do
        publisher.connect
        expect(management_client.exchange_info("/", configuration.rabbitmq_exchange_name).durable).to be false
      end
    end

    # The README documents reading the port from ENV, which yields a String.
    context "when the port is configured as a string" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_port: RabbitmqHelper::PORT.to_s) }

      it "should connect anyway" do
        expect { publisher.connect }.to_not raise_error
      end
    end

    context "when 'bunny_options' contradicts the other options" do
      # The port is wrong everywhere but in 'bunny_options'. Connecting at all proves that
      # 'bunny_options' is merged over the options derived from the configuration, and not the
      # other way round.
      let(:configuration) do
        RabbitmqHelper.configuration(rabbitmq_port: 1,
                                     bunny_options: { port: RabbitmqHelper::PORT })
      end

      it "should let 'bunny_options' win" do
        expect { publisher.connect }.to_not raise_error
      end
    end

    # The railtie used to call 'Flu.start' from both 'to_prepare' and 'after_initialize', which both
    # run at boot: the second call replaced '@connection' with a new one, and the first was left open
    # for the lifetime of the process, along with the channel and the heartbeat thread hanging off it.
    context "when it is already connected" do
      before(:each) { publisher.connect }

      it "should not open a second connection" do
        expect(Bunny).to_not receive(:new)
        publisher.connect
      end

      it "should keep the connection it already had" do
        first_connection = publisher.instance_variable_get(:@connection)
        publisher.connect
        expect(publisher.instance_variable_get(:@connection)).to be first_connection
      end

      it "should still publish on it" do
        queue = subscribe_to
        publisher.connect
        publisher.publish(event)
        expect(message_count_on(queue, expected: 1)).to eq 1
      end
    end

    # What the leak actually looked like on the broker: the second 'connect' overwrote '@connection',
    # so the first session stayed open with nothing referencing it any more — 'disconnect' could not
    # close what the publisher no longer held.
    it "should not leave an unreferenced session open behind it" do
      sessions = []
      allow(Bunny).to receive(:new).and_wrap_original do |original, *arguments|
        session = original.call(*arguments)
        sessions.push(session)
        session
      end

      publisher.connect
      publisher.connect
      publisher.disconnect

      expect(sessions.select(&:open?)).to be_empty
    end

    context "when the connection was closed" do
      before(:each) do
        publisher.connect
        publisher.disconnect
      end

      it "should open a new one" do
        publisher.connect
        expect(publisher).to be_connected
      end

      it "should publish on it" do
        queue = subscribe_to
        publisher.connect
        publisher.publish(event)
        expect(message_count_on(queue, expected: 1)).to eq 1
      end
    end

    context "when the credentials are refused" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_password: "not-the-password") }

      # Only a TCP failure is worth retrying: a broker that rejects the credentials will keep
      # rejecting them, so the error has to reach the application.
      it "should raise instead of retrying" do
        expect { publisher.connect }.to raise_error(Bunny::AuthenticationFailureError)
      end
    end

    context "when 'rabbitmq_vhost' points at a vhost that does not exist" do
      # 'automatically_recover' is off for the same reason 'RabbitmqHelper.connection_options'
      # turns it off for the consumer connection: the broker refuses the vhost by closing the
      # connection right after opening it, and automatic recovery would otherwise keep retrying
      # the same doomed vhost forever in a background thread instead of letting this example fail.
      let(:configuration) do
        RabbitmqHelper.configuration(rabbitmq_vhost: "flu-rails-spec-no-such-vhost",
                                     bunny_options:  { automatically_recover: false })
      end

      # The refusal is not a synchronous error from 'Bunny::Session#start': the broker closes the
      # connection right after opening it, so this only surfaces once something tries to use it,
      # here declaring the exchange's channel.
      it "should fail rather than silently falling back to the default vhost" do
        expect { publisher.connect }.to raise_error(StandardError)
      end
    end

    context "when the broker is not reachable yet" do
      let(:configuration) { RabbitmqHelper.configuration(logger: logger) }
      let(:logger)        { instance_double(Logger, debug: nil, warn: nil) }

      # A broker that comes up after the application does is the case this loop exists for. The
      # first attempts are made to fail because a broker cannot be asked to start late on demand;
      # the attempt that succeeds is a real one, against the real broker.
      it "should retry until the broker accepts the connection" do
        attempts = 0
        allow(Bunny).to receive(:new).and_wrap_original do |original, *arguments|
          attempts += 1
          raise Bunny::TCPConnectionFailedForAllHosts if attempts < 3
          original.call(*arguments)
        end
        allow(publisher).to receive(:sleep)

        publisher.connect

        expect(attempts).to eq 3
        expect(management_client.exchange_info("/", configuration.rabbitmq_exchange_name)).to_not be_nil
      end

      # 'connect' retries forever by design, so a permanently failing broker can only be observed by
      # breaking out of the sleep it makes between two attempts.
      it "should report every failed attempt" do
        allow(Bunny).to receive(:new).and_raise(Bunny::TCPConnectionFailedForAllHosts)
        slept = 0
        allow(publisher).to receive(:sleep) do
          slept += 1
          raise "give up" if slept == 2
        end

        expect(logger).to receive(:warn).with("RabbitMQ connection failed, try again in 1 second.").twice
        expect { publisher.connect }.to raise_error("give up")
      end
    end
  end

  describe "#connected?" do
    it "should be false before connecting" do
      expect(publisher).to_not be_connected
    end

    it "should be true once connected" do
      publisher.connect
      expect(publisher).to be_connected
    end

    it "should be false again once disconnected" do
      publisher.connect
      publisher.disconnect
      expect(publisher).to_not be_connected
    end
  end

  describe "#disconnect" do
    it "should close the connection on the broker's side too" do
      publisher.connect
      connection = publisher.instance_variable_get(:@connection)
      publisher.disconnect
      expect(connection).to_not be_open
    end

    it "should do nothing when it was never connected" do
      expect { publisher.disconnect }.to_not raise_error
    end

    it "should make a later publication raise instead of failing on a nil connection" do
      publisher.connect
      publisher.publish(event)
      publisher.disconnect
      expect { publisher.publish(event) }.to raise_error(Flu::NotConnectedError)
    end

    it "should be callable twice" do
      publisher.connect
      publisher.disconnect
      expect { publisher.disconnect }.to_not raise_error
    end
  end

  describe "#publish" do
    let!(:queue) { subscribe_to }

    before(:each) { publisher.connect }

    it "should publish the event on the configured exchange" do
      publisher.publish(event)
      expect(message_count_on(queue, expected: 1)).to eq 1
    end

    it "should use the event's routing key" do
      publisher.publish(event)
      delivery_info, _properties, _payload = next_message_on(queue)
      expect(delivery_info.routing_key).to eq "new.ninja_app.entity_change.create ninja"
    end

    it "should publish the event serialised as JSON" do
      publisher.publish(event)
      _delivery_info, _properties, payload = next_message_on(queue)
      expect(JSON.parse(payload)).to eq JSON.parse(event.to_json)
    end

    it "should publish the event data" do
      publisher.publish(event)
      _delivery_info, _properties, payload = next_message_on(queue)
      expect(JSON.parse(payload)["data"]).to eq({ "name" => "Hanzo", "dynastyId" => 42 })
    end

    it "should publish a persistent message by default" do
      publisher.publish(event)
      _delivery_info, properties, _payload = next_message_on(queue)
      expect(properties.delivery_mode).to eq 2
    end

    it "should publish a transient message when asked to" do
      publisher.publish(event, false)
      _delivery_info, properties, _payload = next_message_on(queue)
      expect(properties.delivery_mode).to eq 1
    end

    it "should publish every event it is given" do
      3.times { publisher.publish(event) }
      expect(message_count_on(queue, expected: 3)).to eq 3
    end

    context "when a queue is bound to another pattern" do
      # The exchange is a topic one, so the emitter and the kind of an event are what a consumer
      # binds on. This is the whole point of the routing key built by 'Event'.
      let!(:matching_queue)     { subscribe_to("new.ninja_app.entity_change.#") }
      let!(:non_matching_queue) { subscribe_to("new.another_app.#") }

      it "should route the event to the queue whose pattern matches" do
        publisher.publish(event)
        expect(message_count_on(matching_queue, expected: 1)).to eq 1
      end

      it "should not route the event to the other one" do
        publisher.publish(event)
        message_count_on(matching_queue, expected: 1)
        expect(non_matching_queue.message_count).to eq 0
      end
    end

    context "when the event has been replayed" do
      before(:each) { event.mark_as_replayed }

      it "should publish it under the 'replayed' routing key" do
        publisher.publish(event)
        delivery_info, _properties, _payload = next_message_on(queue)
        expect(delivery_info.routing_key).to eq "replayed.ninja_app.entity_change.create ninja"
      end
    end

    context "when the event name would make the routing key too long for AMQP" do
      let(:event) do
        Flu::Event.new(SecureRandom.uuid, "ninja_app", :manual, "a" * 300, {})
      end

      it "should publish it without raising" do
        expect { publisher.publish(event) }.to_not raise_error
      end

      it "should deliver it under a routing key the broker accepted" do
        publisher.publish(event)
        expect(message_count_on(queue, expected: 1)).to eq 1
      end
    end

    context "when the event name contains dots" do
      let(:event) do
        Flu::Event.new(SecureRandom.uuid, "ninja_app", :manual, "user.deleted.v2", {})
      end

      it "should route it as a single name segment, not one per dot" do
        matching_queue = subscribe_to("new.ninja_app.manual.userdeletedv2")
        publisher.publish(event)
        expect(message_count_on(matching_queue, expected: 1)).to eq 1
      end
    end
  end

  describe "channels" do
    def exchange_of_current_thread
      publisher.send(:exchange)
    end

    before(:each) { publisher.connect }

    it "should give each thread a channel of its own" do
      connecting_thread_channel = exchange_of_current_thread.channel.id
      worker_channels = 2.times.map do
        Thread.new do
          publisher.publish(event)
          exchange_of_current_thread.channel.id
        end
      end.map(&:value)

      expect(worker_channels.uniq.size).to eq 2
      expect(worker_channels).to_not include connecting_thread_channel
    end

    it "should reuse the same channel across publications of one thread" do
      Thread.new do
        publisher.publish(event)
        first = exchange_of_current_thread
        publisher.publish(event)
        expect(exchange_of_current_thread).to be first
      end.join
    end

    it "should deliver everything published from several threads at once" do
      queue = subscribe_to
      4.times.map { Thread.new { 5.times { publisher.publish(event) } } }.each(&:join)
      expect(message_count_on(queue, expected: 20)).to eq 20
    end

    # The publisher keeps no registry of the channels it handed out, so this is what makes
    # 'disconnect' safe: a thread that was never told about it finds its channel closed and opens
    # a new one by itself.
    it "should replace a cached channel that the connection closed under it" do
      resume    = Queue.new
      exchanges = Queue.new

      worker = Thread.new do
        publisher.publish(event)
        exchanges.push(exchange_of_current_thread)
        resume.pop
        publisher.publish(event)
        exchanges.push(exchange_of_current_thread)
      end

      # Every wait is bounded: a worker that dies on a closed channel must fail this example
      # rather than hang it, which is exactly what the single-channel publisher used to do here.
      before_disconnect = exchanges.pop(timeout: 10)
      expect(before_disconnect).to_not be_nil, "the worker never published"

      publisher.disconnect
      publisher.connect
      resume.push(:go)

      after_reconnect = exchanges.pop(timeout: 10)
      expect(after_reconnect).to_not be_nil, "the worker never published again after the reconnection"
      worker.join(10)

      expect(before_disconnect.channel).to_not be_open
      expect(after_reconnect).to_not be before_disconnect
      expect(after_reconnect.channel).to be_open
    end
  end
end
