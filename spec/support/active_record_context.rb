RSpec.configure do |rspec|
  rspec.shared_context_metadata_behavior = :apply_to_host_groups
end

# 'extend_models' and 'track_entity_changes' register ActiveRecord callbacks, and callbacks
# accumulate: running this setup twice makes every model publish each of its events twice. More
# than one spec file includes this context, so the setup must happen exactly once for the whole
# suite -- and every group must then share the very publisher those callbacks closed over,
# otherwise the events would be published somewhere the examples cannot see.
module ActiveRecordTestSetup
  class << self
    attr_reader :event_factory, :event_publisher

    def installed?
      !@event_publisher.nil?
    end

    def install!
      @event_factory   = Flu::EventFactory.new(Flu.config)
      @event_publisher = Flu::Dummy::InMemoryEventPublisher.new(Flu.config)
      Flu::ActiveRecordExtender.extend_models(@event_factory, @event_publisher)
    end
  end
end

RSpec.shared_context "active records defined", :shared_context => :metadata do
  before(:all) do
    set_application_name("ninja_app")
    first_run = !ActiveRecordTestSetup.installed?
    ActiveRecordTestSetup.install! if first_run
    @event_factory   = ActiveRecordTestSetup.event_factory
    @event_publisher = ActiveRecordTestSetup.event_publisher
    next unless first_run

    ActiveRecord::Migration.verbose = false
    @connection = ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :database => ":memory:")

    ActiveRecord::Schema.define(:version => 1) do
      create_table :dynasties do |t|
        t.string  :name
        t.integer :year
        t.timestamps
      end
      create_table :ninjas do |t|
        t.string  :name
        t.integer :dynasty_id
        t.string  :color
        t.integer :height
        t.integer :weight
        t.timestamps
      end
      create_table :berserks do |t|
        t.string :name
        t.timestamps
      end
      create_table :padawans do |t|
        t.string  :name
        t.integer :master_id
        t.string  :master_type
        t.timestamps
      end
      create_table :weapons do |t|
        t.string  :name
        t.string  :type
        t.string  :serial_number
        t.integer :dynasty_id
        t.timestamps
      end
    end

    def self.init
      raise "configuration.application_name must not be nil" if @configuration.application_name.nil?
      @logger          = @configuration.logger
      @event_factory   = Flu::EventFactory.new(@configuration)
      @event_publisher = create_event_publisher(@configuration)
      extend_models_and_controllers
    end

    class Dynasty < ActiveRecord::Base
      has_many :ninjas, dependent: :destroy
    end

    class Ninja < ActiveRecord::Base
      track_entity_changes user_metadata: {
        create: lambda {
          {
            dynastyName: dynasty.name
          }
        },
        update: lambda {
          {
            dynastyYear: dynasty.year
          }
        },

      }, ignored_model_changes: ["weight"]

      belongs_to :dynasty
      has_one :padawan, as: :master, dependent: :nullify
    end

    class Berserk < ActiveRecord::Base
      track_entity_changes
      has_one :padawan, as: :master, dependent: :nullify
    end

    class Padawan < ActiveRecord::Base
      track_entity_changes emitter: lambda { " star-wars application " }
      belongs_to :master, polymorphic: true
    end

    # Single Table Inheritance: only the base class calls 'track_entity_changes'. ActiveRecord
    # hands its callbacks down to 'Katana', so the subclass must find the very settings those
    # callbacks read -- 'user_metadata', 'ignored_model_changes' and the tracking flag itself.
    class Weapon < ActiveRecord::Base
      track_entity_changes user_metadata: {
        create: lambda {
          {
            dynastyName: dynasty.name
          }
        }
      }, ignored_model_changes: ["serial_number"]

      belongs_to :dynasty
    end

    class Katana < Weapon
    end
  end

  after(:each) do
    @event_publisher.clear
    Thread.current[:flu_pending_publications] = nil # What one example could not publish is not the next one's
    ActiveRecord::Base.connection.execute("DELETE FROM ninjas")
    ActiveRecord::Base.connection.execute("DELETE FROM dynasties")
    ActiveRecord::Base.connection.execute("DELETE FROM weapons")
  end
end

RSpec.configure do |rspec|
  rspec.include_context "active records defined", include_shared: true
end
