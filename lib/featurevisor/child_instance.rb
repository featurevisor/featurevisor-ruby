# frozen_string_literal: true

module Featurevisor
  # Child instance with isolated context and sticky state.
  class ChildInstance
    def initialize(options)
      @parent = options[:parent]
      @context = options[:context] || {}
      @sticky_features = options[:sticky_features] || {}
      @sticky_variables = options[:sticky_variables] || {}
      @emitter = Featurevisor::Emitter.new
      @parent_unsubscribers = []
    end

    def on(event_name, callback = nil, &block)
      callback = block if block_given?
      if %w[context_set sticky_features_set sticky_variables_set].include?(event_name)
        return @emitter.on(event_name, callback)
      end

      parent_unsubscribe = @parent.on(event_name, callback)
      active = true
      unsubscribe = nil
      unsubscribe = proc do
        next unless active

        active = false
        parent_unsubscribe.call
        @parent_unsubscribers.delete(unsubscribe)
      end
      @parent_unsubscribers << unsubscribe
      unsubscribe
    end

    def close
      @parent_unsubscribers.dup.each(&:call)
      @parent_unsubscribers.clear
      @emitter.clear_all
    end

    def set_context(context, replace = false)
      @context = replace ? context : { **@context, **context }
      @emitter.trigger("context_set", context: @context, replaced: replace)
    end

    def get_context(context = nil)
      @parent.get_context({ **@context, **(context || {}) })
    end

    def set_sticky_features(sticky, replace = false)
      previous = @sticky_features
      @sticky_features = replace ? sticky : { **@sticky_features, **sticky }
      params = Featurevisor::Events.get_params_for_sticky_features_set_event(previous, @sticky_features, replace)
      @emitter.trigger("sticky_features_set", params)
    end

    def set_sticky_variables(sticky, replace = false)
      previous = @sticky_variables
      @sticky_variables = replace ? sticky : { **@sticky_variables, **sticky }
      @emitter.trigger(
        "sticky_variables_set",
        Featurevisor::Events.get_params_for_sticky_variables_set_event(previous, @sticky_variables, replace)
      )
    end

    def is_enabled(feature_key, context = {}, options = {})
      @parent.is_enabled(feature_key, child_context(context), child_options(options))
    end

    def evaluate_flag(feature_key, context = {}, options = {})
      @parent.evaluate_flag(feature_key, child_context(context), child_options(options))
    end

    def get_variation(feature_key, context = {}, options = {})
      @parent.get_variation(feature_key, child_context(context), child_options(options))
    end

    def evaluate_variation(feature_key, context = {}, options = {})
      @parent.evaluate_variation(feature_key, child_context(context), child_options(options))
    end

    def get_variable(feature_or_variable_key, variable_key_or_context = nil, context_or_options = {}, options = {})
      delegate_variable(:get_variable, feature_or_variable_key, variable_key_or_context, context_or_options, options)
    end

    def evaluate_variable(feature_or_variable_key, variable_key_or_context = nil, context_or_options = {}, options = {})
      delegate_variable(:evaluate_variable, feature_or_variable_key, variable_key_or_context, context_or_options, options)
    end

    %i[boolean string integer double array object json].each do |type|
      define_method("get_variable_#{type}") do |feature_or_variable_key, variable_key_or_context = nil, context_or_options = {}, options = {}|
        delegate_variable("get_variable_#{type}".to_sym, feature_or_variable_key, variable_key_or_context, context_or_options, options)
      end
    end

    def get_feature_evaluations(context = {}, feature_keys = [], options = {})
      @parent.get_feature_evaluations(child_context(context), feature_keys, child_options(options))
    end

    def get_variable_evaluations(context = {}, variable_keys = [], options = {})
      @parent.get_variable_evaluations(child_context(context), variable_keys, child_options(options))
    end

    private

    def child_context(context)
      { **@context, **context }
    end

    def child_options(options)
      {
        **options,
        __featurevisor_child_sticky_features: @sticky_features,
        __featurevisor_child_sticky_variables: @sticky_variables
      }
    end

    def delegate_variable(method, first, second, third, fourth)
      if second.nil? || second.is_a?(Hash)
        @parent.public_send(method, first, child_context(second || {}), child_options(third))
      else
        @parent.public_send(method, first, second, child_context(third), child_options(fourth))
      end
    end
  end
end
