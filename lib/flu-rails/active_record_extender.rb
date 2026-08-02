# frozen_string_literal: true

require "active_support/core_ext/object/try"

module Flu
  class ActiveRecordExtender
    def self.extend_models(event_factory, event_publisher)
      ActiveRecord::Base.class_eval do
        unless singleton_class.method_defined?(:flu_is_tracked)
          class_attribute :flu_is_tracked,               instance_accessor: false, default: false
          class_attribute :flu_user_metadata_lambdas,    instance_accessor: false, default: {}.freeze
          class_attribute :flu_ignored_model_changes,    instance_accessor: false, default: [].freeze
          class_attribute :flu_overriden_emitter_lambda, instance_accessor: false, default: nil
        end

        define_singleton_method(:track_entity_changes) do |options = {}|
          self.flu_is_tracked               = true
          self.flu_user_metadata_lambdas    = options.fetch(:user_metadata, {})
          self.flu_ignored_model_changes    = options.fetch(:ignored_model_changes, []).map(&:to_s)
          self.flu_overriden_emitter_lambda = options.fetch(:emitter, nil)
        
          after_create   { flu_track_entity_change(:create, saved_changes, event_factory) }
          after_update   { flu_track_entity_change(:update, saved_changes, event_factory) }
          after_destroy  { flu_track_entity_change(:destroy, { "id" => [id, nil] }, event_factory) }
          after_commit   { flu_commit_changes(event_factory, event_publisher) }
          after_rollback { flu_rollback_changes }
        end

        def self.flu_association_columns
          @flu_association_columns ||= reflect_on_all_associations(:belongs_to).flat_map do |association|
            column_names = [association.foreign_key]
            column_names.push(association.foreign_type) if association.polymorphic?
            column_names
          end
        end

        def flu_changes
          @flu_changes ||= []
        end

        def flu_publish_events!
          run_callbacks(:commit)
        end

        def flu_add_manual_event(name, data)
          raise "data must be a hash" if data.nil? || !data.is_a?(Hash)
          flu_changes.push({
            name: name,
            data: data,
            flu_is_a_manual_event: true
          })
        end

        def flu_changes_as_events(event_factory)
          flu_changes.select do |data|
            !data[:changes].try(:empty?) || data[:flu_is_a_manual_event]
          end.map do |data|
            if data[:flu_is_a_manual_event]
              event_factory.build_manual_event(data[:name], data[:data])
            else
              event_factory.build_entity_change_event(data)
            end
          end
        end

        def flu_commit_changes(event_factory, event_publisher)
          flu_changes_as_events(event_factory).each do |event|
            event_publisher.publish(event)
          end
          flu_flush_changes
        end

        def flu_rollback_changes
          flu_flush_changes
        end

        def flu_flush_changes
          flu_changes.clear
        end

        def flu_track_entity_change(action_name, changes, event_factory)
          unless changes.empty?
            request_id                     = Flu::CoreExt.flu_tracker_request_id
            request_entity_metadata        = Flu::CoreExt.flu_tracker_request_entity_metadata
            data                           = event_factory.create_data_from_entity_changes(action_name,
                                                                                           self,
                                                                                           request_id,
                                                                                           request_entity_metadata,
                                                                                           changes,
                                                                                           self.class.flu_user_metadata_lambdas[action_name],
                                                                                           self.class.flu_association_columns,
                                                                                           self.class.flu_ignored_model_changes,
                                                                                           self.class.flu_overriden_emitter_lambda)
            flu_changes.push(data) unless data.nil?
          end
        end
      end
    end
  end
end
