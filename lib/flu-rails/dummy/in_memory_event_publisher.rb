# frozen_string_literal: true

module Flu
  module Dummy
    class InMemoryEventPublisher < Flu::EventPublisher
      
      attr_reader :published_events_by_routing_key, :ordered_published_event_routing_keys
  
      def initialize(configuration)
        @logger                               = configuration.logger
        @configuration                        = configuration
        @published_events_by_routing_key      = {}
        @ordered_published_event_routing_keys = []
      end
  
      def publish(event, persistent=true)
        routing_key                                    = event.to_routing_key
        published_events_by_routing_key[routing_key] ||= []
        published_events_by_routing_key[routing_key].push(event)
        @ordered_published_event_routing_keys.push(routing_key)
      end
  
      def connect
      end

      def connected?
        true
      end

      def disconnect
      end

      def events_count
        @published_events_by_routing_key.map do | key, value |
          value.size
        end.sum
      end
  
      def fetch_events(routing_key)
        @published_events_by_routing_key[routing_key]
      end
  
      def clear
        @published_events_by_routing_key      = {}
        @ordered_published_event_routing_keys = []
      end
    end
  end
end
