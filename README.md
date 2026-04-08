# Gem for flu-rails

## Description

This project aims at seamlessly creating/emitting events from an existing Rails project (without changing its codebase) in order to execute asynchronous tasks such as event storing, real time analytics, system monitoring,...

For now, events are generated from:

* CRUD operations on Active record models
* Requests on Rails controllers actions

## Installation

Add the gem to your project's Gemfile:

  ```ruby
  gem "flu-rails", git: "https://github.com/crepesourcing/flu-rails.git"
  ```

Then, create an initializer into your Rails app (`config/initializers/flu-rails.rb`)

  ```ruby
    Flu.configure do |config|
      config.development_environments  = []
      config.rabbitmq_host             = ENV["RABBITMQ_HOST"]
      config.rabbitmq_port             = ENV["RABBITMQ_PORT"]
      config.rabbitmq_user             = ENV["RABBITMQ_USER"]
      config.rabbitmq_password         = ENV["RABBITMQ_PASSWORD"]
      config.rabbitmq_exchange_name    = ENV["RABBITMQ_EXCHANGE_NAME"]
    end
  ```
Each configuration is detailed below.

`flu-rails` will start automatically with `railties`.

## Requirements

* Ruby 3
* Tested with Rails 4 and 5.1
* Tested with RabbitMQ 3.5.8

## Usage

### Start up

If your application does not include `Railties`, `flu-rails` can be started as followed:
  ```
  Flu.init
  Flu.start
  ```

`flu-rails` startup waits until its RabbitMQ exchange is connected.

### Track changes on an ActiveRecord model

All subclasses of `ActiveRecord::Base` that call `track_entity_changes` are "tracked". _E.g._:

  ```ruby
  class Car < ActiveRecord::Base
    track_entity_changes
  end
  ```

`track_entity_changes` has several options:

| Option | Default Value | Type | Required? | Description  | Example |
| ---- | ----- | ------ | ----- | ------ | ----- |
| `user_metadata` | `{}`| Hash of lambdas | Optional | This hash can define two keys: `:create` and `:update`. Each value is a lambda that returns a hash. | `{create: lambda {{other_id: id}}}` |
| `ignored_model_changes` | `[]`| Array of strings | Optional | Same as the global parameter `default_ignored_model_changes` for a dedicated class. This option does not override `default_ignored_model_changes`. | `[:rsa_key, :salt]` |
| `emitter` | Emitter from configuration | Lambda that returns a string | Optional | This lambda is executed in each controller action to override the configuration's `emitter`. The result of this lambda cannot contain a dot ("`.`"). | `lambda { "overriden_emitter" }` |

For instance:

  ```ruby
  class Invoice < ActiveRecord::Base
    track_entity_changes user_metadata: {
      create: lambda {
        {
          user_full_name: user.full_name,
          user_birthdate: user.birthdate
        }
      }
    }

    belongs_to :user
  end
  ```

### Track requests to a Rails Controller action

All subclasses of `ActionController::Base` or `ActionController::API` (Rails 5) that call `track_requests` are "tracked". _E.g._:

  ```ruby
  class ApplicationController < ActionController::Base
    track_requests
  end
  ```

`track_requests` has several options:

| Option | Default Value | Type | Required? | Description  | Example |
| ---- | ----- | ------ | ----- | ------ | ----- |
| `user_metadata` | `nil`| Lambda that returns a hash | Optional | This lambda is executed in each controller action to create an additional event attribute: `user_metadata`. | `lambda { {id: 4}}` |
| `entity` | `nil`| Lambda that returns a hash | Optional | This lambda is executed in each controller action to attach a hash to every `entity_change` event related to it as an attribute named: `request_metadata`. | `lambda { {path: request.path}}` |
| `emitter` | Emitter from configuration | Lambda that returns a string | Optional |  This lambda is executed in each controller action to override the configuration's `emitter`. The result of this lambda cannot contain a dot ("`.`"). | `lambda { "overriden_emitter" }` |

For instance,

```ruby
class ApplicationController < ActionController::Base
  track_requests user_metadata: lambda {
    {
      constant_pouet: "Pouet",
      user_agent:     request.headers["User-Agent"]
    }
  }
```

### Create and emit an event manually

Flu's components can be used programmatically to create and emit events manually

  ```ruby
  data = {
    recipient_name: "Lazar",
    recipient_email: "lazar@fourtytwo.net",
    message: "Hi!"
  }
  kind = :manual
  name = "send email"
  event = Flu.event_factory.build_event(name, kind, data)
  Flu.event_publisher.publish(event)
  ```

*Warning!* When calling Flu's `publisher` programmatically in a transaction, these events won't be published according to the transaction's commit. They will be published instantly, contrary to the `ActiveRecord` events that will be published when the transaction commits.
If you want to publish events manually taking the transaction into account, please use the dedicated method `flu_add_manual_event(name: string, data: Hash)` (available on every `ActiveRecord` extended with `track_entity_changes`). For instance:
```ruby
Invoice.transaction do
  invoice = Invoice.new
  invoice.save!
  invoice.flu_add_manual_event("a custom name", { some_data: true }) ## kind is :manual
  Invoice.new.save!
end
```
3 events will be published according to the following order: `entity_change.create invoice`, `manual.a custom name`, `entity_change.create_invoice`. 


## Overall configuration options

All options have a default value. However, all of them can be changed in your initializer file.

| Option | Default Value | Type | Required? | Description  | Example |
| ---- | ----- | ------ | ----- | ------ | ----- |
| `development_environments` | `[]`| Array of strings | Optional | If `Rails.env` matches one of these values then no connection is attempted to the exchange (messages are created by not published to any exchange).  | `["test", "development"]` |
| `rejected_user_agents` | `[]`| Array of regexp | Optional | When calling a controller action, an event can be prevented from being emitted if the request's `user_agent` matches a regular expression. This option is a list of regular expressions.| `[/[^\(]*[^\)]Chrome\//]`|
| `logger` | `Logger.new(STDOUT)`| Logger | Optional | The logger used by `flu-rails` | `Rails.logger` | 
| `rabbitmq_host` | `"localhost"` | String | Required | RabbitMQ exchange's host. | `"192.168.42.42"` |
| `rabbitmq_port` | `"5672"` | Integer | Required | RabbitMQ exchange's port. | `"1234"` |
| `rabbitmq_user` | `""` | String | Required | RabbitMQ exchange's username. | `"root"` |
| `rabbitmq_password` | `""` | String | Required | RabbitMQ exchange's password. | `"pouet"` |
| `rabbitmq_exchange_name` | `"events"` | String | Required | RabbitMQ exchange's name. | `"myproject"` |
| `rabbitmq_management_scheme` | `"http"` | String | Required | RabbitMQ exchange's management scheme. This scheme is used when `happn` must access metadata information about queues, messages, etc. This port is used to create/delete bindings between the queue and its exchange. | `"https"` |
| `rabbitmq_management_port` | `"15672"` | Integer | Optional | RabbitMQ exchange's management port. This port is used when `flu-rails` must access metadata information about queues, messages, etc. This port is important if you want to use an instance of `QueueRepository`. Not required for simple use cases. | `"4242"` |
| `rabbitmq_exchange_durable` | `true` | Boolean | Optional | Make the RabbitMQ's exchange durable or not. From RabbitMQ's [documentation](https://www.rabbitmq.com/tutorials/amqp-concepts.html#exchanges): _"Durable exchanges survive broker restart whereas transient exchanges do not (they have to be redeclared when broker comes back online)."_ | `false` |
| `auto_connect_to_exchange` | `true`| Boolean | Optional | Thanks to `Railties`, `flu-rails` starts automatically when the Rails app boots. However, this can be useful to not connect RabbitMQ at start up. To do so, set `auto_connect_to_exchange` to `false`.  | `false` |
| `default_ignored_model_changes` | `[:password, :password_confirmation, :created_at, :updated_at]` | Boolean | Optional | By default, all these attributes will be ignored from model changes when creating an event. For instance, this means that timestamp fields (`created_at` and `updated_at`) are not monitored when they change. | `[]` |
| `default_ignored_request_params` | `[:password, :password_confirmation, :controller, :action]` | Boolean | Optional | By default, all these parameters will be ignored from controller request's `params` when creating an event. | `false` |
| `application_name` | `Rails.application.class.parent_name.to_s.camelize` | String | Required | Is used as `emitter` for each event created by `flu-rails`, if not overriden by the `track_met`. | `my_app` |
| `bunny_options` | `{}` | Hash of symbols | Optional | Additional options to add when connecting the RabbitMQ broker. This overrides the existing options with the same name. | `{ verify_peer: true }` |

## How to execute tests

From the `flu-rails` directory:

```
  $ docker build . -t flu:test
  $ docker run -v `pwd`:/usr/src/app/ flu:test rspec spec
```

## Example of Events

### Structure of an Active Record change

An event is created and published to the message broker every time a CRUD operation is executed on an ActiveRecord model. Events are published only once the current transaction is commited. Events are not published if a transaction rollbacks.

For example, this code will produces an event _"create country"_:

  ```ruby
  class Country < ActiveRecord::Base
    track_entity_changes user_metadata: {
      create: lambda {
        {
          continent_name: continent.name
        }
      }
    }
    belongs_to :continent
  end

  country = Country.new(name: "Belgium", short_name: "BE", continent: Continent.find(12))
  country.save!
  ```

The generated event looks like:

```json
{
  "meta": {
    "id": "540e4f55-9afa-48ac-80d9-7b0ae3654682",
    "name": "create country",
    "emitter": "my_application",
    "timestamp": "2017-02-16T14:13:42.509Z",
    "kind": "entity_change",
    "status": "new"
  },
  "data": {
    "changes": {
      "id": [null, 42],
      "name": [null, "Belgium"],
      "shortName": [null, "BE"],
      "continentId": [null, 42]
    },
    "entity_id": 42,
    "request_id": null,
    "action_name": "create",
    "entity_name": "country",
    "associations": {
      "continent_id": 12
    },
    "user_metadata": {
      "continent_name": "Europe"
    }
  }
}
```
(`request_id` is not `nil` if this code is executed through a controller action)

### Structure of an Rails controller request

For instance, calling the action `destroy` of `CountryController` will emit this event:

```json
{
  "meta": {
    "id": "a79d411d-7a34-4d31-870b-e09dcd7e5127",
    "name": "request to destroy countries",
    "emitter": "my_application",
    "timestamp": "2017-02-16T14:20:03.463Z",
    "kind": "request",
    "status": "new"
  },
  "data": {
    "requestId": "ec01b901-db42-4c60-9da1-e3ec96a017fc",
    "controllerName": "countries",
    "actionName": "destroy",
    "path": "/countries",
    "responseCode": 200,
    "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/56.0.2924.87 Safari/537.36",
    "duration": 0.065510717,
    "params": {
      "format": "json"
    },
    "userMetadata": {}
  }
}
```

## Side-notes

* `assocations` node contains `belongs_to` associations only.
