require_relative "../support/active_record_context"
require_relative "../support/action_controller_context"

RSpec.describe "tracking", :rabbitmq do
  include_context "active records defined"
  include_context "controllers defined"
  include_context "a rabbitmq broker"

  subject(:publisher) { Flu::EventPublisher.new(configuration) }

  let!(:queue) { subscribe_to }

  before(:each) do
    publisher.connect
    allow(ActiveRecordTestSetup.event_publisher).to receive(:publish) { |event| publisher.publish(event) }
    allow(ActionControllerTestSetup.event_publisher).to receive(:publish) { |event| publisher.publish(event) }
  end

  after(:each) do
    connection = publisher.instance_variable_get(:@connection)
    connection.close if connection&.open?
  end

  def next_event_on(queue)
    delivery_info, _properties, payload = next_message_on(queue)
    [delivery_info.routing_key, JSON.parse(payload)]
  end

  describe "an ActiveRecord change" do
    let(:dynasty) { Dynasty.create!(name: "Tokugawa", year: 1603) }

    before(:each) { Ninja.create!(name: "Hanzo", dynasty: dynasty, color: "black", height: 180, weight: 70) }

    it "should reach the broker" do
      expect(message_count_on(queue, expected: 1)).to eq 1
    end

    it "should be routed by its emitter, its kind and its name" do
      routing_key, _event = next_event_on(queue)
      expect(routing_key).to eq "new.ninja_app.entity_change.create ninja"
    end

    it "should carry the changes of the entity" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["changes"]).to include("name" => [nil, "Hanzo"], "color" => [nil, "black"])
    end

    it "should carry the metadata the model declares" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["userMetadata"]).to eq({ "dynastyName" => "Tokugawa" })
    end

    it "should carry its associations" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["associations"]).to eq({ "dynastyId" => dynasty.id })
    end

    it "should not carry what the model ignores" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["changes"]).to_not have_key "weight"
    end
  end

  describe "an ActiveRecord change on a model overriding the emitter" do
    before(:each) { Padawan.create!(name: "Ahsoka") }

    after(:each) { Padawan.delete_all }

    it "should be routed under the overriden emitter" do
      routing_key, _event = next_event_on(queue)
      expect(routing_key).to eq "new.star-wars application.entity_change.create padawan"
    end
  end

  describe "an ActionController request" do
    before(:each) { dispatch_to(NinjasController, :create, "HTTP_CLIENT_ID" => "ninja-client") }

    it "should reach the broker" do
      expect(message_count_on(queue, expected: 1)).to eq 1
    end

    it "should be routed by its emitter, its kind and its name" do
      routing_key, _event = next_event_on(queue)
      expect(routing_key).to eq "new.ninja_app.request.request to create ninjas"
    end

    it "should carry the response of the request" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["responseCode"]).to eq 200
    end

    it "should carry the metadata the controller declares" do
      _routing_key, event = next_event_on(queue)
      expect(event["data"]["userMetadata"]).to eq({ "currentUserId" => nil, "clientId" => "ninja-client" })
    end
  end
end
