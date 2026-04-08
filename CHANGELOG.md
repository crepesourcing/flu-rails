# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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