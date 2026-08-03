require_relative "../support/action_controller_context"

RSpec.describe Flu::ActionControllerExtender do
  include_context "controllers defined"

  let(:current_user) { OpenStruct.new(id: 14, name: "Michel")}

  context "#extend_controllers" do
    it "track_requests is available on ActionController::Base classes" do
      expect(ActionController::Base.methods).to include :track_requests
    end

    it "track_requests is available on ActionController::API classes" do
      expect(ActionController::API.methods).to include :track_requests
    end

    it "track_requests is not available on non-controller classes" do
      expect(PadawansController.methods).to_not include :track_requests
    end

    it "DynastiesController's requests must not be tracked" do
      expect(DynastiesController.flu_is_tracked).to be false
    end

    it "NinjasController's requests must be tracked" do
      expect(NinjasController.flu_is_tracked).to be true
    end

    it "BerserksController's requests must be tracked" do
      expect(BerserksController.flu_is_tracked).to be false
    end

    context "the tracking helpers" do
      it "should be defined on the tracked controller" do
        expect(NinjasController.method_defined?(:flu_track_request)).to be true
      end

      it "should not leak onto ActionController::Base" do
        expect(ActionController::Base.method_defined?(:flu_track_request)).to be false
      end

      it "should not leak onto ActionController::API" do
        expect(ActionController::API.method_defined?(:flu_track_request)).to be false
      end

      it "should not leak onto an untracked controller" do
        expect(DynastiesController.method_defined?(:flu_track_request)).to be false
      end
    end

    context "when calling DynastiesController#create" do
      it "should not emit any event" do
        dispatch_to(DynastiesController, :create)
        expect(@controller_event_publisher.events_count).to eq 0
      end
    end

    context "when calling NinjasController#create" do
      context "with no parameters" do
        before(:each) do
          dispatch_to(NinjasController, :create)
        end

        it "should emit a single event" do
          expect(@controller_event_publisher.events_count).to eq 1
        end

        it "should emit a request event named after the controller and the action" do
          event = published_controller_events.first
          expect(event.kind).to eq :request
          expect(event.name).to eq "request to create ninjas"
        end

        it "should emit an event carrying the request data" do
          data = published_controller_events.first.data
          expect(data["controllerName"]).to eq "ninjas"
          expect(data["actionName"]).to eq "create"
          expect(data["responseCode"]).to eq 200
          expect(data["requestId"]).to_not be_nil
        end

        it "should emit a small, non-negative duration" do
          duration = published_controller_events.first.data["duration"]
          expect(duration).to be_a(Float).and be_between(0, 1)
        end

        it "should evaluate the user metadata lambda in the controller's context" do
          expect(published_controller_events.first.data["userMetadata"]).to eq({
            "currentUserId" => nil,
            "clientId"      => nil
          })
        end

        it "should use the configured application name as emitter" do
          expect(published_controller_events.first.emitter).to eq "ninja_app"
        end
      end
    end

    context "when calling FarmersController#create" do
      context "with no parameters" do
        before(:each) do
          dispatch_to(FarmersController, :create)
        end

        it "should emit a single event" do
          expect(@controller_event_publisher.events_count).to eq 1
        end

        it "should use the overriden emitter" do
          expect(published_controller_events.first.emitter).to eq "farmer-app"
        end

        it "should not publish the overriden emitter as part of the event data" do
          expect(published_controller_events.first.data).to_not have_key "overridenEmitter"
        end
      end
    end

    context "when the user agent is rejected" do
      before(:each) { Flu.config.rejected_user_agents = [/BadBot/] }
      after(:each)  { Flu.config.rejected_user_agents = [] }

      it "should not emit any event" do
        dispatch_to(NinjasController, :create, "HTTP_USER_AGENT" => "BadBot/1.0")
        expect(@controller_event_publisher.events_count).to eq 0
      end

      # Regression test: the warning used to be emitted through ActionController::Base#logger,
      # because a bare 'def' does not close over the logger given to 'extend_controllers'.
      it "should warn through the logger Flu was configured with" do
        expect(@controller_logger).to receive(:warn).with(/Origin user agent rejected: BadBot\/1\.0/)
        dispatch_to(NinjasController, :create, "HTTP_USER_AGENT" => "BadBot/1.0")
      end
    end

    context "when the request has no user agent" do
      it "should still emit an event" do
        dispatch_to(NinjasController, :create, "HTTP_USER_AGENT" => nil)
        expect(@controller_event_publisher.events_count).to eq 1
      end
    end

    context "when an entity metadata lambda is given" do
      it "should expose its result while the action runs" do
        seen = nil
        allow_any_instance_of(SamuraisController).to receive(:create) do |controller|
          seen = Flu::CoreExt.flu_tracker_request_entity_metadata
          controller.response_body = "created"
        end
        dispatch_to(SamuraisController, :create)
        expect(seen).to eq({ path: "/" })
      end

      it "should clear it once the action is done" do
        dispatch_to(SamuraisController, :create)
        expect(Flu::CoreExt.flu_tracker_request_entity_metadata).to be_nil
      end
    end

    context "when the action raises" do
      def dispatch_failing_action(controller_class)
        dispatch_to(controller_class, :boom)
      rescue RuntimeError
        nil
      end

      after(:each) do
        Flu::CoreExt.flu_tracker_request_id              = nil
        Flu::CoreExt.flu_tracker_request_entity_metadata = nil
      end

      it "should let the exception through" do
        expect { dispatch_to(NinjasController, :boom) }.to raise_error(RuntimeError, "kaboom")
      end

      it "should not emit any event" do
        dispatch_failing_action(NinjasController)
        expect(@controller_event_publisher.events_count).to eq 0
      end

      it "should leave no request id behind" do
        dispatch_failing_action(NinjasController)
        expect(Flu::CoreExt.flu_tracker_request_id).to be_nil
      end

      it "should leave no entity metadata behind" do
        dispatch_failing_action(SamuraisController)
        expect(Flu::CoreExt.flu_tracker_request_entity_metadata).to be_nil
      end

      it "should not attribute the next request to the failed one" do
        dispatch_failing_action(NinjasController)
        dispatch_to(NinjasController, :create)
        expect(published_controller_events.size).to eq 1
        expect(published_controller_events.first.data["requestId"]).to_not be_nil
      end
    end
  end
end
