require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
end

require "byebug"
require "active_support"
require "active_support/time"

Time.zone = "UTC"

require_relative "support/action_controller_spec_helper"
require_relative "support/active_record_spec_helper"
require_relative "../lib/flu-rails"
require_relative "support/rails_helper"
require_relative "support/environment_helper"
require_relative "support/rabbitmq_context"

RSpec.configure do |config|
  config.include RailsHelper
  config.include EnvironmentHelper

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.before(:each, :rabbitmq) do
    next if RabbitmqHelper.available?
    reason = "no RabbitMQ broker on #{RabbitmqHelper.address} (#{RabbitmqHelper.unavailability_reason})"
    raise "FLU_REQUIRE_RABBITMQ is set, but there is #{reason}" if RabbitmqHelper::REQUIRED
    skip "#{reason}. Start one with 'docker compose up -d rabbitmq'."
  end

  config.after(:each, :rabbitmq) { RabbitmqHelper.record_executed_example }

  config.after(:suite) do
    next unless RabbitmqHelper::REQUIRED
    next if RabbitmqHelper.executed_examples.positive?
    raise "FLU_REQUIRE_RABBITMQ is set, but not a single ':rabbitmq' example ran: this run proves " \
          "nothing about RabbitMQ. Check the spec files and the filters this run was given."
  end
end
