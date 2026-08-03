require "bunny"
require "rabbitmq/http/client"
require "securerandom"

module RabbitmqHelper
  HOST            = ENV.fetch("FLU_RABBITMQ_HOST", "localhost")
  PORT            = Integer(ENV.fetch("FLU_RABBITMQ_PORT", "5672"))
  MANAGEMENT_PORT = Integer(ENV.fetch("FLU_RABBITMQ_MANAGEMENT_PORT", "15672"))
  USER            = ENV.fetch("FLU_RABBITMQ_USER", "flu")
  PASSWORD        = ENV.fetch("FLU_RABBITMQ_PASSWORD", "flu")
  REQUIRED        = !ENV["FLU_REQUIRE_RABBITMQ"].to_s.strip.empty?
  QUEUE_OPTIONS   = { durable: true, exclusive: false, auto_delete: false }.freeze

  class << self
    def available?
      probe if @available.nil?
      @available
    end

    def executed_examples
      @executed_examples ||= 0
    end

    def record_executed_example
      @executed_examples = executed_examples + 1
    end

    def unavailability_reason
      probe if @available.nil?
      @unavailability_reason
    end

    def address
      "#{HOST}:#{PORT} (management: #{HOST}:#{MANAGEMENT_PORT})"
    end

    # A configuration pointing at the broker, with an exchange of its own: no example may observe
    # the messages of another one, nor of a previous run left behind on the same broker.
    def configuration(overrides = {})
      configuration                            = Flu::Configuration.new
      configuration.logger                     = Logger.new(IO::NULL)
      configuration.application_name           = "flu_integration"
      configuration.development_environments   = []
      configuration.rejected_user_agents       = []
      configuration.rabbitmq_host              = HOST
      configuration.rabbitmq_vhost             = "/"
      configuration.rabbitmq_port              = PORT
      configuration.rabbitmq_user              = USER
      configuration.rabbitmq_password          = PASSWORD
      configuration.rabbitmq_management_scheme = "http"
      configuration.rabbitmq_management_port   = MANAGEMENT_PORT
      configuration.rabbitmq_exchange_name     = unique_name("exchange")
      configuration.rabbitmq_exchange_durable  = true
      configuration.bunny_options              = {}
      overrides.each { |name, value| configuration.public_send("#{name}=", value) }
      configuration
    end

    # 'automatically_recover' is off on purpose: a connection that recovers in the background turns
    # a broken broker into a hanging example instead of a failing one.
    def connection_options
      {
        host:                  HOST,
        port:                  PORT,
        user:                  USER,
        password:              PASSWORD,
        automatically_recover: false
      }
    end

    def open_connection
      connection = Bunny.new(connection_options.merge(logger: Logger.new(IO::NULL)))
      connection.start
      connection
    end

    def management_client
      RabbitMQ::HTTP::Client.new("http://#{HOST}:#{MANAGEMENT_PORT}/", username: USER, password: PASSWORD)
    end

    def unique_name(prefix)
      "flu-rails-spec-#{prefix}-#{SecureRandom.hex(6)}"
    end

    private

    def probe
      connection = Bunny.new(connection_options.merge(connection_timeout: 3,
                                                      continuation_timeout: 5_000,
                                                      logger: Logger.new(IO::NULL)))
      connection.start
      connection.close
      management_client.overview
      @available = true
    rescue StandardError => error
      @unavailability_reason = "#{error.class}: #{error.message}"
      @available             = false
    end
  end
end

RSpec.shared_context "a rabbitmq broker" do
  let(:configuration)        { RabbitmqHelper.configuration }
  let!(:consumer_connection) { @consumer_connection = RabbitmqHelper.open_connection }
  let(:consumer_channel)     { consumer_connection.create_channel }
  let(:management_client)    { RabbitmqHelper.management_client }

  def subscribe_to(routing_key = "#", exchange_name: configuration.rabbitmq_exchange_name)
    exchange = consumer_channel.topic(exchange_name, durable: configuration.rabbitmq_exchange_durable)
    queue    = consumer_channel.queue(RabbitmqHelper.unique_name("queue"), **RabbitmqHelper::QUEUE_OPTIONS)
    queue.bind(exchange, routing_key: routing_key)
    declared_exchange_names.push(exchange_name)
    declared_queues.push(queue)
    queue
  end

  def next_message_on(queue, timeout: 5)
    deadline = Time.now + timeout
    loop do
      delivery_info, properties, payload = queue.pop
      return [delivery_info, properties, payload] unless payload.nil?
      raise "no message on '#{queue.name}' after #{timeout}s" if Time.now > deadline
      sleep 0.05
    end
  end

  def message_count_on(queue, expected:, timeout: 2)
    deadline = Time.now + timeout
    sleep 0.05 while queue.message_count < expected && Time.now < deadline
    queue.message_count
  end

  def declared_queues
    @declared_queues ||= []
  end

  def declared_exchange_names
    @declared_exchange_names ||= [configuration.rabbitmq_exchange_name]
  end

  after(:each) do
    next if @consumer_connection.nil? || !@consumer_connection.open?
    declared_queues.each(&:delete)
    declared_exchange_names.uniq.each { |name| consumer_channel.exchange_delete(name) }
    @consumer_connection.close
  end
end
