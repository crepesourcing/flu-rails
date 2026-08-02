# frozen_string_literal: true

require "json"

module Flu
  class Event

    attr_reader :data

    def initialize(uuid, emitter, kind, name, data)
      raise ArgumentError, "uuid must not be nil"              if uuid.nil?
      raise ArgumentError, "emitter must not be nil nor empty" if emitter.nil? || emitter.length == 0
      raise ArgumentError, "kind must not be nil nor empty"    if kind.nil?    || kind.length == 0
      raise ArgumentError, "name must not be nil nor empty"    if name.nil?    || name.length == 0

      @meta = {
        id:        uuid,
        name:      name,
        emitter:   emitter,
        timestamp: Time.now.utc,
        kind:      kind,
        status:    :new
      }
      @data = data || {}
    end

    def to_routing_key
      "#{@meta[:status]}.#{@meta[:emitter]}.#{@meta[:kind]}.#{@meta[:name]}"
    end

    def to_json(options=nil)
      JSON.dump({
        meta: @meta,
        data: map_complex_object(@data)
      })
    end

    def id
      @meta[:id]
    end

    def timestamp=(new_timestamp)
      @meta[:timestamp] = new_timestamp
    end

    def mark_as_replayed
      @meta[:status] = :replayed
    end

    def emitter
      @meta[:emitter]
    end

    def timestamp
      @meta[:timestamp]
    end

    def kind
      @meta[:kind]
    end

    def name
      @meta[:name]
    end

    def status
      @meta[:status]
    end

    private

    def map_complex_object(object)
      if object.is_a?(Array)
        map_array(object)
      elsif object.is_a?(Hash)
        map_hash(object)
      elsif object.is_a?(ActionDispatch::Http::UploadedFile)
        map_file(object)
      else
        object
      end
    end

    def map_array(object)
      array = []
      object.each do |value|
        array.push(map_complex_object(value))
      end
      array
    end

    def map_hash(object)
      hash = {}
      object.each do |key, value|
        hash[key] = map_complex_object(value)
      end
      hash
    end

    def map_file(object)
      {
        "file_name":    object.original_filename,
        "content_type": object.content_type
      }
    end
  end
end

