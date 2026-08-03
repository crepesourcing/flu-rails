RSpec.describe Flu::Event do

  let(:valid_kinds)    { [:entity_change, :request] }
  let(:valid_emitters) { ["Frontend", "Emitter"] }
  let(:valid_names)    { ["create invoice", "update order", "destroy invoice", "create invoices"] }
  let(:valid_kind)     { valid_kinds.first }
  let(:valid_emitter)  { valid_emitters.first }
  let(:valid_name)     { valid_names.first }
  let(:valid_data)     { valid_names.first }
  let(:uuid)           { SecureRandom.uuid }

  describe "#initialize" do
    context "when uuid is nil" do
      it "should raise an error" do
        expect { Flu::Event.new(nil, valid_emitter, valid_kind, valid_name, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when emitter is nil" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, nil, valid_kind, valid_name, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when emitter is empty" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, "", valid_kind, valid_name, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when kind is nil" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, valid_emitter, nil, valid_name, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when kind is empty" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, valid_emitter, "", valid_name, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when name is nil" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, valid_emitter, valid_kind, nil, {}) }.to raise_error(ArgumentError)
      end
    end

    context "when name is empty" do
      it "should raise an error" do
        expect { Flu::Event.new(uuid, valid_emitter, valid_kind, "", {}) }.to raise_error(ArgumentError)
      end
    end

    context "when data is nil" do
      it "sets data to an empty hash" do
        event = Flu::Event.new(uuid, valid_emitter, valid_kind, valid_name, nil)
        expect(event.data).to eq({})
      end
    end

    it "sets status to new by default" do
      event = Flu::Event.new(uuid, valid_emitter, valid_kind, valid_name, {})
      expect(event.status).to be(:new)
    end
  end

  describe "#to_routing_key" do
    def build_event(name:)
      Flu::Event.new(uuid, valid_emitter, valid_kind, name, {})
    end

    let(:prefix) { "new.#{valid_emitter}.#{valid_kind}." }

    it "joins status, emitter, kind and name with dots" do
      expect(build_event(name: "create invoice").to_routing_key).to eq "#{prefix}create invoice"
    end

    it "changes prefix once the event is marked as replayed" do
      event = build_event(name: "create invoice")
      event.mark_as_replayed
      expect(event.to_routing_key).to start_with "replayed."
    end

    context "when the name contains dots" do
      it "removes them instead of letting them add topic levels" do
        expect(build_event(name: "user.deleted.v2").to_routing_key).to eq "#{prefix}userdeletedv2"
      end

      it "leaves spaces untouched" do
        name = "request to destroy countries"
        expect(build_event(name: name).to_routing_key).to eq "#{prefix}#{name}"
      end
    end

    context "when the name would push the routing key past Bunny's 255-character limit" do
      let(:long_name) { "a" * 280 + "TAIL" }

      it "truncates the whole routing key down to 255 characters" do
        expect(build_event(name: long_name).to_routing_key.length).to eq 255
      end

      it "keeps the beginning of the name and drops what does not fit" do
        name_portion = build_event(name: long_name).to_routing_key.delete_prefix(prefix)
        expect(long_name).to start_with name_portion
        expect(name_portion).to_not include "TAIL"
      end

      it "warns through Flu.logger" do
        logger = instance_double(Logger, warn: nil)
        allow(Flu).to receive(:logger).and_return(logger)
        expect(logger).to receive(:warn).with(/truncated/)
        build_event(name: long_name).to_routing_key
      end

      it "does not raise when Flu.logger was never set" do
        allow(Flu).to receive(:logger).and_return(nil)
        expect { build_event(name: long_name).to_routing_key }.to_not raise_error
      end
    end

    context "when the name fits" do
      it "does not warn" do
        logger = instance_double(Logger, warn: nil)
        allow(Flu).to receive(:logger).and_return(logger)
        expect(logger).to_not receive(:warn)
        build_event(name: "create invoice").to_routing_key
      end
    end
  end

  describe "#to_json without ActionDispatch loaded" do
    it "should serialize the event instead of raising NameError" do
      lib_dir = File.expand_path("../../lib", __dir__)
      script  = <<~RUBY
        require "active_support"
        require "active_support/time"
        Time.zone = "UTC"
        require "flu-rails"
        raise "ActionDispatch got loaded, this example proves nothing" if defined?(ActionDispatch)

        event = Flu::Event.new("1", "app", :manual, "test", { "name" => "Hanzo" })
        puts event.to_json
      RUBY

      output = IO.popen(["ruby", "-I", lib_dir, "-e", script], err: [:child, :out], &:read)

      expect($?).to be_success, "subprocess failed:\n#{output}"
      expect(JSON.parse(output)["data"]).to eq({ "name" => "Hanzo" })
    end
  end
end
