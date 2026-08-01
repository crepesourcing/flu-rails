require "active_support/core_ext/string/inflections"
require "active_support/core_ext/time/zones"
require "random/formatter"
require "securerandom"

module Flu
  class ActionControllerExtender
    def self.extend_controllers(event_factory, event_publisher, logger)
      all_controller_types.each do |controller_type|
        controller_type.class_eval do
          def self.flu_is_tracked=(is_tracked)
            @flu_is_tracked = is_tracked
          end

          def self.flu_is_tracked
            @flu_is_tracked || false
          end 

          define_singleton_method(:track_requests) do |options = {}|
            self.flu_is_tracked      = true
            user_metadata_lambda     = options[:user_metadata]
            entity_metadata_lambda   = options[:entity_metadata]
            ignored_request_params   = options.fetch(:ignored_request_params, []).map(&:to_sym)
            emitter_lambda           = options[:emitter]

            # These helpers are defined with 'define_method' rather than 'def' for two reasons. A bare
            # 'def' opens a new scope, so it captures neither 'logger' nor the tracking options: the
            # former silently resolved to ActionController::Base#logger, which ignored 'Flu.config.logger'
            # altogether. And its default definee is the class 'class_eval' was called on, so the helpers
            # landed on ActionController::Base itself, leaking onto every controller of the host
            # application. Here 'self' is the class calling 'track_requests', which is where they belong.
            define_method(:flu_define_request_id) do
              request_id      = Random.respond_to?(:uuid_v7) ? Random.uuid_v7 : SecureRandom.uuid
              @flu_request_id = request_id
              Flu::CoreExt.flu_tracker_request_id = request_id
            end

            define_method(:flu_remove_request_id) do
              Flu::CoreExt.flu_tracker_request_id = nil
            end

            define_method(:flu_define_request_entity_metadata) do
              Flu::CoreExt.flu_tracker_request_entity_metadata = instance_exec(&entity_metadata_lambda) if entity_metadata_lambda
            end

            define_method(:flu_remove_request_entity_metadata) do
              Flu::CoreExt.flu_tracker_request_entity_metadata = nil
            end

            define_method(:flu_rejected_origin?) do
              rejected_user_agents = Regexp.union(Flu.config.rejected_user_agents)
              !request.user_agent&.match(rejected_user_agents).nil?
            end

            define_method(:flu_track_request) do
              if flu_rejected_origin?
                logger.warn("Origin user agent rejected: #{request.user_agent}")
              else
                tracked_request                     = event_factory.create_data_from_request(@flu_request_id,
                                                                                             params,
                                                                                             request,
                                                                                             response,
                                                                                             @request_start_time,
                                                                                             ignored_request_params)
                tracked_request[:user_metadata]     = instance_exec(&user_metadata_lambda) if user_metadata_lambda
                tracked_request[:overriden_emitter] = instance_exec(&emitter_lambda) if emitter_lambda
                event                               = event_factory.build_request_event(tracked_request)
                event_publisher.publish(event)
              end
            end

            before_action do
              flu_define_request_id
              @request_start_time = Time.zone.now
            end
            prepend_before_action do
              flu_define_request_entity_metadata
            end
            prepend_after_action do
              flu_track_request
              flu_remove_request_entity_metadata
            end
            after_action do
              flu_remove_request_id
            end
          end
        end
      end
    end

    private

    def self.all_controller_types
      class_names = ["ActionController::Base", "ActionController::API"]
      class_names.select { |class_name| Object.const_defined?(class_name) }.map(&:constantize)
    end
  end
end
