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

    context "when the credentials are refused" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_password: "not-the-password") }

      # Only a TCP failure is worth retrying: a broker that rejects the credentials will keep
      # rejecting them, so the error has to reach the application.
      it "should raise instead of retrying" do
        expect { publisher.connect }.to raise_error(Bunny::AuthenticationFailureError)
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
  end
end
