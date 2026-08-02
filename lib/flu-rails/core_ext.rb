# frozen_string_literal: true

require_relative "active_record_extender"
require_relative "action_controller_extender"

module Flu
  class CoreExt
    def self.extend_model_classes(event_factory, event_publisher)
      ActiveRecordExtender.extend_models(event_factory, event_publisher)
    end

    def self.extend_controller_classes(event_factory, event_publisher, logger)
      ActionControllerExtender.extend_controllers(event_factory, event_publisher, logger)
    end

    def self.flu_tracker_request_id=(value)
      Thread.current[:flu_tracker_request_id] = value
    end

    def self.flu_tracker_request_id
      Thread.current[:flu_tracker_request_id]
    end

    def self.flu_tracker_request_entity_metadata=(value)
      Thread.current[:flu_tracker_request_entity_metadata] = value
    end

    def self.flu_tracker_request_entity_metadata
      Thread.current[:flu_tracker_request_entity_metadata]
    end
  end
end
