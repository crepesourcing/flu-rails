# frozen_string_literal: true

module Flu
  # The entities that recorded events in the transaction currently open, so that its commit can
  # publish them.
  #
  # A record hands its events over from 'after_commit', and Rails skips every transactional callback
  # still to run as soon as one of them raises: it re-commits the rest of the batch with
  # 'should_run_callbacks: false' (ActiveRecord::ConnectionAdapters::Transaction#commit_records). One
  # raising callback, in this gem or in the application, therefore drops the events of every record
  # left in the queue. The commit of the transaction itself is the one moment nothing can skip, and
  # it is where these are published instead.
  #
  # One buffer per thread, one mark per open transaction: what a transaction recorded is what was
  # pushed past its mark, which is what its rollback discards and what the outermost commit hands
  # back. A thread holding transactions open on several databases at once shares that one stack, so
  # the events of the first to commit wait for the last.
  class TransactionBuffer
    def self.current
      Thread.current[:flu_transaction_buffer] ||= new
    end

    def initialize
      @entities = []
      @marks    = []
    end

    # @return [Boolean] false when no transaction is open, in which case nothing will ever drain the
    #   buffer and the entity is left to publish its own changes.
    def record(entity)
      if @marks.empty?
        false
      else
        @entities.push(entity)
        true
      end
    end

    def transaction_started
      @marks.push(@entities.size)
    end

    # @return [Array] the entities to publish: those of the outermost transaction, none otherwise,
    #   a nested transaction leaving what it recorded to the one it is nested in.
    def transaction_committed
      @marks.pop
      if @marks.empty?
        committed = @entities
        @entities = []
        committed
      else
        []
      end
    end

    # @return [Array] the entities whose events the rollback discards.
    def transaction_rolled_back
      @entities.slice!((@marks.pop || 0)..) || []
    end
  end
end
