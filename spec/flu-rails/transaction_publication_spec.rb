require_relative "../support/active_record_context"

# Events are published when the transaction commits rather than from each record's 'after_commit',
# because Rails skips every transactional callback still queued as soon as one of them raises:
# 'commit_records' re-commits the rest of the batch with 'should_run_callbacks: false'. One raising
# callback -- this gem's, or the application's own -- used to drop the events of every record behind
# it, silently, on data that is committed and cannot be replayed.
RSpec.describe "publication of the events of a transaction" do
  include_context "active records defined"

  let!(:dynasty) { Dynasty.create!(name: "Japan", year: 1300) }

  def create_ninjas(count)
    count.times.map { |index| Ninja.create!(name: "ninja #{index}", dynasty: dynasty, color: "blue", height: 170) }
  end

  def published_ninja_events
    @event_publisher.fetch_events("new.ninja_app.entity_change.create ninja") || []
  end

  def published_ninja_names
    published_ninja_events.map { |event| event.data["changes"]["name"].last }
  end

  # A callback of the application's own, which this gem has no way to rescue: it does not run in its
  # stack. Registered once and armed per example, so that removing it never takes this gem's own
  # callbacks with it.
  poison = { name: nil }
  before(:all) { Ninja.after_commit { raise "poison" if poison[:name] == name } }
  after(:each) { poison[:name] = nil }

  describe "when a callback raises in the middle of the batch" do
    before(:each) { poison[:name] = "ninja 2" }

    def commit_five_ninjas
      ActiveRecord::Base.transaction { create_ninjas(5) }
    rescue RuntimeError => error
      raise unless error.message == "poison"
    end

    it "should publish the events of every record of the batch" do
      commit_five_ninjas
      expect(published_ninja_events.size).to eq 5
    end

    it "should publish the events of the records queued behind the one that raised" do
      commit_five_ninjas
      expect(published_ninja_names).to include "ninja 3", "ninja 4"
    end

    it "should still let the application see its own error" do
      expect { ActiveRecord::Base.transaction { create_ninjas(5) } }.to raise_error("poison")
    end
  end

  describe "when the publisher raises on one event" do
    before(:each) do
      allow(@event_publisher).to receive(:publish).and_wrap_original do |original, event|
        raise Flu::ConnectionLostError, "broker down" if event.data["changes"]["name"].last == "ninja 2"
        original.call(event)
      end
    end

    it "should publish every other event of the batch" do
      ActiveRecord::Base.transaction { create_ninjas(5) }
      expect(published_ninja_events.size).to eq 4
    end

    it "should not fail the transaction over an event it could not publish" do
      expect { ActiveRecord::Base.transaction { create_ninjas(5) } }.to_not raise_error
    end

    it "should keep the event it could not publish for another attempt" do
      ActiveRecord::Base.transaction { create_ninjas(5) }
      expect(Flu::PendingPublications.current.size).to eq 1
    end
  end

  describe "when an event cannot even be built" do
    before(:each) { allow(@event_factory).to receive(:build_manual_event).and_raise("cannot be built") }

    it "should still publish the other events of the same record" do
      ActiveRecord::Base.transaction do
        create_ninjas(1).first.flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      end

      expect(published_ninja_events.size).to eq 1
    end

    it "should report it with no event to hand over" do
      reported = []
      Flu.config.on_publication_failure = lambda { |event, error| reported.push([event, error]) }
      ActiveRecord::Base.transaction do
        create_ninjas(1).first.flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      end

      expect(reported.size).to eq 1
      expect(reported.first.first).to be_nil
      expect(reported.first.last.message).to eq "cannot be built"
    ensure
      Flu.config.on_publication_failure = nil
    end
  end

  describe "what a transaction publishes" do
    it "should publish an event once and once only" do
      create_ninjas(1)
      expect(published_ninja_events.size).to eq 1
    end

    it "should publish them in the order the records were saved" do
      ActiveRecord::Base.transaction { create_ninjas(3) }
      expect(published_ninja_names).to eq ["ninja 0", "ninja 1", "ninja 2"]
    end

    it "should publish nothing before the transaction commits" do
      ActiveRecord::Base.transaction do
        create_ninjas(2)
        expect(published_ninja_events).to be_empty
      end
    end

    it "should publish nothing at all when the transaction rolls back" do
      ActiveRecord::Base.transaction do
        create_ninjas(2)
        raise ActiveRecord::Rollback
      end

      expect(published_ninja_events).to be_empty
    end

    it "should publish the manual events of the batch too" do
      ActiveRecord::Base.transaction do
        create_ninjas(1).first.flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      end

      expect(@event_publisher.fetch_events("new.ninja_app.manual.ninja spotted")&.size).to eq 1
    end

    it "should leave 'flu_publish_events!' publishing on demand" do
      ninja = create_ninjas(1).first
      @event_publisher.clear
      ninja.flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      ninja.flu_publish_events!

      expect(@event_publisher.fetch_events("new.ninja_app.manual.ninja spotted")&.size).to eq 1
    end
  end

  describe "nested transactions" do
    it "should publish what the nested transaction committed" do
      ActiveRecord::Base.transaction do
        Ninja.create!(name: "outer", dynasty: dynasty, color: "blue", height: 170)
        ActiveRecord::Base.transaction(requires_new: true) do
          Ninja.create!(name: "inner", dynasty: dynasty, color: "blue", height: 170)
        end
      end

      expect(published_ninja_names).to eq ["outer", "inner"]
    end

    it "should publish nothing of a nested transaction that rolled back" do
      ActiveRecord::Base.transaction do
        Ninja.create!(name: "outer", dynasty: dynasty, color: "blue", height: 170)
        ActiveRecord::Base.transaction(requires_new: true) do
          Ninja.create!(name: "inner", dynasty: dynasty, color: "blue", height: 170)
          raise ActiveRecord::Rollback
        end
      end

      expect(published_ninja_names).to eq ["outer"]
    end

    it "should publish nothing when the outer transaction rolls back" do
      ActiveRecord::Base.transaction do
        Ninja.create!(name: "outer", dynasty: dynasty, color: "blue", height: 170)
        ActiveRecord::Base.transaction(requires_new: true) do
          Ninja.create!(name: "inner", dynasty: dynasty, color: "blue", height: 170)
        end
        raise ActiveRecord::Rollback
      end

      expect(published_ninja_events).to be_empty
    end
  end

  # Rails runs the transactional callbacks of a row on one of its instances only, and skips the
  # others without a word. Which one it keeps is what
  # 'run_commit_callbacks_on_first_saved_instances_in_transaction' decides, so events buffered on an
  # instance are lost either way: the create under the Rails 7.1 default, the update under the older
  # one.
  describe "a row saved as several instances of its own in one transaction" do
    def commit_a_create_and_an_update_on_separate_instances
      ActiveRecord::Base.transaction do
        ninja = create_ninjas(1).first
        Ninja.find(ninja.id).update!(color: "red")
      end
    end

    def published_update_events
      @event_publisher.fetch_events("new.ninja_app.entity_change.update ninja") || []
    end

    [true, false].each do |on_first_instance|
      context "with the callbacks running on the #{on_first_instance ? 'first' : 'last'} instance" do
        around(:each) do |example|
          previously = ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction
          ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction = on_first_instance
          example.run
        ensure
          ActiveRecord::Base.run_commit_callbacks_on_first_saved_instances_in_transaction = previously
        end

        it "should publish the event of the instance that created the row" do
          commit_a_create_and_an_update_on_separate_instances
          expect(published_ninja_events.size).to eq 1
        end

        it "should publish the event of the instance that updated it" do
          commit_a_create_and_an_update_on_separate_instances
          expect(published_update_events.size).to eq 1
        end
      end
    end
  end

  # 'use_transactional_tests' wraps each example in a transaction opened as non-joinable, which is
  # rolled back rather than committed: waiting for it would hold every event until the example ends.
  describe "within a transaction that will never commit" do
    around(:each) do |example|
      connection = ActiveRecord::Base.lease_connection
      connection.begin_transaction(joinable: false)
      example.run
    ensure
      connection.rollback_transaction
    end

    it "should publish what the transactions inside it commit" do
      ActiveRecord::Base.transaction { create_ninjas(2) }
      expect(published_ninja_names).to eq ["ninja 0", "ninja 1"]
    end

    it "should publish the events of every instance of the same row too" do
      ActiveRecord::Base.transaction do
        ninja = create_ninjas(1).first
        Ninja.find(ninja.id).update!(color: "red")
      end

      expect(published_ninja_events.size).to eq 1
      expect(@event_publisher.fetch_events("new.ninja_app.entity_change.update ninja")&.size).to eq 1
    end
  end

  describe "an event added outside any transaction" do
    it "should not be published by the next transaction to commit" do
      create_ninjas(1).first.flu_add_manual_event("ninja spotted", { "where" => "Kyoto" })
      ActiveRecord::Base.transaction { create_ninjas(1) }

      expect(@event_publisher.fetch_events("new.ninja_app.manual.ninja spotted")).to be_nil
    end
  end
end
