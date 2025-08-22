# frozen_string_literal: true

module Featurevisor
  # Child instance class for managing child contexts and sticky features
  class ChildInstance
    attr_reader :parent, :context, :sticky, :emitter

    # Initialize a new child instance
    # @param options [Hash] Child instance options
    # @option options [Instance] :parent Parent instance
    # @option options [Hash] :context Child context
    # @option options [Hash] :sticky Child sticky features
    def initialize(options)
      @parent = options[:parent]
      @context = options[:context] || {}
      @sticky = options[:sticky] || {}
      @emitter = Featurevisor::Emitter.new
    end

    # Subscribe to an event
    # @param event_name [String] Event name
    # @param callback [Proc] Callback function
    # @return [Proc] Unsubscribe function
    def on(event_name, callback = nil, &block)
      callback = block if block_given?
      
      if event_name == "context_set" || event_name == "sticky_set"
        @emitter.on(event_name, callback)
      else
        @parent.on(event_name, callback)
      end
    end

    # Close the child instance
    def close
      @emitter.clear_all
    end

    # Set context
    # @param context [Hash] Context to set
    # @param replace [Boolean] Whether to replace existing context
    def set_context(context, replace = false)
      if replace
        @context = context
      else
        @context = { **@context, **context }
      end

      @emitter.trigger("context_set", {
        context: @context,
        replaced: replace
      })
    end

    # Get context
    # @param context [Hash, nil] Additional context to merge
    # @return [Hash] Merged context
    def get_context(context = nil)
      @parent.get_context({
        **@context,
        **(context || {})
      })
    end

    # Set sticky features
    # @param sticky [Hash] Sticky features
    # @param replace [Boolean] Whether to replace existing sticky features
    def set_sticky(sticky, replace = false)
      previous_sticky_features = @sticky || {}

      if replace
        @sticky = sticky
      else
        @sticky = {
          **@sticky,
          **sticky
        }
      end

      params = Featurevisor::Events.get_params_for_sticky_set_event(previous_sticky_features, @sticky, replace)
      @emitter.trigger("sticky_set", params)
    end

    # Check if a feature is enabled
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Boolean] True if feature is enabled
    def is_enabled(feature_key, context = {}, options = {})
      @parent.is_enabled(
        feature_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variation value
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [String, nil] Variation value or nil
    def get_variation(feature_key, context = {}, options = {})
      @parent.get_variation(
        feature_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable value
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] Variable value or nil
    def get_variable(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as boolean
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Boolean, nil] Boolean value or nil
    def get_variable_boolean(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_boolean(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as string
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [String, nil] String value or nil
    def get_variable_string(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_string(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as integer
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Integer, nil] Integer value or nil
    def get_variable_integer(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_integer(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as double
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Float, nil] Float value or nil
    def get_variable_double(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_double(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as array
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Array, nil] Array value or nil
    def get_variable_array(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_array(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as object
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash, nil] Object value or nil
    def get_variable_object(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_object(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get variable as JSON
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] JSON value or nil
    def get_variable_json(feature_key, variable_key, context = {}, options = {})
      @parent.get_variable_json(
        feature_key,
        variable_key,
        {
          **@context,
          **context
        },
        {
          sticky: @sticky,
          **options
        }
      )
    end

    # Get all evaluations
    # @param context [Hash] Context
    # @param feature_keys [Array<String>] Feature keys to evaluate
    # @param options [Hash] Override options
    # @return [Hash] All evaluations
    def get_all_evaluations(context = {}, feature_keys = [], options = {})
      @parent.get_all_evaluations(
        {
          **@context,
          **context
        },
        feature_keys,
        {
          sticky: @sticky,
          **options
        }
      )
    end

    private
  end
end
