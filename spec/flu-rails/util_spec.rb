require "stringio"
require_relative "../support/active_record_context"

RSpec.describe Flu::Util::ExportService do
  include_context "active records defined"

  let(:service)         { Flu::Util::ExportService.new }
  let(:export_publisher) { Flu::Dummy::InMemoryEventPublisher.new(Flu.config) }
  let(:export_factory)   { Flu::EventFactory.new(Flu.config) }

  # 'export_existing_entities_to_events' lowers 'Flu.logger' to WARN, and reports its progress on
  # standard output. Neither is interesting here, but both need somewhere to go.
  before(:each) do
    allow(Flu).to receive(:logger).and_return(Logger.new(IO::NULL))

    # The shared context only truncates 'ninjas' and 'dynasties' between examples. Exporting reads
    # whole tables, so these examples must not see rows left behind by another spec file.
    # 'delete_all' issues a plain DELETE and therefore triggers no tracking callback.
    Berserk.delete_all
    Padawan.delete_all
  end

  def export(entity_types)
    original_stdout = $stdout
    $stdout         = StringIO.new
    service.export_existing_entities_to_events(export_publisher, export_factory, entity_types)
  ensure
    $stdout = original_stdout
  end

  def exported_events
    export_publisher.published_events_by_routing_key.values.flatten
  end

  describe "#export_existing_entities_to_events" do
    let!(:dynasty) { Dynasty.create!(name: "Tokugawa", year: 1603) }

    context "when a tracked entity type has existing rows" do
      before(:each) do
        Ninja.create!(name: "Hanzo", dynasty: dynasty, color: "black", height: 180)
        Ninja.create!(name: "Goemon", dynasty: dynasty, color: "blue", height: 175)
        export_publisher.clear
        export([Ninja])
      end

      it "should publish one event per existing entity" do
        expect(export_publisher.events_count).to eq 2
      end

      it "should publish entity change events" do
        expect(exported_events.map(&:kind).uniq).to eq [:entity_change]
      end

      it "should publish them as 'create' events" do
        expect(exported_events.map(&:name).uniq).to eq ["create ninja"]
      end

      it "should describe every non-nil attribute as a change from nil" do
        changes = exported_events.first.data["changes"]
        expect(changes["name"]).to eq [nil, "Hanzo"]
        expect(changes["color"]).to eq [nil, "black"]
        expect(changes["height"]).to eq [nil, 180]
      end

      it "should not export the timestamps as changes" do
        changes = exported_events.first.data["changes"]
        expect(changes).to_not have_key "createdAt"
        expect(changes).to_not have_key "updatedAt"
      end

      it "should not export the attributes ignored by the model" do
        # Ninja is declared with 'ignored_model_changes: ["weight"]'
        expect(exported_events.first.data["changes"]).to_not have_key "weight"
      end

      it "should date each event after the entity it was built from" do
        expect(exported_events.map(&:timestamp)).to match_array Ninja.all.map(&:created_at)
      end

      it "should export the belongs_to associations" do
        expect(exported_events.first.data["associations"]).to eq({ "dynastyId" => dynasty.id })
      end
    end

    context "when the entity type overrides the emitter" do
      before(:each) do
        Padawan.create!(name: "Ahsoka")
        export_publisher.clear
        export([Padawan])
      end

      it "should use the overriden emitter" do
        expect(exported_events.first.emitter).to eq "star-wars application"
      end

      it "should not publish the overriden emitter as part of the event data" do
        expect(exported_events.first.data).to_not have_key "overridenEmitter"
      end
    end

    context "when a tracked entity type has no row" do
      it "should publish nothing" do
        export([Berserk])
        expect(export_publisher.events_count).to eq 0
      end
    end

    context "when an entity type has no 'created_at' attribute" do
      let(:timeless_entity_type) do
        Class.new do
          def self.attribute_names = ["id", "name"]
          def self.name            = "Timeless"
        end
      end

      it "should refuse to export it" do
        expect { export([timeless_entity_type]) }
          .to raise_error(/1 entities do not have 'created_at': \["Timeless"\]/)
      end

      it "should publish nothing" do
        expect { export([timeless_entity_type]) }.to raise_error(StandardError)
        expect(export_publisher.events_count).to eq 0
      end
    end
  end

  describe "#find_all_tracked_entity_types" do
    it "should keep the entity types declaring 'track_entity_changes'" do
      tracked = service.send(:find_all_tracked_entity_types, [Dynasty, Ninja, Berserk, Padawan])
      expect(tracked).to match_array [Ninja, Berserk, Padawan]
    end

    it "should reject an entity type that is not tracked" do
      expect(service.send(:find_all_tracked_entity_types, [Dynasty])).to be_empty
    end
  end
end
