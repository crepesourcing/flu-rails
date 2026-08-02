require_relative "lib/flu-rails/version"

Gem::Specification.new do |spec|
  spec.name        = "flu-rails"
  spec.version     = Flu::VERSION
  spec.authors     = ["Loïc Vigneron", "Lorent Lempereur", "Thibault Poncelet", "Logan Clément"]
  spec.email       = ["support@commuty.net"]
  spec.summary     = "Track your application events and publish them to RabbitMQ."
  spec.description = "Seamlessly emit events from an existing Rails application, without changing its " \
                     "codebase, and publish them to RabbitMQ. Events are generated from CRUD operations " \
                     "on ActiveRecord models and from requests on Rails controller actions."
  spec.homepage    = "https://github.com/crepesourcing/flu-rails"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri"       => spec.homepage,
    "changelog_uri"         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob(["lib/**/*.rb", "CHANGELOG.md", "MIT-LICENSE", "README.md", "flu-rails.gemspec"])
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack",               "~> 8.0"
  spec.add_dependency "activerecord",             "~> 8.0"
  spec.add_dependency "activesupport",            "~> 8.0"
  spec.add_dependency "bunny",                    "~> 3.1"
  spec.add_dependency "logger",                   "~> 1.7"
  spec.add_dependency "rabbitmq_http_api_client", "~> 3.2"

  spec.add_development_dependency "byebug",       "~> 13.0"
  spec.add_development_dependency "ostruct",      "~> 0.6"
  spec.add_development_dependency "rake",         ">= 13.0"
  spec.add_development_dependency "rspec",        "~> 3.13"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "sqlite3",      "~> 2.9"
end
