require "securerandom"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/time/zones"
require_relative "event"

module Flu
  class EventFactory
    def initialize(configuration)
      @logger                         = configuration.logger
      @configuration                  = configuration
      @emitter                        = configuration.application_name
      @default_ignored_model_changes  = configuration.default_ignored_model_changes.map(&:to_s)
      @default_ignored_request_params = configuration.default_ignored_request_params
    end

    def build_request_event(data)
      raise ArgumentError, "data must not be nil"              if data.nil?
      raise ArgumentError, "data must have an action_name"     if !data.has_key?(:action_name) || data[:action_name].empty?
      raise ArgumentError, "data must have an controller_name" if !data.has_key?(:controller_name) || data[:controller_name].empty?
      name  = "request to #{data[:action_name]} #{data[:controller_name]}"
      event = build_event(name, :request, data)
      @logger.debug("Track action: #{JSON.pretty_generate(event)}")
      event
    end

    def build_entity_change_event(data)
      raise ArgumentError, "data must not be nil"          if data.nil?
      raise ArgumentError, "data must have changes"        if !data.has_key?(:changes) || data[:changes].empty?
      raise ArgumentError, "data must have an action_name" if !data.has_key?(:action_name) || data[:action_name].empty?
      raise ArgumentError, "data must have an entity_name" if !data.has_key?(:entity_name) || data[:entity_name].empty?
      name  = "#{data[:action_name]} #{data[:entity_name]}"
      event = build_event(name, :entity_change, data)
      @logger.debug("Track change: " + JSON.pretty_generate(event))
      event
    end

    def build_manual_event(name, data)
      raise ArgumentError, "data must not be nil"          if data.nil?
      raise ArgumentError, "data must be a hash"           if !data.is_a?(Hash)
      raise ArgumentError, "name must not be nil or empty" if name.nil? || name.empty?
      event = build_event(name.to_s, :manual, data)
      @logger.debug("Track manual: " + JSON.pretty_generate(event))
      event
    end

    def build_event(name, kind, data)
      original_emitter  = @emitter
      overriden_emitter = data[:overriden_emitter]&.strip&.delete(".")
      final_emitter     = overriden_emitter.blank? ? original_emitter : overriden_emitter
      # 'overriden_emitter' selects the emitter of the event, it is not part of what is tracked:
      # it is dropped from the payload instead of being published as an 'overridenEmitter' key.
      Event.new(SecureRandom.uuid, final_emitter, kind, name, deep_camelize(data.except(:overriden_emitter)))
    end

    def create_data_from_entity_changes(action_name, entity, request_id, request_entity_metadata, changes, user_metadata_lambda, association_columns, ignored_model_changes, flu_overriden_emitter_lambda)
      {
        entity_id:         entity.id,
        entity_name:       entity.class.name.underscore,
        overriden_emitter: flu_overriden_emitter_lambda ? entity.instance_exec(&flu_overriden_emitter_lambda) : nil,
        request_id:        request_id,
        request_metadata:  request_entity_metadata.nil? ? {} : request_entity_metadata,
        action_name:       action_name,
        changes:           changes.except(*ignored_model_changes).except(*@default_ignored_model_changes),
        user_metadata:     user_metadata_lambda ? entity.instance_exec(&user_metadata_lambda) : {},
        associations:      extract_associations_from(entity, association_columns)
      }
    end

    def create_data_from_request(request_id, params, request, response, request_start_time, ignored_request_params)
      {
        request_id:      request_id,
        controller_name: params[:controller],
        action_name:     params[:action],
        path:            request.original_fullpath,
        response_code:   response.status,
        user_agent:      request.user_agent,
        duration:        Time.zone.now - request_start_time,
        params:          extract_params(params, ignored_request_params)
      }
    end

    private

    def extract_params(params, ignored_request_params)
      remaining = params.except(*ignored_request_params).except(*@default_ignored_request_params)
      remaining.respond_to?(:to_unsafe_h) ? remaining.to_unsafe_h.to_h : remaining.to_h
    end

    def deep_camelize(value)
      case value
      when Array
        value.map { |v| deep_camelize v }
      when Hash
        value.reduce({}) do |camelized_hash, (k,v)|
          camelized_hash[camelize(sanitize(k.to_s), false)] = deep_camelize v
          camelized_hash
        end
      else
        sanitize(value)
      end
    end

    def camelize(lower_case_and_underscored_word, first_letter_in_uppercase = true)
      if first_letter_in_uppercase
        lower_case_and_underscored_word.to_s.gsub(/\/(.?)/) { "::" + $1.upcase }.gsub(/(^|_)(.)/) { $2.upcase }
      else
        (lower_case_and_underscored_word[0] || "") + camelize(lower_case_and_underscored_word)[1..-1]
      end
    end

    def extract_associations_from(entity, association_columns)
      association_columns.reduce({}) do |associations, column_name|
        associations[column_name] = entity[column_name]
        associations
      end
    end

    def sanitize(value)
      if value.respond_to?(:encode)
        value.encode("UTF-8", invalid: :replace, undef: :replace).delete("\u0000")
      else
        value
      end
    end
  end
end
