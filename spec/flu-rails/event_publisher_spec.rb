require "securerandom"

RSpec.describe Flu::EventPublisher do
  subject(:publisher) { described_class.new(configuration) }

  let(:configuration) do
    configuration                           = Flu::Configuration.new
    configuration.logger                    = Logger.new(IO::NULL)
    configuration.rabbitmq_exchange_name    = "events"
    configuration.rabbitmq_exchange_durable = true
    configuration
  end

  let(:event) do
    Flu::Event.new(SecureRandom.uuid, "ninja_app", :entity_change, "create ninja", { "name" => "Hanzo" })
  end

  describe "#publish" do
    context "when the publisher was never connected" do
      it "should raise a Flu error rather than a NoMethodError on nil" do
        expect { publisher.publish(event) }.to raise_error(Flu::NotConnectedError)
      end

      it "should say what has to be done about it" do
        expect { publisher.publish(event) }.to raise_error(/'connect' was never called/)
      end

      it "should mention the option that turns the automatic connection off" do
        expect { publisher.publish(event) }.to raise_error(/auto_connect_to_exchange/)
      end
    end
  end

  describe "Flu::NotConnectedError" do
    # A host application should be able to rescue everything this gem raises without naming each
    # error, and without reaching for 'StandardError'.
    it "should be a Flu::Error" do
      expect(Flu::NotConnectedError.new).to be_a Flu::Error
    end

    it "should be a StandardError" do
      expect(Flu::NotConnectedError.new).to be_a StandardError
    end
  end
end
