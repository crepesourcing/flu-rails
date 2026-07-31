RSpec.configure do |rspec|
  rspec.shared_context_metadata_behavior = :apply_to_host_groups
end

module ControllerDispatchHelper
  # Runs an action through the real ActionController dispatch: this is what triggers the
  # 'before_action'/'after_action' callbacks that 'track_requests' registers, and therefore the
  # only way to exercise the tracking end to end.
  def dispatch_to(controller_class, action, env = {})
    request                 = ActionDispatch::TestRequest.create(env)
    request.request_method  = "POST"
    request.path_parameters = { controller: controller_name_of(controller_class), action: action.to_s }
    controller_class.new.dispatch(action, request, controller_class.make_response!(request))
  end

  def controller_name_of(controller_class)
    controller_class.name.underscore.sub(/_controller\z/, "")
  end

  def published_controller_events
    @controller_event_publisher.published_events_by_routing_key.values.flatten
  end
end

# Same reasoning as ActiveRecordTestSetup: 'track_requests' registers controller callbacks, which
# accumulate if the setup runs more than once.
module ActionControllerTestSetup
  class << self
    attr_reader :event_factory, :event_publisher, :logger

    def installed?
      !@event_publisher.nil?
    end

    def install!
      @event_factory   = Flu::EventFactory.new(Flu.config)
      @event_publisher = Flu::Dummy::InMemoryEventPublisher.new(Flu.config)
      @logger          = Logger.new(STDOUT)
      Flu::ActionControllerExtender.extend_controllers(@event_factory, @event_publisher, @logger)
    end
  end
end

RSpec.shared_context "controllers defined", :shared_context => :metadata do
  before(:all) do
    set_application_name("ninja_app")
    first_run = !ActionControllerTestSetup.installed?
    ActionControllerTestSetup.install! if first_run
    @event_factory   = ActionControllerTestSetup.event_factory
    @event_publisher = ActionControllerTestSetup.event_publisher
    @logger          = ActionControllerTestSetup.logger

    # The 'active records defined' context assigns '@event_publisher' too. These aliases give the
    # controller examples an unambiguous handle on the publisher and the logger that
    # 'extend_controllers' actually closed over.
    @controller_event_publisher = @event_publisher
    @controller_logger          = @logger
    next unless first_run

    class ApplicationController < ActionController::Base
      attr_accessor :current_user

      def create
        self.response_body = "created"
      end
      def update
        self.response_body = "updated"
      end
      def destroy
        self.response_body = "destroyed"
      end
      def show
        self.response_body = "shown"
      end
      def index
        self.response_body = "indexed"
      end
    end

    class DynastiesController < ApplicationController
    end

    class NinjasController < ApplicationController
      track_requests user_metadata: lambda {
        {
          current_user_id: current_user ? current_user.id : nil,
          client_id:       request.headers["Client-Id"]
        }
      }
    end

    class FarmersController < ApplicationController
      track_requests emitter: lambda { "farmer-app" }
    end

    class BerserksController < ActionController::API
    end

    class PadawansController
    end
  end

  after(:each) do
    @controller_event_publisher.clear
  end
end

RSpec.configure do |rspec|
  rspec.include ControllerDispatchHelper
  rspec.include_context "controllers defined", include_shared: true
end
