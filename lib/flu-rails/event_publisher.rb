# frozen_string_literal: true

require "bunny"
require_relative "event"


module Flu
  class EventPublisher
    def initialize(configuration)
      @logger        = configuration.logger
      @configuration = configuration
      @exchange_key  = :"flu_exchange_#{object_id}" # Channels are cached per thread
    end

    def publish(event, persistent=true)
      routing_key = event.to_routing_key
      @logger.debug("Publishing event with id '#{event.id}' with routing key: #{routing_key}")
      exchange.publish(event.to_json, routing_key: routing_key, persistent: persistent)
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
      !@connection.nil? && @connection.open?
    end

    # Closing the connection closes every channel opened on it, and stops the heartbeat and
    # recovery threads Bunny runs alongside it.
    # The guard is on the connection alone: a connection that was opened before the exchange could
    # be declared still has to be closed.
    def disconnect
      if !@connection.nil? && @connection.open?
        @connection.close
      end
      @connection = nil
      Thread.current[@exchange_key] = nil
    end

    private

    # One channel per thread rather than one for the whole publisher. 
    # Bunny serialises every publication on the channel's own mutex.
    #
    # No bookkeeping of the channels handed out is needed. 
    # Closing the connection closes all of them, so a thread holding a closed channel simply opens a new one on its next publication:
    # 'disconnect' and a reconnection are both covered without reaching into other threads.
    def exchange
      cached = Thread.current[@exchange_key]
      return cached if cached && cached.channel.open?
      Thread.current[@exchange_key] = declare_exchange
    end

    def declare_exchange
      channel = @connection.create_channel
      channel.topic(@configuration.rabbitmq_exchange_name,
                    durable: @configuration.rabbitmq_exchange_durable)
    end

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
      Thread.current[@exchange_key] = declare_exchange
    end
  end
end
