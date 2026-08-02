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
require_relative "flu-rails/event_publisher"
require_relative "flu-rails/util"
require_relative "flu-rails/dummy/in_memory_event_publisher"
require_relative "flu-rails/railtie" if defined?(Rails)

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

  def self.init
    @configuration.application_name ||= default_application_name
    raise "configuration.application_name must not be nil" if @configuration.application_name.nil?
    @logger          = @configuration.logger
    @event_factory   = Flu::EventFactory.new(@configuration)
    # The railtie re-runs 'init' on every code reload. The publisher being replaced owns an open
    # connection, its channel and Bunny's heartbeat thread: dropping the reference to it without
    # closing it leaks all three for the lifetime of the process.
    @event_publisher&.disconnect
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

  def self.create_event_publisher(configuration)
    if is_testing_environment?
      logger.info("Loading Flu with a dummy event publisher (this will not connect any exchange)")
      require_relative "flu-rails/dummy/in_memory_event_publisher"
      Flu::Dummy::InMemoryEventPublisher.new(@configuration)
    else
      Flu::EventPublisher.new(@configuration)
    end
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

  def self.start
    @event_publisher.connect if config.auto_connect_to_exchange
  end

  def self.load_configuration
    configure do |config|
      config.development_environments       = []
      config.rejected_user_agents           = []
      config.logger                         = ::Logger.new(STDOUT)
      config.rabbitmq_host                  = "localhost"
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
    end
  end

  load_configuration
end
