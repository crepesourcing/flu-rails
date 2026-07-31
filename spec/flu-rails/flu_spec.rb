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
end
