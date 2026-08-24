# frozen_string_literal: true

require "logger"
require "json"
require "active_support/core_ext/module/introspection"
require_relative "flu-rails/version"
require_relative "flu-rails/errors"
require_relative "flu-rails/event"
require_relative "flu-rails/event_factory"
require_relative "flu-rails/queue_repository"
require_relative "flu-rails/configuration"
require_relative "flu-rails/core_ext"
require_relative "flu-rails/transaction_buffer"
require_relative "flu-rails/pending_publications"
require_relative "flu-rails/event_publisher"
require_relative "flu-rails/util"
require_relative "flu-rails/dummy/in_memory_event_publisher"
require_relative "flu-rails/railtie" if defined?(Rails::Railtie)

module Flu
  def self.configure
    yield @configuration ||= Flu::Configuration.new
  end

  def self.config
    @configuration
  end

  def self.logger
    @logger
  end

  def self.event_factory
    @event_factory
  end

  def self.event_publisher
    @event_publisher
  end

  # Keeps an event whose publication failed for another attempt, a broker being reachable again
  # within seconds. One that could not even be built is reported at once instead.
  def self.publication_failed(event, error, event_publisher)
    if event.nil?
      report_publication_failure(event, error) 
    else
      PendingPublications.current.push(event, event_publisher, error)
    end
  end

  # Publishes again what the last attempt could not. Never raises: its callers are a transaction that
  # has committed and the end of a request, neither of which is a place to fail.
  def self.retry_pending_publications
    PendingPublications.current.drain
  rescue StandardError => error
    config.logger&.error("Flu could not retry the publications it had kept: #{error.class}: #{error.message}")
  end

  # @param event [Flu::Event, nil] nil when the event could not even be built.
  def self.report_publication_failure(event, error)
    handler = config.on_publication_failure
    if handler.nil?
      subject = event.nil? ? "an event it could not build" : "the event '#{event.id}' ('#{event.name}')"
      config.logger&.error("Flu could not publish #{subject}: #{error.class}: #{error.message}. " \
                           "The event is lost unless 'on_publication_failure' is configured to keep it.")
    else
      handler.call(event, error) 
    end
  end

  def self.init
    @configuration.application_name ||= default_application_name
    raise "configuration.application_name must not be nil" if @configuration.application_name.nil?
    @logger          = @configuration.logger
    @event_factory   = Flu::EventFactory.new(@configuration)
    @event_publisher = create_event_publisher(@configuration)
    extend_models_and_controllers
  end

  def self.default_application_name
    if defined?(Rails) && Rails.respond_to?(:application)
      application = Rails.application
      application.nil? ? nil : application.class.module_parent_name
    else
      nil
    end
  end

  # The railtie re-runs 'init' on every code reload. Building a new publisher on each of them left
  # every reference the application had already taken on the previous one -- a tracked model
  # publishes through the very publisher it was tracked with -- on a connection 'init' had closed
  # and that nothing ever reopens. The publisher outlives the reloads, and only a change of kind
  # replaces it: its connection, its channels and Bunny's heartbeat thread are then closed with it.
  def self.create_event_publisher(configuration)
    publisher_class = event_publisher_class
    return @event_publisher if @event_publisher.instance_of?(publisher_class)

    @event_publisher&.disconnect
    if publisher_class == Flu::Dummy::InMemoryEventPublisher
      logger.info("Loading Flu with a dummy event publisher (this will not connect any exchange)")
    end
    publisher_class.new(configuration)
  end

  def self.event_publisher_class
    is_testing_environment? ? Flu::Dummy::InMemoryEventPublisher : Flu::EventPublisher
  end

  def self.is_testing_environment?
    # 'defined?(Rails)' alone is not enough: gems such as 'rails-html-sanitizer' define an empty
    # 'Rails' namespace, so the constant can exist without railties ever defining 'Rails.env'.
    return false unless defined?(Rails) && Rails.respond_to?(:env)
    config.development_environments.include?(Rails.env)
  end

  def self.extend_models_and_controllers
    Flu::CoreExt.extend_model_classes(@event_factory, @event_publisher)
    Flu::CoreExt.extend_controller_classes(@event_factory, @event_publisher, @logger)
  end

  # A broker that is not there yet must not keep the application from booting: publishing reopens
  # the connection itself once the broker answers again.
  def self.start
    return unless config.auto_connect_to_exchange
    @event_publisher.connect
  rescue Flu::ConnectionLostError => error
    config.logger&.error("Flu could not connect to RabbitMQ: #{error.message}")
  end

  def self.load_configuration
    configure do |config|
      config.development_environments       = []
      config.rejected_user_agents           = []
      config.logger                         = ::Logger.new(STDOUT)
      config.rabbitmq_host                  = "localhost"
      config.rabbitmq_vhost                 = "/"
      config.rabbitmq_port                  = 5672
      config.rabbitmq_management_scheme     = "http"
      config.rabbitmq_management_port       = 15672
      config.rabbitmq_user                  = ""
      config.rabbitmq_password              = ""
      config.rabbitmq_exchange_name         = "events"
      config.rabbitmq_exchange_durable      = true
      config.auto_connect_to_exchange       = true
      config.default_ignored_model_changes  = [:password, :password_confirmation, :created_at, :updated_at]
      config.default_ignored_request_params = [:password, :password_confirmation, :controller, :action]
      config.application_name               = nil
      config.bunny_options                  = {}
      config.on_publication_failure         = nil
      config.max_pending_events             = 1000
      config.max_connect_wait               = 30
    end
  end

  load_configuration
end
