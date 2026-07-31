require "active_support/core_ext/string/inflections"
require "active_support/core_ext/time/zones"

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

            before_action do
              define_request_id
              @request_start_time = Time.zone.now
            end
            prepend_before_action do
              define_request_entity_metadata_lambda(entity_metadata_lambda)
            end
            prepend_after_action do
              track_requests(event_factory, event_publisher, user_metadata_lambda, ignored_request_params, emitter_lambda)
              remove_request_entity_metadata_lambda
            end
            after_action do
              remove_request_id
            end

            def define_request_id
              request_id      = SecureRandom.uuid
              @flu_request_id = request_id
              Flu::CoreExt.flu_tracker_request_id = request_id
            end

            def remove_request_id
              Flu::CoreExt.flu_tracker_request_id = nil
            end

            def define_request_entity_metadata_lambda(entity_metadata_lambda)
              Flu::CoreExt.flu_tracker_request_entity_metadata = instance_exec(&entity_metadata_lambda) if entity_metadata_lambda
            end

            def remove_request_entity_metadata_lambda
              Flu::CoreExt.flu_tracker_request_entity_metadata = nil
            end

            def rejected_origin?(request)
              rejected_user_agents  = Regexp.union(Flu.config.rejected_user_agents)
              user_agent            = request.user_agent
              matching_user_agents  = user_agent&.match(rejected_user_agents)
              !matching_user_agents.nil?
            end

            def track_requests(event_factory, event_publisher, user_metadata_lambda, ignored_request_params, emitter_lambda)
              if rejected_origin?(request)
                logger.warn "Origin user agent rejected: #{request.user_agent}"
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
