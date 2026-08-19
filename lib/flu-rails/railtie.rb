# frozen_string_literal: true

module Flu
  class Railtie < Rails::Railtie
    railtie_name :flu

    # 'to_prepare' runs before eager loading, so that 'track_entity_changes' and 'track_requests'
    # exist by the time the application's models and controllers are loaded. It runs again on every
    # code reload, where 'Flu.init' builds a new publisher which has to be connected too.
    #
    # There is deliberately no 'after_initialize' hook here: it also runs at boot, right after this
    # one, and the 'Flu.start' it used to make opened a second connection that replaced — and
    # therefore leaked — the connection opened above.
    config.to_prepare do
      Flu.init
      Flu.start
    end

    # The end of a request or of a job, which runs even when it is an exception that ended it, is the
    # last chance to publish what the broker could not take a moment earlier.
    initializer "flu.retry_pending_publications" do |application|
      application.executor.to_complete { Flu.retry_pending_publications }
    end
  end
end
