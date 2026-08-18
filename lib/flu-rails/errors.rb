# frozen_string_literal: true

module Flu
  class Error < StandardError
  end

  class NotConnectedError < Error
  end

  class ConnectionLostError < Error
  end
end
