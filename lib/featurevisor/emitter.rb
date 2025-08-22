# frozen_string_literal: true

module Featurevisor
  # Event names for the emitter
  EVENT_NAMES = %w[datafile_set context_set sticky_set].freeze

  # Event emitter class for handling event subscriptions and triggers
  class Emitter
    attr_reader :listeners

    # Initialize a new emitter
    def initialize
      @listeners = {}
    end

    # Subscribe to an event
    # @param event_name [String] Name of the event to listen to
    # @param callback [Proc] Callback function to execute when event is triggered
    # @return [Proc] Unsubscribe function
    def on(event_name, callback)
      @listeners[event_name] ||= []
      listeners = @listeners[event_name]
      listeners << callback

      is_active = true

      # Return unsubscribe function
      -> do
        return unless is_active

        is_active = false
        index = listeners.index(callback)
        listeners.delete_at(index) if index && index >= 0
      end
    end

    # Trigger an event with optional details
    # @param event_name [String] Name of the event to trigger
    # @param details [Hash] Optional details to pass to event handlers
    def trigger(event_name, details = {})
      listeners = @listeners[event_name]

      return unless listeners

      listeners.each do |listener|
        begin
          listener.call(details)
        rescue => err
          # Log error but don't stop execution
          warn "Error in event listener: #{err.message}"
        end
      end
    end

    # Clear all event listeners
    def clear_all
      @listeners = {}
    end
  end
end
