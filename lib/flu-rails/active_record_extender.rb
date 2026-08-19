# frozen_string_literal: true

require "active_support/core_ext/object/try"
require "active_support/notifications"

module Flu
  class ActiveRecordExtender
    def self.extend_models(event_factory, event_publisher)
      publish_on_transaction_commit

      ActiveRecord::Base.class_eval do
        unless singleton_class.method_defined?(:flu_is_tracked)
          class_attribute :flu_is_tracked,               instance_accessor: false, default: false
          class_attribute :flu_user_metadata_lambdas,    instance_accessor: false, default: {}.freeze
          class_attribute :flu_ignored_model_changes,    instance_accessor: false, default: [].freeze
          class_attribute :flu_overriden_emitter_lambda, instance_accessor: false, default: nil
          # Held per model rather than looked up on 'Flu', so that the publication driven by the
          # transaction reaches the very publisher the model was tracked with.
          class_attribute :flu_event_factory,            instance_accessor: false, default: nil
          class_attribute :flu_event_publisher,          instance_accessor: false, default: nil
        end

        define_singleton_method(:track_entity_changes) do |options = {}|
          self.flu_is_tracked               = true
          self.flu_user_metadata_lambdas    = options.fetch(:user_metadata, {})
          self.flu_ignored_model_changes    = options.fetch(:ignored_model_changes, []).map(&:to_s)
          self.flu_overriden_emitter_lambda = options.fetch(:emitter, nil)
          self.flu_event_factory            = event_factory
          self.flu_event_publisher          = event_publisher
        
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

        # Defined with 'define_method' rather than 'def', for the same reason as the tracking
        # helpers in 'ActionControllerExtender#extend_controllers': a bare 'def' opens a new scope
        # and would not close over 'event_factory' and 'event_publisher'. 
        #
        # Without them, publishing manually had no way to call 'flu_commit_changes' directly,
        # and used 'run_callbacks(:commit)' instead, which runs *every* 'after_commit' callback on the record, 
        # including the hoste application's own (mailers, jobs, cache invalidation), not just Flu's.
        define_method(:flu_publish_events!) do
          flu_commit_changes(self.class.flu_event_factory   || event_factory,
                             self.class.flu_event_publisher || event_publisher)
        end

        def flu_add_manual_event(name, data)
          raise "data must be a hash" if data.nil? || !data.is_a?(Hash)
          flu_changes.push({
            name: name,
            data: data,
            flu_is_a_manual_event: true
          })
          Flu::TransactionBuffer.current.record(self) if self.class.flu_is_tracked
        end

        def flu_changes_as_events(event_factory)
          flu_publishable_changes.map { |change| flu_change_as_event(change, event_factory) }
        end

        def flu_publishable_changes
          flu_changes.select do |change|
            !change[:changes].try(:empty?) || change[:flu_is_a_manual_event]
          end
        end

        def flu_change_as_event(change, event_factory)
          if change[:flu_is_a_manual_event]
            event_factory.build_manual_event(change[:name], change[:data])
          else
            event_factory.build_entity_change_event(change)
          end
        end

        # Every change is built and published on its own: one that cannot be is reported and the next
        # one goes out all the same, where a raise would take the whole rest of the batch with it.
        def flu_commit_changes(event_factory, event_publisher)
          flu_publishable_changes.each do |change|
            event = flu_change_as_event(change, event_factory)
            event_publisher.publish(event)
          rescue StandardError => error
            Flu.publication_failed(event, error, event_publisher)
          end
        ensure
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
            return if data.nil?
            flu_changes.push(data)
            Flu::TransactionBuffer.current.record(self)
          end
        end
      end
    end

    # The commit of the transaction, unlike the 'after_commit' callbacks that follow it, is a moment
    # Rails cannot skip: the notification is emitted once the COMMIT is through and before the first
    # callback runs, so no callback raising afterwards can cost anybody their events.
    def self.publish_on_transaction_commit
      unless @subscribed
        @subscribed = true

        ActiveSupport::Notifications.subscribe("start_transaction.active_record") do |*, payload|
          TransactionBuffer.current.transaction_started if joinable?(payload)
        end

        ActiveSupport::Notifications.subscribe("transaction.active_record") do |*, payload|
          next unless joinable?(payload)

          buffer = TransactionBuffer.current
          if payload[:outcome] == :commit
            buffer.transaction_committed.each do |entity|
              # Nothing may travel from here into the commit that is calling us.
              entity.flu_commit_changes(entity.class.flu_event_factory, entity.class.flu_event_publisher)
            rescue StandardError => error
              Flu.config.logger&.error("Flu could not build the events of #{entity.class}: " \
                                      "#{error.class}: #{error.message}")
            end
            Flu.retry_pending_publications
          else
            buffer.transaction_rolled_back.each(&:flu_rollback_changes)
          end
        end
      end
    end

    # A transaction opened as non-joinable, such as the one 'use_transactional_tests' wraps an
    # example in, is rolled back rather than committed and only its savepoints publish anything.
    def self.joinable?(payload)
      !payload[:transaction].equal?(ActiveRecord::Transaction::NULL_TRANSACTION)
    end
  end
end
