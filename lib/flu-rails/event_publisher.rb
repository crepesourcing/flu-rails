# frozen_string_literal: true

require "bunny"
require_relative "errors"
require_relative "event"


module Flu
  class EventPublisher
    NOT_CONNECTED_MESSAGE = "no connection to RabbitMQ: 'connect' was never called, or " \
                            "'disconnect' was. The railtie calls it at boot unless " \
                            "'auto_connect_to_exchange' is false."
    CONNECTION_LOST_MESSAGE = "the connection to RabbitMQ is down. Bunny reopens it in the " \
                              "background when 'automatically_recover' is on, and publishing " \
                              "works again once it has."

    def initialize(configuration)
      @logger        = configuration.logger
      @configuration = configuration
      @mutex         = Mutex.new
    end

    def publish(event, persistent=true)
      routing_key = event.to_routing_key
      @logger.debug { "Publishing event with id '#{event.id}' with routing key: #{routing_key}" }
      exchange.publish(event.to_json, routing_key: routing_key, persistent: persistent)
      @logger.debug { "Event published." }
    rescue Bunny::ConnectionClosedError
      raise ConnectionLostError, CONNECTION_LOST_MESSAGE
    end

    def connect
      @mutex.synchronize do
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
    end

    def connected?
      !forked? && !@connection.nil? && @connection.open?
    end

    # Closing the connection closes every channel opened on it, and stops the heartbeat and
    # recovery threads Bunny runs alongside it.
    # The guard is on the connection alone: a connection that was opened before the exchange could
    # be declared still has to be closed.
    # An inherited connection is dropped rather than closed: its socket is the parent's.
    def disconnect
      @mutex.synchronize do
        @connection.close if connected?
        @connection = nil
        @pid        = nil
        Thread.current[exchange_key] = nil
      end
    end

    private

    # A child inherits the parent's socket but none of the threads Bunny runs on it.
    def forked?
      !@pid.nil? && @pid != Process.pid
    end

    # Per process too: a channel cached before the fork still reports itself open in the child.
    def exchange_key
      :"flu_exchange_#{object_id}_#{Process.pid}"
    end

    # One channel per thread rather than one for the whole publisher. 
    # Bunny serialises every publication on the channel's own mutex.
    #
    # No bookkeeping of the channels handed out is needed. 
    # Closing the connection closes all of them, so a thread holding a closed channel simply opens a new one on its next publication:
    # 'disconnect' and a reconnection are both covered without reaching into other threads.
    # A connection that is down is reported as such rather than left to 'create_channel', which
    # raises a bare 'RuntimeError' the caller has no way to tell from any other.
    def exchange
      connect if forked?
      cached = Thread.current[exchange_key]
      return cached if cached && cached.channel.open?
      raise NotConnectedError, NOT_CONNECTED_MESSAGE if @connection.nil?
      raise ConnectionLostError, CONNECTION_LOST_MESSAGE unless @connection.open?
      Thread.current[exchange_key] = declare_exchange
    end

    def declare_exchange
      channel = @connection.create_channel
      channel.topic(@configuration.rabbitmq_exchange_name,
                    durable: @configuration.rabbitmq_exchange_durable)
    end

    def connect_to_exchange
      options = {
        host:     @configuration.rabbitmq_host,
        vhost:    @configuration.rabbitmq_vhost,
        port:     @configuration.rabbitmq_port&.to_i,
        user:     @configuration.rabbitmq_user,
        password: @configuration.rabbitmq_password,
        automatically_recover: true
      }.merge(@configuration.bunny_options || {})

      @connection = Bunny.new(options)
      @connection.start
      @pid = Process.pid
      Thread.current[exchange_key] = declare_exchange
    end
  end
end
