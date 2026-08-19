require_relative "../support/active_record_context"

# An event whose publication failed is kept for another attempt rather than given up on: a broker
# that closed the connection is reachable again a few seconds later, and the transaction the event
# belongs to has committed in the meantime.
RSpec.describe Flu::PendingPublications do
  include_context "active records defined"

  let!(:dynasty) { Dynasty.create!(name: "Japan", year: 1300) }
  let(:pending)  { described_class.current }
  let(:reported) { [] }

  before(:each) { Flu.config.on_publication_failure = lambda { |event, error| reported.push([event, error]) } }
  after(:each)  { Flu.config.on_publication_failure = nil }

  def create_ninja(name)
    Ninja.create!(name: name, dynasty: dynasty, color: "blue", height: 170)
  end

  def published_ninja_events
    @event_publisher.fetch_events("new.ninja_app.entity_change.create ninja") || []
  end

  def broker_refuses_everything
    allow(@event_publisher).to receive(:publish).and_raise(Flu::ConnectionLostError, "broker down")
  end

  def broker_is_reachable(reachable)
    allow(@event_publisher).to receive(:connected?).and_return(reachable)
  end

  describe "while the publisher cannot be reached" do
    before(:each) do
      broker_refuses_everything
      broker_is_reachable(false)
      create_ninja("Hanzo")
    end

    it "should keep the event it could not publish" do
      expect(pending.size).to eq 1
    end

    it "should not report it as lost yet" do
      expect(reported).to be_empty
    end

    it "should not spend an attempt on a publisher that says it cannot take it" do
      3.times { |index| create_ninja("ninja #{index}") }
      expect(reported).to be_empty
      expect(pending.size).to eq 4
    end
  end

  describe "once the publisher can be reached again" do
    before(:each) do
      broker_refuses_everything
      broker_is_reachable(false)
      create_ninja("Hanzo")
      allow(@event_publisher).to receive(:publish).and_call_original
      broker_is_reachable(true)
    end

    it "should publish what it kept on the next commit of the thread" do
      create_ninja("Goemon")
      expect(published_ninja_events.size).to eq 2
    end

    it "should keep nothing once it is published" do
      create_ninja("Goemon")
      expect(pending.size).to eq 0
    end

    it "should publish what it kept at the end of the request, with no commit to hang on" do
      Flu.retry_pending_publications
      expect(published_ninja_events.size).to eq 1
      expect(pending.size).to eq 0
    end
  end

  describe "when the publisher takes the event but keeps refusing it" do
    before(:each) do
      broker_is_reachable(true)
      @attempts = 0
      allow(@event_publisher).to receive(:publish) do
        @attempts += 1
        raise Flu::ConnectionLostError, "broker down"
      end
      create_ninja("Hanzo")
      10.times { Flu.retry_pending_publications }
    end

    it "should try it 'MAX_ATTEMPTS' times and no more" do
      expect(@attempts).to eq described_class::MAX_ATTEMPTS
    end

    it "should give up on it rather than retry it forever" do
      expect(pending.size).to eq 0
    end

    it "should hand it over to 'on_publication_failure' with the error that made it fail" do
      expect(reported.size).to eq 1
      expect(reported.first.first.data["changes"]["name"].last).to eq "Hanzo"
      expect(reported.first.last).to be_a Flu::ConnectionLostError
    end
  end

  describe "when more events pile up than the configuration allows" do
    before(:each) do
      Flu.config.max_pending_events = 2
      broker_refuses_everything
      broker_is_reachable(false)
      3.times { |index| create_ninja("ninja #{index}") }
    end

    after(:each) { Flu.config.max_pending_events = 1000 }

    it "should keep no more than that" do
      expect(pending.size).to eq 2
    end

    it "should report the oldest rather than drop it silently" do
      expect(reported.size).to eq 1
      expect(reported.first.first.data["changes"]["name"].last).to eq "ninja 0"
    end
  end

  describe "an event that could not even be built" do
    before(:each) do
      allow(@event_factory).to receive(:build_manual_event).and_raise("cannot be built")
      broker_is_reachable(false)
    end

    it "should be reported at once, there being nothing to try again" do
      ActiveRecord::Base.transaction do
        create_ninja("Hanzo").flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      end

      expect(pending.size).to eq 0
      expect(reported.size).to eq 1
      expect(reported.first.first).to be_nil
    end
  end
end
