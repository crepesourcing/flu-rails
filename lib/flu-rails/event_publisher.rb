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
    CONNECTION_FAILED_MESSAGE = "could not reach RabbitMQ within %s seconds. Publishing reopens " \
                                "the connection itself once the broker answers again."
    RECONNECTION_INTERVAL = 5

    def initialize(configuration)
      @logger          = configuration.logger
      @configuration   = configuration
      @mutex           = Mutex.new
      @next_attempt_at = 0
      @exchanges       = {}
      @exchanges_mutex = Mutex.new
    end

    def publish(event, persistent=true)
      routing_key = event.to_routing_key
      @logger.debug { "Publishing event with id '#{event.id}' with routing key: #{routing_key}" }
      exchange.publish(event.to_json, routing_key: routing_key, persistent: persistent)
      @logger.debug { "Event published." }
    rescue Bunny::ConnectionClosedError
      raise ConnectionLostError, CONNECTION_LOST_MESSAGE
    end

    # Retries a broker that is not there yet, for at most 'max_connect_wait' seconds. Waiting on it
    # forever would hold whatever called it -- the railtie calls it from 'to_prepare', which runs on
    # every code reload, holding the reload interlock and the request that triggered it.
    def connect
      @mutex.synchronize do
        next if connected?
        give_up_at = deadline
        begin
          connect_to_exchange
        rescue Bunny::TCPConnectionFailedForAllHosts
          raise ConnectionLostError, format(CONNECTION_FAILED_MESSAGE, @configuration.max_connect_wait) if expired?(give_up_at)
          @logger.warn("RabbitMQ connection failed, try again in 1 second.")
          sleep 1
          retry
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
        forget_exchanges
      end
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A nil 'max_connect_wait' waits on the broker for however long it takes.
    def deadline
      @configuration.max_connect_wait.nil? ? nil : now + @configuration.max_connect_wait
    end

    def expired?(give_up_at)
      !give_up_at.nil? && now >= give_up_at
    end

    # A connection Bunny is recovering comes back on its own. One that never opened, or that Bunny
    # has given up on, comes back from here or not at all.
    def abandoned?
      return false if @connection.nil? || @connection.open?
      !@connection.recovering_from_network_failure? &&
        (!@connection.automatically_recover? ||
         @connection.closed? ||
         @connection.status == :not_connected)
    end

    # A broker that hangs rather than refuses costs a full Bunny 'connect_timeout' per attempt, so
    # publishing pays for one at most every 'RECONNECTION_INTERVAL' seconds.
    def due_for_another_attempt?
      return false if now < @next_attempt_at
      @next_attempt_at = now + RECONNECTION_INTERVAL
      true
    end

    # Reopening is best effort: the caller is publishing, and an event that cannot go out is
    # reported through the connection errors below rather than through whatever the broker refused.
    def reconnect
      @mutex.synchronize { connect_to_exchange unless connected? }
    rescue StandardError => error
      @logger.warn("Could not reopen the connection to RabbitMQ: #{error.class}: #{error.message}")
    end

    # A child inherits the parent's socket but none of the threads Bunny runs on it.
    def forked?
      !@pid.nil? && @pid != Process.pid
    end

    # One channel per thread, kept in '@exchanges' (thread => exchange).
    #
    # Why not 'Thread.current[]': it is per fiber, not per thread, and a channel stored there is
    # never closed when the thread ends. RabbitMQ allows 2047 channels per connection, so a server
    # that keeps creating and ending threads hit that limit after a day and could not publish
    # from any new thread. Now, each time a channel is opened, the channels of the threads that
    # have ended are closed.
    #
    # Until then, '@exchanges' still references the ended threads and what
    # their thread-local variables hold: a weak reference would lose the channel before it is closed.
    #
    # A thread whose channel is closed opens a new one on its next publication.
    # That is what makes 'disconnect' and a reconnection safe.
    # A connection that is down is reported as such rather than left to 'create_channel', which
    # raises a bare 'RuntimeError' the caller has no way to tell from any other.
    # The connection is checked before the cached channel: Bunny marks the channels open before it
    # announces it is done, so a thread that read its channel closed, then the announcement, would
    # open one more.
    def exchange
      reconnect if forked? || (abandoned? && due_for_another_attempt?)
      raise NotConnectedError, NOT_CONNECTED_MESSAGE if @connection.nil?
      raise ConnectionLostError, CONNECTION_LOST_MESSAGE unless @connection.open?
      raise ConnectionLostError, CONNECTION_LOST_MESSAGE if being_reopened?
      cached = @exchanges_mutex.synchronize { @exchanges[Thread.current] }
      return cached if cached && cached.channel.open?
      remember_exchange(declare_exchange)
    end

    # Bunny reopens the connection first, then the channels it had on it. A channel opened in between
    # stays open on the broker with no thread to use it, and the session does not show that window:
    # 'open?' is true as soon as the socket is. Bunny announces each recovery attempt and its
    # completion instead. The session is kept rather than a flag: a child process inherits the flag
    # of a connection its parent was reopening, and opens one of its own.
    # Bunny holds one callback of each: the ones the application gave in 'bunny_options' are called
    # from here.
    def hold_publishing_while_bunny_reopens(session, options)
      started   = options[:recovery_attempt_started]
      completed = options[:recovery_completed]
      session.before_recovery_attempt_starts { @being_reopened = session; started&.call }
      session.after_recovery_completed { @being_reopened = nil if @being_reopened.equal?(session); completed&.call }
    end

    def being_reopened?
      @being_reopened&.equal?(@connection)
    end

    def remember_exchange(exchange)
      ended = @exchanges_mutex.synchronize do
        @exchanges[Thread.current] = exchange
        @exchanges.keys.reject(&:alive?).map { |thread| @exchanges.delete(thread) }
      end

      unless ended.empty?
        @logger.debug { "Closing the channels of #{ended.size} threads that have ended." }
      end

      ended.each { |orphan| close_channel(orphan.channel) }
      exchange
    end

    # Forgets the channels without closing them.
    # Their connection is gone: closed by 'disconnect',
    # lost, or inherited from a parent process
    # (closing that one would close the parent's socket).
    def forget_exchanges
      @exchanges_mutex.synchronize { @exchanges.clear }
    end

    # Closing may fail (the broker may have closed the channel already). That is fine: the thread
    # is gone, and the publication in progress must not fail because of it.
    def close_channel(channel)
      channel.close if channel.open?
    rescue StandardError => error
      @logger.debug { "Could not close the channel of an ended thread: #{error.class}: #{error.message}" }
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

      # Before 'start': when it fails, the channels of the previous connection must be gone already,
      # or the forking thread would publish on the parent's channel in a child that has no broker.
      forget_exchanges
      @connection = Bunny.new(options)
      hold_publishing_while_bunny_reopens(@connection, options)
      @connection.start
      @pid = Process.pid
      remember_exchange(declare_exchange)
    end
  end
end
