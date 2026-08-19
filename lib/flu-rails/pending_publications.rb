# frozen_string_literal: true

module Flu
  # The events whose publication failed, kept for another attempt.
  #
  # A broker that closes a connection takes a few seconds to be usable again, since Bunny reopens it
  # in the background, and an event published in that window has nowhere to go. Rather than being
  # given up on there, it waits here for the connection to be back: the next transaction to commit on
  # the thread comes back for it, and so does the end of the request or the job it belongs to.
  #
  # In memory, and per thread: what is waiting here dies with the process. An application that cannot
  # afford to lose an event keeps it itself, from 'on_publication_failure', which is called for every
  # event this gives up on.
  class PendingPublications
    MAX_ATTEMPTS = 3

    def self.current
      Thread.current[:flu_pending_publications] ||= new
    end

    def initialize
      @entries = []
    end

    def size
      @entries.size
    end

    def push(event, publisher, error)
      give_up(@entries.shift) while @entries.size >= Flu.config.max_pending_events
      @entries.push({ event: event, publisher: publisher, error: error, attempts: 1 })
    end

    # Publishes again what its publisher can reach again, keeps what it cannot, and gives up on what
    # has been refused MAX_ATTEMPTS times, an event the broker itself rejects being no more publishable
    # on the tenth attempt than on the first.
    def drain
      return if @entries.empty?

      kept = []
      @entries.each do |entry|
        next kept.push(entry) unless reachable?(entry[:publisher])

        begin
          entry[:publisher].publish(entry[:event])
        rescue StandardError => error
          entry[:error]     = error
          entry[:attempts] += 1
          entry[:attempts] < MAX_ATTEMPTS ? kept.push(entry) : give_up(entry)
        end
      end
      @entries = kept
    end

    private

    def reachable?(publisher)
      publisher.connected?
    rescue StandardError
      false
    end

    def give_up(entry)
      Flu.report_publication_failure(entry[:event], entry[:error])
    end
  end
end
