# frozen_string_literal: true

module Flu
  class Configuration
    attr_accessor :development_environments,
                  :rejected_user_agents,
                  :logger,
                  :rabbitmq_host,
                  :rabbitmq_vhost,
                  :rabbitmq_management_scheme,
                  :rabbitmq_management_port,
                  :rabbitmq_port,
                  :rabbitmq_user,
                  :rabbitmq_password,
                  :rabbitmq_exchange_name,
                  :rabbitmq_exchange_durable,
                  :auto_connect_to_exchange,
                  :default_ignored_model_changes,
                  :default_ignored_request_params,
                  :application_name,
                  :bunny_options
  end
end
