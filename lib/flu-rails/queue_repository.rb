# frozen_string_literal: true

require "rabbitmq/http/client"

module Flu
  class QueueRepository
    def initialize(configuration)
      @logger            = configuration.logger
      @configuration     = configuration
      @management_client = create_management_client(configuration)
    end

    def find_all
      @management_client.list_queues
    end

    def find_queue(name)
      @management_client.queue_info("/", name)
    end

    def find_bindings_for_queue(name)
      @management_client.list_queue_bindings("/", name)
    end

    def purge_queue(name)
      @management_client.purge_queue("/", name)
    end

    def delete_queue(name)
      @management_client.delete_queue("/", name)
    end

    private

    def create_management_client(configuration)
      rabbitmq_url = "#{configuration.rabbitmq_management_scheme || "http"}://#{configuration.rabbitmq_host}:#{configuration.rabbitmq_management_port}/"
      RabbitMQ::HTTP::Client.new(rabbitmq_url,
                                 username: configuration.rabbitmq_user,
                                 password: configuration.rabbitmq_password)
    end
  end
end
