# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

**Fixed**

* Guard the railtie require on `Rails::Railtie` rather than on `Rails`. Gems such as `rails-html-sanitizer` define an empty `Rails` namespace, which `is_testing_environment?` already accounted for a few lines below -- the railtie require itself did not, and raised `NameError: uninitialized constant Rails::Railtie` in that case.
* Stop assuming `ActionDispatch` is loaded when serializing an event. `Event#to_json` referenced `ActionDispatch::Http::UploadedFile` unconditionally to special-case uploaded files, on every value it serialized. A plain script that builds and serializes an event without the rest of Rails loaded raised `NameError: uninitialized constant Flu::Event::ActionDispatch` on the very first field.
* Track Single Table Inheritance subclasses. ActiveRecord hands the callbacks registered by `track_entity_changes` down to subclasses, but the class-level instance variables holding their settings were not inherited, so every save of an STI subclass of a tracked model raised `NoMethodError` on `nil`. `flu_is_tracked`, `flu_user_metadata_lambdas`, `flu_ignored_model_changes` and `flu_overriden_emitter_lambda` are now declared with `class_attribute`, which a subclass inherits until it sets its own value.
* Always clear the per-request tracking state, even when an action raises. The request id and the entity metadata are stored in thread-local storage and were cleared from an `after_action`, which does not run when the action raises. Since application servers reuse their threads, a failed request left its id behind for the next request served by that same thread, whose entity changes were then attributed to a request that had already died. `track_requests` now installs a single `around_action` that clears both from an `ensure` block.

**Added**

* `Flu::Error`, the base class of every error this gem raises on its own, and `Flu::NotConnectedError`.

**Changed**

* `EventFactory` no longer serializes an event to JSON before logging it, unless debug logging is actually enabled.
* Publishing through a publisher that holds no connection now raises `Flu::NotConnectedError`, naming what to call and the option that turns the automatic connection off, instead of a `NoMethodError` on `nil`.
* A `request` event is now built once every other `after_action` has run, so its `duration` covers them too. An action that raises still publishes nothing.
* `EventPublisher` opens one Bunny channel per thread instead of sharing a single one.
* `EventPublisher#connected?` now reports on the connection alone. The exchange is declared per thread, so it is no longer a single object whose absence says anything about the publisher as a whole.

**Performance**

* Optimize `deep_camelize` to use `each_with_object` and `ActiveSupport::Inflector#camelize` to improve performance and reduce memory consumption.
* Add `# frozen_string_literal: true` to all ruby files to reduce string allocations.

**Tests**

* Cover loading `flu-rails` with an empty `Rails` namespace defined, through the same kind of subprocess as the `ActionDispatch` example above.
* Cover that building an entity change, request or manual event does not serialize it when the logger's level is above `DEBUG`.
* Cover `Event#to_json` without `ActionDispatch` loaded, through a subprocess that never requires actionpack -- the main suite always has it loaded, so this is the only honest way to exercise the guard.
* Cover which channel a thread publishes on, against a real broker: each thread gets its own, reuses it across publications, and picks up a fresh one after the connection was closed under it.
* Cover `entity_metadata`, which had no test at all: its lambda is evaluated before the action runs, and its result is cleared afterwards.
* Cover what a raising action leaves behind in the thread-local tracking state.
* Add `simplecov` as a development dependency to track and report code coverage.
* Add support for the `RABBITMQ_VERSION` environment variable in `docker-compose.yml` to allow testing locally against different versions of RabbitMQ.
* Configure GitHub Actions CI to run the test suite against a matrix of RabbitMQ versions (3.12, 3.13, and 4.0).

### [8.0.4] - 2026-08-01

**Security**

* Honour the host application's `config.filter_parameters` when publishing a `request` event.

**Fixed**

* Stop opening two RabbitMQ connections on every boot. The railtie called `Flu.start
* Close the publisher that `Flu.init` replaces.

**Added**

* `EventPublisher#disconnect` and `EventPublisher#connected?`.

**Changed**

* `ignored_request_params` and `default_ignored_request_params` are now matched as strings.
* A published `request` event may now carry `"[FILTERED]"` in place of a param value. 
* `EventPublisher#connect` is now idempotent: calling it on a connected publisher does nothing
  instead of opening a second connection.

**Tests**

* Cover the connection lifecycle against a real broker: redundant `connect` calls, `disconnect`,
  `connected?`, and reconnection after a disconnect — including an example asserting that no session
  is left open behind the publisher.
* Cover `Flu.init` disconnecting the publisher it replaces.

### [8.0.3] - 2026-08-01

* Use `uuid_v7` as Event ID (requires Ruby 3.3)

### [8.0.2] - 2026-08-01

**Fixed**

* Honour `configuration.logger` when rejecting a request on its user agent.
* Stop defining those helpers on `ActionController::Base` and `ActionController::API` themselves.
* Apply the model's `emitter:` override when exporting existing entities. `Util::ExportService`
  passed `nil` instead of the model's lambda, so a replayed event carried the global
  `application_name` while the live event for the same entity carried the overriden one — putting
  the two on different routing keys. Unnoticed since `1.0.4`, where the option was introduced.
* Do not assume that a defined `Rails` constant means railties is loaded.

**Changed**

* Stop publishing `overriden_emitter` as part of the event payload.

**Tests**

* Enable the three controller examples that were disabled with `xit`, and run them through the real
  `ActionController` dispatch, which is what triggers the callbacks registered by `track_requests`.
  This is the code path that hid the `ActionController::UnfilteredParameters` bug fixed in `8.0.1`.
* Cover `Util::ExportService`, which had no test at all — and which is how the `emitter:` bug above
  surfaced.
* Make the spec setup idempotent
* Integration tests with RabbitMQ

### [8.0.1] - 2026-07-31

**Fixed**

* Fix tracking a controller request raising `ActionController::UnfilteredParameters`. Controller params
  reach `EventFactory` as unpermitted `ActionController::Parameters`, on which `to_h` raises
  (Rails >= 5.1). The unsafe hash is now used, which is what a read-only tracker needs. This broke
  `track_requests` entirely, and went unnoticed because its specs are disabled (`xit`).
* Fix `Flu.init` raising `configuration.application_name must not be nil` on a stock Rails application.

**Changed**

* **Breaking**: `flu-rails` now supports Rails 8 exclusively.
* Drop the pre-Rails-8 compatibility shims that this makes dead code:
    * `flu_changes_depending_on_active_record_version`
    * the `Zeitwerk::Loader.eager_load_all` fallback in `Util::ExportService`
* Restore `activesupport` as a runtime dependency
* Require the ActiveSupport core extensions that are actually used

**Publishing**

* Add a `Rakefile` (`bundler/gem_tasks` + an `rspec` task), so that `rake release` builds, tags and publishes the gem. `rake` becomes a development dependency.
* Add `.github/workflows/release.yml`: pushing a `v*` tag checks that the tag matches `Flu::VERSION`,
  runs the specs, then builds and pushes the gem through RubyGems' Trusted Publishing. No RubyGems
  API key is stored in the repository — a short-lived GitHub OIDC token is exchanged for a scoped
  RubyGems credential.

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