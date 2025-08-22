require "featurevisor"

RSpec.describe Featurevisor::Emitter do
  let(:emitter) { Featurevisor::Emitter.new }
  let(:handled_details) { [] }

  let(:handle_details) do
    ->(details) { handled_details << details }
  end

  before(:each) do
    handled_details.clear
  end

  describe "basic functionality" do
    it "should add a listener for an event" do
      unsubscribe = emitter.on("datafile_set", handle_details)

      expect(emitter.listeners["datafile_set"]).to include(handle_details)
      expect(emitter.listeners["datafile_changed"]).to be_nil
      expect(emitter.listeners["context_set"]).to be_nil
      expect(emitter.listeners["datafile_set"].length).to eq(1)

      # trigger already subscribed event
      emitter.trigger("datafile_set", { key: "value" })
      expect(handled_details.length).to eq(1)
      expect(handled_details[0]).to eq({ key: "value" })

      # trigger unsubscribed event
      emitter.trigger("sticky_set", { key: "value2" })
      expect(handled_details.length).to eq(1)

      # unsubscribe
      unsubscribe.call
      expect(emitter.listeners["datafile_set"].length).to eq(0)

      # clear all
      emitter.clear_all
      expect(emitter.listeners).to eq({})
    end
  end

  describe "event handling" do
    it "should handle multiple listeners for the same event" do
      second_handler = ->(details) { handled_details << "second: #{details[:key]}" }

      emitter.on("datafile_set", handle_details)
      emitter.on("datafile_set", second_handler)

      emitter.trigger("datafile_set", { key: "value" })

      expect(handled_details.length).to eq(2)
      expect(handled_details[0]).to eq({ key: "value" })
      expect(handled_details[1]).to eq("second: value")
    end

    it "should handle events with no listeners" do
      # Should not raise an error
      expect { emitter.trigger("nonexistent_event", { key: "value" }) }.not_to raise_error
    end

    it "should handle events with empty details" do
      emitter.on("context_set", handle_details)

      emitter.trigger("context_set")

      expect(handled_details.length).to eq(1)
      expect(handled_details[0]).to eq({})
    end

    it "should handle events with complex details" do
      complex_details = {
        user_id: 123,
        features: ["feature1", "feature2"],
        metadata: { version: "1.0.0", environment: "production" }
      }

      emitter.on("sticky_set", handle_details)
      emitter.trigger("sticky_set", complex_details)

      expect(handled_details.length).to eq(1)
      expect(handled_details[0]).to eq(complex_details)
    end
  end

  describe "unsubscribe functionality" do
    it "should allow multiple unsubscribes without error" do
      unsubscribe = emitter.on("datafile_set", handle_details)

      # First unsubscribe should work
      unsubscribe.call
      expect(emitter.listeners["datafile_set"].length).to eq(0)

      # Second unsubscribe should not cause errors
      expect { unsubscribe.call }.not_to raise_error
      expect(emitter.listeners["datafile_set"].length).to eq(0)
    end

    it "should handle unsubscribe when listener is already removed" do
      unsubscribe = emitter.on("datafile_set", handle_details)

      # Manually remove the listener
      emitter.listeners["datafile_set"].delete(handle_details)

      # Unsubscribe should not cause errors
      expect { unsubscribe.call }.not_to raise_error
    end

    it "should maintain other listeners when one is unsubscribed" do
      second_handler = ->(details) { handled_details << "second" }

      unsubscribe1 = emitter.on("datafile_set", handle_details)
      unsubscribe2 = emitter.on("datafile_set", second_handler)

      expect(emitter.listeners["datafile_set"].length).to eq(2)

      unsubscribe1.call
      expect(emitter.listeners["datafile_set"].length).to eq(1)
      expect(emitter.listeners["datafile_set"]).to include(second_handler)

      # Second handler should still work
      emitter.trigger("datafile_set", { key: "value" })
      expect(handled_details.length).to eq(1)
      expect(handled_details[0]).to eq("second")
    end
  end

  describe "error handling" do
    it "should continue processing other listeners when one fails" do
      failing_handler = ->(details) { raise "Test error" }
      working_handler = ->(details) { handled_details << details[:key] }

      emitter.on("datafile_set", failing_handler)
      emitter.on("datafile_set", working_handler)

      # Should not raise error and should process working handler
      expect { emitter.trigger("datafile_set", { key: "value" }) }.not_to raise_error
      expect(handled_details.length).to eq(1)
      expect(handled_details[0]).to eq("value")
    end

    it "should handle nil callback gracefully" do
      expect { emitter.on("datafile_set", nil) }.not_to raise_error
    end
  end

  describe "clear_all functionality" do
    it "should remove all listeners from all events" do
      emitter.on("datafile_set", handle_details)
      emitter.on("context_set", handle_details)
      emitter.on("sticky_set", handle_details)

      expect(emitter.listeners.keys.length).to eq(3)

      emitter.clear_all
      expect(emitter.listeners).to eq({})
    end

    it "should allow adding new listeners after clear_all" do
      emitter.on("datafile_set", handle_details)
      emitter.clear_all

      # Should be able to add new listeners
      emitter.on("datafile_set", handle_details)
      expect(emitter.listeners["datafile_set"].length).to eq(1)

      # Should work normally
      emitter.trigger("datafile_set", { key: "value" })
      expect(handled_details.length).to eq(1)
    end
  end

  describe "constants" do
    it "should have correct event names" do
      expect(Featurevisor::EVENT_NAMES).to eq(%w[datafile_set context_set sticky_set])
    end
  end

  describe "edge cases" do
    it "should handle very long event names" do
      long_event_name = "a" * 1000
      emitter.on(long_event_name, handle_details)

      expect(emitter.listeners[long_event_name]).to include(handle_details)

      emitter.trigger(long_event_name, { key: "value" })
      expect(handled_details.length).to eq(1)
    end

    it "should handle special characters in event names" do
      special_event_name = "event-with-dashes_and_underscores.123"
      emitter.on(special_event_name, handle_details)

      expect(emitter.listeners[special_event_name]).to include(handle_details)

      emitter.trigger(special_event_name, { key: "value" })
      expect(handled_details.length).to eq(1)
    end
  end
end
