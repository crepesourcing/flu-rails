require_relative "../support/active_record_context"

RSpec.describe Flu::ActiveRecordExtender do
  include_context "active records defined"

  let(:dynasty) { Dynasty.new(name: "Japan", year: 1300) }

  def fetch_event_for_new_ninja
    @event_publisher.fetch_events("new.ninja_app.entity_change.create ninja").first
  end

  def fetch_event_for_updated_ninja
    @event_publisher.fetch_events("new.ninja_app.entity_change.update ninja").first
  end

  def fetch_event_for_destroyed_ninja
    @event_publisher.fetch_events("new.ninja_app.entity_change.destroy ninja").first
  end

  context "#extend_models" do

    it "Dynasty must not be tracked" do
      expect(Dynasty.flu_is_tracked).to be false
    end

    it "Ninja must be tracked" do
      expect(Ninja.flu_is_tracked).to be true
    end

    it "Berserk must be tracked" do
      expect(Berserk.flu_is_tracked).to be true
    end

    it "Padawan must be tracked" do
      expect(Padawan.flu_is_tracked).to be true
    end

    it "Padawan association columns should contain master_type (polymorphic association)" do
      expect(Padawan.flu_association_columns).to include "master_type"
    end

    it "Padawan association columns should contain master_id" do
      expect(Padawan.flu_association_columns).to include "master_id"
    end

    it "Berserk association columns should not contain padawan_id (has_one)" do
      expect(Berserk.flu_association_columns).to_not include "padawan_id"
    end

    it "Ninja association columns should not contain padawan_id (has_one)" do
      expect(Ninja.flu_association_columns).to_not include "padawan_id"
    end

    it "Ninja association columns should contain dynasty_id" do
      expect(Ninja.flu_association_columns).to include "dynasty_id"
    end
    

    context "when saving a dynasty" do
      it "should not emit any event" do
        dynasty.save!
        expect(@event_publisher.events_count).to eq 0
      end
    end

    context "when saving a ninja" do
      let (:ninja) {
        Ninja.new(dynasty: dynasty, name: "Jean Paul", color: :black, height: 160, weight: 60)
      }

      before(:each) do
        ninja.save!
      end

      it "should emit a single event" do
        expect(@event_publisher.events_count).to eq 1
      end

      it "should emit a valid event id" do
        event = fetch_event_for_new_ninja
        expect(event.id).to_not be_nil
      end

      it "should emit a valid event name" do
        event = fetch_event_for_new_ninja
        expect(event.name).to eq "create ninja"
      end

      it "should emit a valid emitter" do
        event = fetch_event_for_new_ninja
        expect(event.emitter).to eq "ninja_app"
      end

      it "should emit a valid timestamp" do
        event = fetch_event_for_new_ninja
        expect(event.timestamp).to_not be_nil
      end

      it "should emit a valid kind" do
        event = fetch_event_for_new_ninja
        expect(event.kind).to eq :entity_change
      end

      it "should emit a valid status" do
        event = fetch_event_for_new_ninja
        expect(event.status).to eq :new
      end

      it "should emit valid changes" do
        event = fetch_event_for_new_ninja
        expected_data = {
          "id" => [nil, ninja.id],
          "name" => [nil, ninja.name],
          "dynastyId" => [nil, dynasty.id],
          "color" => [nil, ninja.color],
          "height" => [nil, ninja.height]
        }
        expect(event.data["changes"]).to eq expected_data
      end

      it "should emit a valid data -> entity id" do
        event = fetch_event_for_new_ninja
        expect(event.data["entityId"]).to eq ninja.id
      end

      it "should emit a valid data -> entity name" do
        event = fetch_event_for_new_ninja
        expect(event.data["entityName"]).to eq "ninja"
      end

      it "should emit a nil data -> request Id" do
        event = fetch_event_for_new_ninja
        expect(event.data["requestId"]).to be_nil
      end

      it "should emit an empty data -> request metadata" do
        event = fetch_event_for_new_ninja
        expect(event.data["requestMetadata"]).to be_empty
      end

      it "should emit a valid data -> action name" do
        event = fetch_event_for_new_ninja
        expect(event.data["actionName"]).to eq :create
      end

      it "should emit a valid data -> action name" do
        event = fetch_event_for_new_ninja
        expect(event.data["actionName"]).to eq :create
      end

      it "should ignore timestamps (default 'ignore')" do
        event = fetch_event_for_new_ninja
        expect(event.data["changes"].has_key?("updatedAt")).to be false
        expect(event.data["changes"].has_key?("createdAt")).to be false
      end

      it "should ignore timestamps (by_class 'ignore')" do
        event = fetch_event_for_new_ninja
        expect(event.data["changes"].has_key?("weight")).to be false
      end

      it "should emit valid associations" do
        event = fetch_event_for_new_ninja
        expected_associations = {
          "dynastyId" => ninja.dynasty.id
        }
        expect(event.data["associations"]).to eq expected_associations
      end

      it "should emit valid userMetadata" do
        event = fetch_event_for_new_ninja
        expected_metadata = {
          "dynastyName" => ninja.dynasty.name
        }
        expect(event.data["userMetadata"]).to eq expected_metadata
      end

      context "when loading it again" do
        let(:reloaded_ninja) { Ninja.find(ninja.id) }
        before(:each) do
          @event_publisher.clear
        end

        context "when doing nothing with the ninja and saving it" do
          it "should not emit any event" do
            reloaded_ninja.save!
            expect(@event_publisher.events_count).to eq 0
          end
        end

        context "when updating a single ignored field and saving it" do
          it "should not emit any event" do
            reloaded_ninja.weight = 100
            reloaded_ninja.save!
            expect(@event_publisher.events_count).to eq 0
          end
        end

        context "when updating some attributes and saving it" do
          before(:each) do
            reloaded_ninja.color = :purple
            reloaded_ninja.save!
          end

          it "should emit a single event" do
            expect(@event_publisher.events_count).to eq 1
          end

          it "should emit with status new" do
            event = fetch_event_for_updated_ninja
            expect(event.status).to eq :new
          end

          it "should emit with the single change in it" do
            event = fetch_event_for_updated_ninja
            expected_data = {
              "color" => [ninja.color, reloaded_ninja.color]
            }
            expect(event.data["changes"]).to eq expected_data
          end

          it "should emit a valid data -> entity id" do
            event = fetch_event_for_updated_ninja
            expect(event.data["entityId"]).to eq reloaded_ninja.id
          end

          it "should emit a valid data -> entity name" do
            event = fetch_event_for_updated_ninja
            expect(event.data["entityName"]).to eq "ninja"
          end

          it "should emit a nil data -> request Id" do
            event = fetch_event_for_updated_ninja
            expect(event.data["requestId"]).to be_nil
          end

          it "should emit an empty data -> request metadata" do
            event = fetch_event_for_updated_ninja
            expect(event.data["requestMetadata"]).to be_empty
          end

          it "should emit a valid data -> action name" do
            event = fetch_event_for_updated_ninja
            expect(event.data["actionName"]).to eq :update
          end

          it "should ignore timestamps (default 'ignore')" do
            event = fetch_event_for_updated_ninja
            expect(event.data["changes"].has_key?("updatedAt")).to be false
            expect(event.data["changes"].has_key?("createdAt")).to be false
          end

          it "should ignore timestamps (by_class 'ignore')" do
            event = fetch_event_for_updated_ninja
            expect(event.data["changes"].has_key?("weight")).to be false
          end

          it "should emit valid associations" do
            event = fetch_event_for_updated_ninja
            expected_associations = {
              "dynastyId" => reloaded_ninja.dynasty.id
            }
            expect(event.data["associations"]).to eq expected_associations
          end

          it "should emit valid userMetadata" do
            event = fetch_event_for_updated_ninja
            expected_metadata = {
              "dynastyYear" => reloaded_ninja.dynasty.year
            }
            expect(event.data["userMetadata"]).to eq expected_metadata
          end
        end

        context "when deleting it" do
          before(:each) do
            @event_publisher.clear
            reloaded_ninja.destroy!
          end

          it "should emit a single event" do
            expect(@event_publisher.events_count).to eq 1
          end

          it "should emit a valid entityId" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["entityId"]).to eq reloaded_ninja.id
          end

          it "should emit a valid data -> entity name" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["entityName"]).to eq "ninja"
          end

          it "should emit a nil data -> request Id" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["requestId"]).to be_nil
          end

          it "should emit an empty data -> request metadata" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["requestMetadata"]).to be_empty
          end

          it "should emit a valid data -> action name" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["actionName"]).to eq :destroy
          end

          it "should emit with its id only as change" do
            event = fetch_event_for_destroyed_ninja
            expected_data = {
              "id" => [reloaded_ninja.id, nil]
            }
            expect(event.data["changes"]).to eq expected_data
          end

          it "should emit valid associations" do
            event = fetch_event_for_destroyed_ninja
            expected_associations = {
              "dynastyId" => reloaded_ninja.dynasty.id
            }
            expect(event.data["associations"]).to eq expected_associations
          end

          it "should emit an empty userMetadata" do
            event = fetch_event_for_destroyed_ninja
            expect(event.data["userMetadata"]).to be_empty
          end
        end
      end
    end

    context "when saving three ninjas" do
      let (:ninja1) {
        Ninja.new(dynasty: dynasty, name: "Jean Paul", color: :black, height: 160, weight: 60)
      }
      let (:ninja2) {
        Ninja.new(dynasty: dynasty, name: "Henri", color: :yellow, height: 150, weight: 75)
      }
      let (:ninja3) {
        Ninja.new(dynasty: dynasty, name: "Michel", color: :white, height: 200, weight: 80)
      }
      it "should emit 3 events" do
        ninja1.save!
        ninja2.save!
        ninja3.save!
        expect(@event_publisher.events_count).to eq 3
        expect(@event_publisher.fetch_events("new.ninja_app.entity_change.create ninja").size).to eq 3
      end
    end

    context "when saving a berserk's padawan" do
      let (:berserk)        { Berserk.new(name: "cloclo") }
      let (:padawan)        { Padawan.new(name: "pouyou", master: berserk) }
      let (:berserk_events) { @event_publisher.fetch_events("new.ninja_app.entity_change.create berserk") }
      let (:berserk_event)  { berserk_events.first }
      let (:padawan_events) { @event_publisher.fetch_events("new.star-wars application.entity_change.create padawan") }
      let (:padawan_event)  { padawan_events.first }

      before(:each) do
        berserk.save!
        padawan.save!
      end

      it "should emit 2 events" do
        expect(@event_publisher.events_count).to eq 2
      end

      it "should emit one event for 'create berserk'" do
        expect(berserk_events.size).to eq 1
      end

      it "should emit one event for 'create padawan'" do
        expect(padawan_events.size).to eq 1
      end

      it "should not had the padawan_id (has_one) to the 'create berserk' associations" do
        expect(berserk_event.data["associations"]).to be_empty
      end

      it "should had the padawan_id (belongs_to) to the 'create berserk' associations" do
        expect(padawan_event.data["associations"]["masterId"]).to eq berserk.id
      end

      it "should add berserk_type to the padawan event" do
        expect(padawan_event.data["associations"]["masterType"]).to eq Berserk.name
      end

      it "should set the overriden emitter on the Padawan event" do
        expect(padawan_event.emitter).to eq "star-wars application"
      end

      context "when moving the padawan from the berserk to a ninja" do
        let (:different_id_from_berserk) { berserk.id * 2 }
        let (:ninja)                     { Ninja.new(id: different_id_from_berserk, dynasty: dynasty, name: "Jean Paul", color: :black, height: 160, weight: 60) }
        let (:update_padawan_events)     { @event_publisher.fetch_events("new.star-wars application.entity_change.update padawan") }
        let (:update_padawan_event)      { update_padawan_events.first }

        before(:each) do
          ninja.save!
          padawan.master = ninja
          padawan.save!
        end

        it "should emit one event for 'update padawan'" do
          expect(update_padawan_events.size).to eq 1
        end

        it "should add old master id to the update padawan event" do
          expect(update_padawan_event.data["changes"]["masterId"][0]).to eq berserk.id
        end

        it "should add new master id to the update padawan event" do
          expect(update_padawan_event.data["changes"]["masterId"][1]).to eq ninja.id
        end

        it "should add old master type to the update padawan event" do
          expect(update_padawan_event.data["changes"]["masterType"][0]).to eq Berserk.name
        end

        it "should add new master type to the update padawan event" do
          expect(update_padawan_event.data["changes"]["masterType"][1]).to eq Ninja.name
        end

        it "should add ninja_type to the update padawan event" do
          expect(update_padawan_event.data["associations"]["masterType"]).to eq Ninja.name
        end

        it "should set the overriden emitter on the Padawan event" do
          expect(update_padawan_event.emitter).to eq "star-wars application"
        end
      end
    end

    context "when adding a manuel event that is not a hash" do
      it "raises an exception" do
        expect { Ninja.new.flu_add_manual_event("custom name", "not a hash") }.to raise_error
      end
    end

    context "when publishing events programmatically" do
      let(:daddy_ninja)        { Ninja.new(dynasty: dynasty, name: "Marcel",  color: :black,  height: 180, weight: 90) }

      def add_custom_events(ninja)
        ninja.flu_add_manual_event("custom", {})
        ninja.flu_add_manual_event("event", {})
      end
      
      before(:each) do
        add_custom_events(daddy_ninja)
        daddy_ninja.flu_publish_events!
      end

      it "flushes the events in the active record" do
        expect(daddy_ninja.flu_changes.size).to eq 0
      end

      it "publishes the manual events" do
        expect(@event_publisher.events_count).to eq 2
      end

      it "publishes events in the proper order" do
        expect(@event_publisher.ordered_published_event_routing_keys).to eq [
          "new.ninja_app.manual.custom",
          "new.ninja_app.manual.event"
        ]
      end
    end

    context "when saving ninjas in a transaction" do
      let(:daddy_ninja)        { Ninja.new(dynasty: dynasty, name: "Marcel",  color: :black,  height: 180, weight: 90) }
      let(:mommy_ninja)        { Ninja.new(dynasty: dynasty, name: "Ginette", color: :yellow, height: 160, weight: 60) }
      let(:mini_ninja)         { Ninja.new(dynasty: dynasty, name: "George",  color: :yellow, height: 50, weight: 15) }
      let(:must_rollback)      { false }
      let(:custom_event_data1) do
        {
          ladies: ["boss", "master"]
        }
      end
      let(:custom_event_data2) do
        {
          enemy: "black ninja",
          age:   42
        }
      end
      let(:custom_event_name1) { "send pigeons to the ladies" }
      let(:custom_event_name2) { "kill arch enemy" }

      def add_custom_events(ninja)
        ninja.flu_add_manual_event(custom_event_name1, custom_event_data1)
        ninja.flu_add_manual_event(custom_event_name2, custom_event_data2)
      end

      before(:each) do
        begin
          Ninja.transaction do
            daddy_ninja.save!
            add_custom_events(daddy_ninja)
            @after_custom_events_count = @event_publisher.events_count
            mommy_ninja.save!
            mini_ninja.save!
            @before_commit_events_count = @event_publisher.events_count
            raise "rollback" if must_rollback
          end
        rescue
        end
        @after_transaction_events = @event_publisher.events_count
      end

      context "when the transaction commits" do
        let(:must_rollback) { false }
        it "does not publish any event in the transaction" do
          expect(@before_commit_events_count).to eq 0
        end
        it "does not publish any event when adding custom events" do
          expect(@after_custom_events_count).to eq 0
        end
        it "publishes 5 events when committing" do
          expect(@after_transaction_events).to eq 5
        end
        it "publishes events in the proper order" do
          expect(@event_publisher.ordered_published_event_routing_keys).to eq [
            "new.ninja_app.entity_change.create ninja",
            "new.ninja_app.manual.#{custom_event_name1}",
            "new.ninja_app.manual.#{custom_event_name2}",
            "new.ninja_app.entity_change.create ninja",
            "new.ninja_app.entity_change.create ninja"
          ]
        end
      end

      context "when the transaction rollbacks" do
        let(:must_rollback) { true }
        it "does not publish any event in the transaction" do
          expect(@before_commit_events_count).to eq 0
        end
        it "does not publish any event after the transaction" do
          expect(@after_transaction_events).to eq 0
        end
      end
    end

    context "with a Single Table Inheritance subclass of a tracked model" do
      let(:dynasty) { Dynasty.create!(name: "Tokugawa", year: 1603) }

      it "considers the subclass tracked" do
        expect(Katana.flu_is_tracked).to be true
      end

      it "inherits the user metadata lambdas of its parent" do
        expect(Katana.flu_user_metadata_lambdas.keys).to eq [:create]
      end

      it "inherits the ignored model changes of its parent" do
        expect(Katana.flu_ignored_model_changes).to eq ["serial_number"]
      end

      it "inherits the association columns of its parent" do
        expect(Katana.flu_association_columns).to include "dynasty_id"
      end

      context "when saving a subclass instance" do
        before(:each) do
          Katana.create!(name: "Masamune", dynasty: dynasty, serial_number: "SN-1")
        end

        def fetch_event_for_new_katana
          @event_publisher.fetch_events("new.ninja_app.entity_change.create katana").first
        end

        it "emits a single event" do
          expect(@event_publisher.events_count).to eq 1
        end

        it "names the event after the subclass" do
          expect(fetch_event_for_new_katana.data["entityName"]).to eq "katana"
        end

        it "applies the user metadata lambdas of its parent" do
          expect(fetch_event_for_new_katana.data["userMetadata"]).to eq({ "dynastyName" => "Tokugawa" })
        end

        it "applies the ignored model changes of its parent" do
          expect(fetch_event_for_new_katana.data["changes"]).to_not have_key "serialNumber"
        end

        it "reports the associations of its parent" do
          expect(fetch_event_for_new_katana.data["associations"]).to eq({ "dynastyId" => dynasty.id })
        end
      end

      context "when saving the parent class itself" do
        before(:each) do
          Weapon.create!(name: "Naginata", dynasty: dynasty, serial_number: "SN-2")
        end

        it "still emits an event named after the parent" do
          expect(@event_publisher.fetch_events("new.ninja_app.entity_change.create weapon").size).to eq 1
        end
      end
    end
  end
end
