require "byebug"
require "active_support"
require "active_support/time"

Time.zone = "UTC"

require_relative "support/action_controller_spec_helper"
require_relative "support/active_record_spec_helper"
require_relative "../lib/flu-rails"
require_relative "support/rails_helper"
require_relative "support/environment_helper"
require_relative "support/queue_repository_stub"

RSpec.configure do |config|
  config.include RailsHelper
  config.include EnvironmentHelper

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
end
