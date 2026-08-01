require "bunny"
require_relative "event"


module Flu
  class EventPublisher
    def initialize(configuration)
      @logger        = configuration.logger
      @configuration = configuration
    end

    def publish(event, persistent=true)
      routing_key = event.to_routing_key
      @logger.debug("Publishing event with id '#{event.id}' with routing key: #{routing_key}")
      @exchange.publish(event.to_json, routing_key: routing_key, persistent: persistent)
      @logger.debug("Event published.")
    end

    def connect
      unless connected?
        connected = false
        while !connected
          begin
            connect_to_exchange
            connected = true
          rescue Bunny::TCPConnectionFailedForAllHosts
            @logger.warn("RabbitMQ connection failed, try again in 1 second.")
            sleep 1
          end
        end
      end
    end

    def connected?
      if @connection.nil? || @exchange.nil?
        false
      else
        @connection.open?
      end
    end

    # Closing the connection closes the channel opened on it, and stops the heartbeat and recovery
    # threads Bunny runs alongside it.
    # The guard is on the connection alone, not on 'connected?': a connection that was opened before
    # the exchange could be declared still has to be closed.
    def disconnect
      if !@connection.nil? && @connection.open?
        @connection.close 
      end
      @connection = nil
      @channel    = nil
      @exchange   = nil
    end

    private

    def connect_to_exchange
      options = {
        host:     @configuration.rabbitmq_host,
        port:     @configuration.rabbitmq_port&.to_i,
        user:     @configuration.rabbitmq_user,
        password: @configuration.rabbitmq_password,
        automatically_recover: true
      }.merge(@configuration.bunny_options || {})
      
      @connection = Bunny.new(options)
      @connection.start
      @channel  = @connection.create_channel
      @exchange = @channel.send(:topic,
                                @configuration.rabbitmq_exchange_name,
                                durable: @configuration.rabbitmq_exchange_durable)
    end
  end
end
