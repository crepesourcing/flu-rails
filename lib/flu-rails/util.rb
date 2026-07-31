module Flu
  module Util
    class ExportService
      def export_existing_entities_to_events(event_publisher, event_factory, entity_types=nil)
        entity_types ||= find_all_tracked_entity_types(entity_types)
        check_that_all_entity_types_have_created_at(entity_types)

        Flu.logger.level             = Logger::WARN
        total_number_of_entity_types = entity_types.size
        current_entity_type_index    = 0
        entity_types.each do | entity_type |
          entities                     = entity_type.all
          total_number_of_entities     = entities.size
          current_entity_index         = 0
          current_entity_type_index   += 1
          association_columns          = entity_type.flu_association_columns
          user_metadata_lambda         = entity_type.flu_user_metadata_lambdas[:create]
          ignored_model_changes        = entity_type.flu_ignored_model_changes

          entities.each do |entity|
            print "\r"      unless current_entity_index == 0
            current_entity_index += 1
            print "#{entity_type} (#{current_entity_type_index}/#{total_number_of_entity_types}) : #{current_entity_index}/#{total_number_of_entities}"
            data            = extract_data_from(entity, event_factory, user_metadata_lambda, association_columns, ignored_model_changes)
            event           = event_factory.build_entity_change_event(data)
            event.timestamp = entity.created_at unless entity.created_at.nil?
            event_publisher.publish(event)
            print "\n"      if current_entity_index == total_number_of_entities
          end
        end
      end

      private

      def check_that_all_entity_types_have_created_at(entity_types)
        entity_types_without_timestamp = entity_types.select do | entity_type |
          !entity_type.attribute_names.include?("created_at")
        end
        if (entity_types_without_timestamp.size > 0)
          raise "#{entity_types_without_timestamp.size} entities do not have 'created_at': #{entity_types_without_timestamp.map {|type| type.name}}"
        end
      end

      def find_all_entity_types
        Rails.application.eager_load!
        ActiveRecord::Base.descendants
      end

      def find_all_tracked_entity_types(entity_types)
        (entity_types || find_all_entity_types).select do | entity_type |
          ActiveRecord::Base.connection.table_exists?(entity_type.table_name) && entity_type.flu_is_tracked
        end
      end

      def extract_data_from(entity, event_factory, user_metadata_lambda, association_columns, ignored_model_changes)
        changes = create_changes_from_existing(entity)
        event_factory.create_data_from_entity_changes(:create, entity, nil, nil, changes, user_metadata_lambda, association_columns, ignored_model_changes, nil)
      end

      def create_changes_from_existing(entity)
        changes = entity.attribute_names.inject({}) do | result, attribute_name |
          attribute_value             = entity.attributes[attribute_name]
          result[attribute_name.to_s] = [nil, attribute_value] unless attribute_value.nil?
          result
        end
        changes.except(:created_at, :updated_at)
      end
    end
  end
end
