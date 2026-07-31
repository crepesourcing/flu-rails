require "securerandom"

RSpec.describe Flu::QueueRepository, :rabbitmq do
  include_context "a rabbitmq broker"

  subject(:repository) { described_class.new(configuration) }

  let(:publisher)   { Flu::EventPublisher.new(configuration) }
  let(:routing_key) { "new.ninja_app.entity_change.create ninja" }
  let!(:queue)      { subscribe_to(routing_key) }

  def publish_events(count)
    publisher.connect
    count.times do
      publisher.publish(Flu::Event.new(SecureRandom.uuid, "ninja_app", :entity_change, "create ninja",
                                       { "name" => "Hanzo" }))
    end
    message_count_on(queue, expected: count)
  end

  after(:each) do
    connection = publisher.instance_variable_get(:@connection)
    connection.close if connection&.open?
  end

  describe "#find_all" do
    it "should return the queues declared on the broker" do
      expect(repository.find_all.map(&:name)).to include queue.name
    end
  end

  describe "#find_queue" do
    it "should return the queue of that name" do
      expect(repository.find_queue(queue.name).name).to eq queue.name
    end

    it "should describe it" do
      expect(repository.find_queue(queue.name).durable).to be true
    end

    it "should raise when no queue has that name" do
      expect { repository.find_queue("flu-rails-spec-no-such-queue") }
        .to raise_error(Faraday::ResourceNotFound)
    end
  end

  describe "#find_bindings_for_queue" do
    it "should return the binding to the exchange the queue is bound to" do
      binding = repository.find_bindings_for_queue(queue.name)
                          .find { |candidate| candidate.source == configuration.rabbitmq_exchange_name }
      expect(binding).to_not be_nil
    end

    it "should return the routing key of that binding" do
      binding = repository.find_bindings_for_queue(queue.name)
                          .find { |candidate| candidate.source == configuration.rabbitmq_exchange_name }
      expect(binding.routing_key).to eq routing_key
    end

    # Every queue is also reachable through the default exchange, under its own name.
    it "should return the implicit binding to the default exchange" do
      sources = repository.find_bindings_for_queue(queue.name).map(&:source)
      expect(sources).to include ""
    end
  end

  describe "#purge_queue" do
    it "should discard the messages waiting on the queue" do
      expect(publish_events(2)).to eq 2
      repository.purge_queue(queue.name)
      expect(queue.message_count).to eq 0
    end

    it "should keep the queue itself" do
      publish_events(1)
      repository.purge_queue(queue.name)
      expect(repository.find_queue(queue.name).name).to eq queue.name
    end
  end

  describe "#delete_queue" do
    # The queue is gone, so the cleanup of the shared context must not try to delete it a second
    # time: that would close the channel it deletes the other queues with.
    before(:each) do
      repository.delete_queue(queue.name)
      declared_queues.delete(queue)
    end

    it "should remove the queue from the broker" do
      expect { repository.find_queue(queue.name) }.to raise_error(Faraday::ResourceNotFound)
    end

    it "should remove it from the queues of the broker" do
      expect(repository.find_all.map(&:name)).to_not include queue.name
    end
  end

  describe "the management client" do
    context "when no management scheme is configured" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_management_scheme: nil) }

      it "should fall back on http" do
        expect(repository.find_all.map(&:name)).to include queue.name
      end
    end

    context "when the management port is wrong" do
      let(:configuration) { RabbitmqHelper.configuration(rabbitmq_management_port: RabbitmqHelper::PORT) }

      # The AMQP port is open but speaks no HTTP, so this is a connection that is established and
      # then goes nowhere -- the failure mode a misconfigured 'rabbitmq_management_port' produces.
      it "should not reach the management API" do
        expect { repository.find_all }.to raise_error(StandardError)
      end
    end
  end
end
