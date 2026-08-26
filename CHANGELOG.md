# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [8.0.7] - 2026-08-26

**Fixed**

* Keep the event publisher across code reloads. The railtie re-runs `init` on every reload, and `init` disconnected the publisher it replaced -- but a tracked model publishes through the very publisher it was tracked with, so every model the reload did not reload kept publishing on a connection that had just been closed, and nothing ever reopened it: `Flu::NotConnectedError` ("'connect' was never called, or 'disconnect' was") on every event from then on, until the process was restarted. The publisher now outlives the reloads, and only a change of kind (the real publisher for the dummy one, or the other way round) replaces and disconnects it.
* Reopen a connection Bunny has stopped recovering. Bunny reopens a connection it lost, but not one that never opened, nor one whose recovery attempts ran out: `publish` only ever reconnected after a fork, so a publisher left with such a connection raised on every event for the rest of the process. It now reopens it on the next publication, and no more than once every five seconds, since a broker that hangs rather than refuses costs a full `connect_timeout` per attempt.

**Changed**

* `connect` no longer retries an unreachable broker forever. It gives up after `max_connect_wait` seconds and raises `Flu::ConnectionLostError`. The railtie calls it from `to_prepare`, which runs on every code reload: waiting on a broker that never answers held the reload interlock, and the request behind it, for good.
* A broker that cannot be reached at startup no longer keeps the application from booting. `Flu.start` logs the failure, and publishing opens the connection once the broker answers again.

**Added**

* `max_connect_wait` (default `30`), how many seconds the startup retries a broker that does not answer before letting the application boot. `nil` waits for the broker for as long as it takes.

### [8.0.6] - 2026-08-19

**Fixed**

* Publish the events of a transaction from its commit rather than from each record's `after_commit`, which used to lose events two separate ways: Rails runs the transactional callbacks of a row on one single instance of it and skips the others (which one it picks is what `run_commit_callbacks_on_first_saved_instances_in_transaction` decides, and neither value was safe), and it skips every callback still queued as soon as one of them raises. Events now go out from the commit itself, which nothing can skip, once per recorded change and in the order the records were saved. A non-joinable transaction, such as the one `use_transactional_tests` wraps an example in, is never waited on, so a test suite sees what production does.
* Keep an event whose publication failed for another attempt rather than giving up on it there and then. It waits in memory, per thread, up to `max_pending_events`, and is published by the next transaction to commit on that thread or at the end of the request or the job, whichever comes first. Nothing is attempted while the publisher reports itself unreachable, and an event still refused after three attempts, or pushed out of a full buffer, is handed to `on_publication_failure`.
* Build and publish every change on its own, so an event that cannot be built or cannot reach the broker no longer costs the events queued behind it. A failed publication does not fail the transaction it belongs to either -- it has already committed by then.
* Reconnect to RabbitMQ after a fork. A forked child inherited the parent's `Bunny` connection and published on it, which the broker then ended for both. `EventPublisher` now remembers the pid it connected under, caches channels per process as well as per thread, and drops an inherited connection instead of closing it.
* Serialize `connect` and `disconnect` on a mutex. Two threads reaching `connect` together both opened a connection, the second overwriting the first, which stayed open and unreachable.

**Added**

* `Flu::ConnectionLostError`, raised by `publish` while the connection to RabbitMQ is down.
* `on_publication_failure`, called with the event and the error when an event cannot be published, so that an application can keep it rather than read about it in the logs. The event is `nil` when it could not even be built.
* `max_pending_events` (default `1000`), how many events a thread keeps waiting for the broker to be reachable again before the oldest are handed to `on_publication_failure`.

**Changed**

* Publishing while the connection is down now raises `Flu::ConnectionLostError` instead of the bare `RuntimeError` `Bunny::Session#create_channel` raises ("this connection is not open"), which nothing could tell apart from any other `RuntimeError`. It still fails immediately rather than waiting: Bunny reopens the connection in the background, and publishing works again once it has.

### [8.0.5] - 2026-08-03

**Fixed**

* `QueueRepository#find_all` no longer lists queues across every vhost on the broker. It called `list_queues` without a vhost, which lists every vhost's queues -- on a broker shared with other applications, that meant every other application's queues too, not just this one's.
* Sanitize the event name before building the routing key.
* [Breaking change?] Publish only Flu's own events from `flu_publish_events!`. It called `run_callbacks(:commit)`, which runs every `after_commit` callback registered on the record (including the host application's own (mailers, jobs, cache invalidation)) rather than just the one `track_entity_changes` installs. It now calls `flu_commit_changes` directly, the same way the real `after_commit` callback does.
* Guard the railtie require on `Rails::Railtie` rather than on `Rails`. Gems such as `rails-html-sanitizer` define an empty `Rails` namespace, which `is_testing_environment?` already accounted for a few lines below -- the railtie require itself did not, and raised `NameError: uninitialized constant Rails::Railtie` in that case.
* Stop assuming `ActionDispatch` is loaded when serializing an event. `Event#to_json` referenced `ActionDispatch::Http::UploadedFile` unconditionally to special-case uploaded files, on every value it serialized. A plain script that builds and serializes an event without the rest of Rails loaded raised `NameError: uninitialized constant Flu::Event::ActionDispatch` on the very first field.
* Track Single Table Inheritance subclasses. ActiveRecord hands the callbacks registered by `track_entity_changes` down to subclasses, but the class-level instance variables holding their settings were not inherited, so every save of an STI subclass of a tracked model raised `NoMethodError` on `nil`. `flu_is_tracked`, `flu_user_metadata_lambdas`, `flu_ignored_model_changes` and `flu_overriden_emitter_lambda` are now declared with `class_attribute`, which a subclass inherits until it sets its own value.
* Always clear the per-request tracking state, even when an action raises. The request id and the entity metadata are stored in thread-local storage and were cleared from an `after_action`, which does not run when the action raises. Since application servers reuse their threads, a failed request left its id behind for the next request served by that same thread, whose entity changes were then attributed to a request that had already died. `track_requests` now installs a single `around_action` that clears both from an `ensure` block.

**Added**

* `rabbitmq_vhost` configuration option (default `"/"`), used by both `EventPublisher`'s AMQP connection and `QueueRepository`'s management API calls, to operate on a vhost other than the default.
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

* Cover `rabbitmq_vhost` against a real broker: `EventPublisher#connect` fails rather than silently falling back to the default vhost when it points at one that does not exist, and `QueueRepository#find_all` scoped to a dedicated vhost does not see a queue declared on another one -- proving the cross-vhost leak above was real.
* Cover `duration`, which had no test at all: it is the elapsed wall-clock time since `request_start_time`, and a real controller request emits one that is a small, non-negative `Float`.
* Cover `Event#to_routing_key`: dots are stripped from the name, spaces are left untouched, a name that would push the routing key past 255 characters is truncated with a warning through `Flu.logger`, and none of this raises when `Flu.logger` was never set. Cover the same against a real broker: a name with dots is delivered under a single routing-key segment, and a 300-character name that used to make Bunny raise is published and delivered instead.
* Cover that `flu_publish_events!` does not run a host application's own `after_commit` callback, registered on the record's singleton class, exactly the way `run_callbacks(:commit)` used to run it too.
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