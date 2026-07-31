# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

**Fixed**

* Fix tracking a controller request raising `ActionController::UnfilteredParameters`. Controller params
  reach `EventFactory` as unpermitted `ActionController::Parameters`, on which `to_h` raises
  (Rails >= 5.1); the unsafe hash is now used, which is what a read-only tracker needs. This broke
  `track_requests` entirely, and went unnoticed because its specs are disabled (`xit`).
* Fix `Flu.init` raising `configuration.application_name must not be nil` on a stock Rails application.
  The default was computed when the gem was required — that is, from `Bundler.require` in
  `config/application.rb`, before the application class exists and while `Rails.application` is still
  nil. It is now resolved lazily from `init`, which the railtie runs in `to_prepare`.

**Changed**

* `flu-rails` is now explicitly a Rails-only gem: `actionpack`, `activerecord` and `activesupport`
  (all `>= 7.0`) are declared as runtime dependencies. It extends `ActiveRecord::Base` and
  `ActionController::Base`, so a standalone `gem install flu-rails` could never work. The README no
  longer documents a non-Rails startup.
* Restore `activesupport` as a runtime dependency: it was dropped in `1.1.0` as "no longer used
  directly", but the code still relies on `blank?`, `try`, `underscore`, `constantize`,
  `module_parent_name` and `Time.zone`. It only kept working because the host application loaded it.
* Require the ActiveSupport core extensions that are actually used, rather than relying on the host
  application having loaded them.

**Verified**

* Verified against Rails 8.1 on a real application: railtie boot, `ActiveRecord` and
  `ActionController::Base`/`API` tracking through the full Rack stack, request id propagation from a
  controller into its entity-change events, uploaded file mapping and user-agent rejection — with
  every framework deprecator set to `:raise`. No deprecation is triggered.

### [1.2.0] - 2026-07-31

* Declare `required_ruby_version` as `>= 3.2`
* Test the specs on Ruby 3.2, 3.3 and 3.4 through GitHub Actions (`.github/workflows/ci.yml`)
* Declare `logger` as an explicit runtime dependency (it is required directly, and stops being a default gem in Ruby 3.5)
* Relax the exact development dependency pins (`rspec`, `sqlite3`, `byebug`) to pessimistic constraints,
  and drop the redundant lower bounds on `bunny` and `rabbitmq_http_api_client`
* Drop `bundler` as a development dependency
* Add `ostruct` as a development dependency (used by the specs, becomes a bundled gem in Ruby 3.5)
* Remove the unused `Flu::Dummy::EventPublisherDummy`, superseded by `Flu::Dummy::InMemoryEventPublisher` since `0.2.0`
* Fill in the gemspec `homepage`, `description` and `metadata`, and build `spec.files` from `Dir.glob`
  instead of `git ls-files` (which returned nothing outside of a git checkout, such as in the Docker image)
* Stop tracking `Gemfile.lock`, so that each supported Ruby resolves its own dependencies

### [1.1.0] - 2026-07-30

* Upgrade dependencies
    * `bunny`: `~> 3.1`
    * `bundler`: `>= 2.6.9`
    * `sqlite3`: `2.9.5`
    * `byebug`: `13.0.0`
* Remove `activesupport` runtime dependency (no longer used directly)
* Replace deprecated `ActiveSupport::Configurable` with plain `attr_accessor` in `Configuration` (removed in Rails 8.2)

### [1.0.8] - 2026-04-08

* Upgrade dependencies:
    * `ruby`: `>= 3`
    * `bunny`: `~> 2.23`
    * `activesupport`: `>= 7.0.0`
    * `bundler`: `>= 2.6.9`
    * `sqlite3`: `2.9.2`
    * `byebug`: `13.0.0`
* Upgrade Docker base image to `ruby:3.4.9-slim-trixie`

### [1.0.7] - 2023-04-04

* Upgrade constraints on dependencies:
    * `rabbitmq_http_api_client`: `2.2`
    * `rails` : `>= 7`

### [1.0.6] - 2022-11-18

* Make sure the deep camelization when serializing an event has no side-effet

### [1.0.5] - 2022-11-02

* Support for requests without any user agent

### [1.0.4] - 2022-11-02

* Allow the emitter to be overriden in `track_requests` and `track_entity_changes`

### [1.0.3] - 2022-03-30

* Update `Gemfile.lock` to avoid wrong CVE detections. The version of Rails should always be specified by the parent project. This change has no functional impact.

### [1.0.2] - 2021-11-06

* Breaking change : force every `port` to be an integer

## [1.0.0] - 2021-11-05

* Add `bunny_options`
* Add `rabbitmq_manage¨ment_scheme`
* MIT License

## [0.4.2]

* Add capability to add request metadata in the entity_change events related to the request
* Upgrade `rabbitmq_http_api_client`to `2.0`, bunny to `2.19`

## [0.4.1]

* Use of `rabbitmq_http_api_client:1.14.0`, which supports `faraday >= 1`

## [0.4.0]

* Drop support of Rails 5
* Upgrade dependencies: `rabbitmq_http_api_client:1.13.0`, `activesupport:>=6.0.0`, `bunny:>=2.14.4`

## [0.3.1]

* Eager load with Zeitwerk when available

## [0.3.0]

* Support for Rails 6+

## [0.2.0]

* Expose `InMemoryEventPublisher` for testing purpose

## [0.1.9]

* `publish_events!` allows to publish programmatically all the events that are stacked on an ActiveRecord

## [0.1.8]

* Events can be published manually according to a transactionnal context

## [0.1.7]

* Support for ActiveRecord >= 5.1

## [0.1.6]

* Allow to use the Event and the EventPublisher in non-rails environment

## [0.1.5]

* Allow to use the EventFactory in non-rails environment

## [0.1.4]

* Prevent events to be published including an invalid Unicode character (such as `\u0000`)

## [0.1.3]

* Support for polymorphic one-to-one associations
* Support for `ActionController:API`