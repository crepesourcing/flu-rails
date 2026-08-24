RSpec.describe Flu do

  describe "#init" do
    context "when Rails is loaded" do
      before (:each) do
        stub_rails
        set_environment_to_test
      end

      after (:each) do
        reset_environment
      end

      it "should set application_name from the rails application name" do
        Flu.init
        expect(Flu.config.application_name).to eq "flu_test"
      end

      it "should resolve application_name at init, not when the configuration is loaded" do
        reset_application_name
        expect(Flu.config.application_name).to be_nil
        Flu.init
        expect(Flu.config.application_name).to eq "flu_test"
      end

      it "should keep an explicitly configured application_name" do
        set_application_name("explicitly_set")
        Flu.init
        expect(Flu.config.application_name).to eq "explicitly_set"
      end
    end

    context "when Rails is not loaded" do
      context "when application_name is not explicitly set" do
        it "should raise an error" do
          reset_application_name
          expect { Flu.init }.to raise_error(RuntimeError)
        end
      end

      context "when application_name is explicitly set" do
        it "should set application_name from this value" do
          set_application_name("flu_test")
          Flu.init
          expect(Flu.config.application_name).to eq "flu_test"
        end
      end
    end

    # The railtie re-runs 'init' on every code reload. A tracked model publishes through the very
    # publisher it was tracked with, so replacing the publisher on each reload left every model the
    # reload did not reload publishing on a connection 'init' had just closed.
    context "when a publisher has already been created" do
      before(:each) { set_application_name("flu_test") }

      it "should keep it" do
        Flu.init
        previous_publisher = Flu.event_publisher
        Flu.init
        expect(Flu.event_publisher).to be previous_publisher
      end

      it "should not disconnect it" do
        Flu.init
        expect(Flu.event_publisher).to_not receive(:disconnect)
        Flu.init
      end

      # The publisher that answers 'Flu.event_publisher' must be the one the environment calls for,
      # and the connection of the one it replaces is nobody else's to close.
      context "when the environment has become a testing one" do
        before(:each) do
          stub_rails
          set_environment_to_test
        end

        after(:each) { reset_environment }

        it "should replace it with a dummy publisher" do
          reset_environment
          Flu.init
          set_environment_to_test
          Flu.init
          expect(Flu.event_publisher).to be_a Flu::Dummy::InMemoryEventPublisher
        end

        it "should disconnect the publisher it replaces" do
          reset_environment
          Flu.init
          previous_publisher = Flu.event_publisher
          expect(previous_publisher).to receive(:disconnect)
          set_environment_to_test
          Flu.init
        end
      end
    end

    # Gems such as 'rails-html-sanitizer' declare an empty 'Rails' namespace, so the constant can
    # exist without railties ever defining 'Rails.env'.
    context "when the Rails constant exists but is not the Rails framework" do
      before(:each) { stub_const("Rails", Module.new) }

      it "should not blow up on Rails.env" do
        set_application_name("flu_test")
        expect { Flu.init }.to_not raise_error
      end

      it "should not be considered a testing environment" do
        set_application_name("flu_test")
        Flu.init
        expect(Flu.event_publisher).to be_a Flu::EventPublisher
        expect(Flu.event_publisher).to_not be_a Flu::Dummy::InMemoryEventPublisher
      end
    end
  end

  # 'flu-rails.rb' decides whether to load the railtie once, when the file is first required --
  # by then, this suite has already loaded it and 'Rails' is fully defined, so nothing here can
  # exercise that line. Only a subprocess that defines the same empty 'Rails' namespace *before*
  # requiring 'flu-rails' can.
  describe "loading the railtie" do
    it "does not blow up when 'Rails' exists but 'Rails::Railtie' does not" do
      lib_dir = File.expand_path("../../lib", __dir__)
      script  = <<~RUBY
        module Rails; end
        require "active_support"
        require "active_support/time"
        Time.zone = "UTC"
        require "flu-rails"
        puts "ok"
      RUBY

      output = IO.popen(["ruby", "-I", lib_dir, "-e", script], err: [:child, :out], &:read)

      expect($?).to be_success, "subprocess failed:\n#{output}"
      expect(output).to include "ok"
    end
  end
end
