require "active_support/configurable"

module Flu
  class Configuration
    include ActiveSupport::Configurable
    config_accessor :development_environments
    config_accessor :rejected_user_agents
    config_accessor :logger
    config_accessor :rabbitmq_host
    config_accessor :rabbitmq_management_scheme
    config_accessor :rabbitmq_management_port
    config_accessor :rabbitmq_port
    config_accessor :rabbitmq_user
    config_accessor :rabbitmq_password
    config_accessor :rabbitmq_exchange_name
    config_accessor :rabbitmq_exchange_durable
    config_accessor :auto_connect_to_exchange
    config_accessor :default_ignored_model_changes
    config_accessor :default_ignored_request_params
    config_accessor :application_name
    config_accessor :bunny_options
  end
end
