# frozen_string_literal: true

require "json"
require "securerandom"

module Featurevisor
  # Instance class for managing feature flag evaluations
  class Instance
    # Empty datafile template
    EMPTY_DATAFILE = {
      schemaVersion: "2",
      revision: "unknown",
      segments: {},
      features: {},
      variables: {}
    }.freeze

    # Initialize a new Featurevisor instance
    # @param options [Hash] Instance options
    # @option options [Hash, String] :datafile Datafile content or JSON string
    # @option options [Hash] :context Initial context
    # @option options [String] :log_level Log level
    # @option options [Hash] :sticky_features Sticky features
    # @option options [Array<Hash, FeaturevisorModule>] :modules Array of modules
    # @option options [Proc] :on_diagnostic Diagnostic handler
    def initialize(options = {})
      # from options
      @context = options[:context] || {}
      @diagnostics = DiagnosticReporter.new(
        level: options[:log_level] || "info",
        handler: method(:handle_evaluation_diagnostic)
      )
      @on_diagnostic = options[:on_diagnostic] || options[:onDiagnostic]
      @emitter = Featurevisor::Emitter.new
      @sticky_features = options[:sticky_features] || options[:stickyFeatures] || {}
      @sticky_variables = options[:sticky_variables] || options[:stickyVariables] || {}
      @closed = false
      @module_diagnostic_subscriptions = []

      # datafile
      @datafile = InstanceEvaluationDataProvider.new(
        datafile: EMPTY_DATAFILE,
        diagnostics: @diagnostics
      )

      @modules_manager = Featurevisor::Modules::ModulesManager.new(
        modules: options[:modules] || [],
        report_diagnostic: method(:report_diagnostic),
        module_api_factory: method(:create_module_api),
        clear_module_diagnostic_subscriptions: method(:clear_module_diagnostic_subscriptions)
      )

      if options[:datafile]
        set_datafile(options[:datafile], true)
      end

      report_diagnostic(
        level: "info",
        code: "sdk_initialized",
        message: "SDK initialized"
      )
    end

    # Set the log level
    # @param level [String] Log level
    def set_log_level(level)
      @diagnostics.set_level(level)
    end

    def handle_evaluation_diagnostic(level, message, details = nil)
      details = (details || {}).dup
      code = details.delete(:code) || details.delete("code") || details[:reason] || details["reason"] || message
      code = "deprecated_feature" if message == "feature is deprecated"
      code = "deprecated_variable" if message == "variable is deprecated"
      code = "feature_not_found" if message == "feature not found"
      code = "variable_not_found" if message == "variable schema not found"
      code = "no_variations" if message == "no variations"
      code = "invalid_bucket_by" if message == "invalid bucketBy"
      code = "evaluation_error" if message == "Error during evaluation"
      code = "conditions_parse_error" if message == "Error parsing conditions"
      original_error = details.delete(:error) || details.delete("error")
      nested_details = details.delete(:details) || details.delete("details")
      details.merge!(nested_details) if nested_details.is_a?(Hash)
      if details.key?(:feature_key) && details.key?(:reason)
        evaluation = details.dup
        details = {
          featureKey: evaluation[:feature_key],
          variableKey: evaluation[:variable_key],
          reason: evaluation[:reason],
          evaluation: camelize_diagnostic_value(evaluation)
        }
      end
      report_diagnostic(level: level, code: code.to_s, message: message, details: details, originalError: original_error)
    end
    private :handle_evaluation_diagnostic

    # Set the datafile
    # @param datafile [Hash, String] Datafile content or JSON string
    # @param replace [Boolean] Whether to replace instead of merge
    def set_datafile(datafile, replace = false)
      return if @closed

      begin
        parsed_datafile = if datafile.is_a?(String)
                            JSON.parse(datafile, symbolize_names: true)
                          elsif datafile.is_a?(Hash)
                            JSON.parse(JSON.generate(datafile), symbolize_names: true)
                          else
                            datafile
                          end
        unless parsed_datafile.is_a?(Hash) && parsed_datafile[:schemaVersion].is_a?(String) &&
               parsed_datafile[:revision].is_a?(String) && parsed_datafile[:segments].is_a?(Hash) &&
               parsed_datafile[:features].is_a?(Hash) &&
               (!parsed_datafile.key?(:variables) || parsed_datafile[:variables].is_a?(Hash))
          raise ArgumentError, "Invalid datafile"
        end
        next_datafile = replace ? parsed_datafile : merge_datafiles(@datafile.get_datafile, parsed_datafile)
        new_datafile = InstanceEvaluationDataProvider.new(
          datafile: next_datafile,
          diagnostics: @diagnostics
        )

        details = Featurevisor::Events.get_params_for_datafile_set_event(@datafile, new_datafile, replace)
        @datafile = new_datafile

        report_diagnostic(
          level: "info",
          code: "datafile_set",
          message: "Datafile set",
          details: details
        )
        @emitter.trigger("datafile_set", details)
      rescue => e
        report_diagnostic(
          level: "error",
          code: "invalid_datafile",
          message: "Could not parse datafile",
          original_error: e
        )
      end
    end

    # Set sticky features
    # @param sticky [Hash] Sticky features
    # @param replace [Boolean] Whether to replace existing sticky features
    def set_sticky_features(sticky, replace = false)
      previous_sticky_features = @sticky_features || {}

      if replace
        @sticky_features = sticky
      else
        @sticky_features = {
          **@sticky_features,
          **sticky
        }
      end

      params = Featurevisor::Events.get_params_for_sticky_features_set_event(previous_sticky_features, @sticky_features, replace)

      report_diagnostic(
        level: "info",
        code: "sticky_features_set",
        message: "Sticky features set",
        details: params
      )
      @emitter.trigger("sticky_features_set", params)
    end

    def set_sticky_variables(sticky, replace = false)
      previous = @sticky_variables || {}
      @sticky_variables = replace ? sticky : { **@sticky_variables, **sticky }
      params = Featurevisor::Events.get_params_for_sticky_variables_set_event(previous, @sticky_variables, replace)
      report_diagnostic(level: "info", code: "sticky_variables_set", message: "Sticky variables set", details: params)
      @emitter.trigger("sticky_variables_set", params)
    end

    # Get the revision
    # @return [String] Revision string
    def get_revision
      @datafile.get_revision
    end

    def get_schema_version
      @datafile.get_schema_version
    end

    def get_segment(segment_key)
      @datafile.get_segment(segment_key)
    end

    def get_feature_keys
      @datafile.get_feature_keys
    end

    def get_variable_keys(feature_key = nil)
      @datafile.get_variable_keys(feature_key)
    end

    def has_variations?(feature_key)
      @datafile.has_variations?(feature_key)
    end

    # Get a feature by key
    # @param feature_key [String] Feature key
    # @return [Hash, nil] Feature data or nil if not found
    def get_feature(feature_key)
      @datafile.get_feature(feature_key)
    end

    # Add a module
    # @param mod [Hash, FeaturevisorModule] Module to add
    # @return [Proc, nil] Remove function or nil if module already exists
    def add_module(mod)
      @modules_manager.add(mod)
    end

    def remove_module(name)
      @modules_manager.remove(name)
    end

    # Subscribe to an event
    # @param event_name [String] Event name
    # @param callback [Proc] Callback function
    # @return [Proc] Unsubscribe function
    def on(event_name, callback)
      return -> {} if @closed

      @emitter.on(event_name, callback)
    end

    # Close the instance
    def close
      return if @closed

      @closed = true
      @modules_manager.close_all
      @module_diagnostic_subscriptions = []
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

      report_diagnostic(
        level: "debug",
        code: "context_set",
        message: replace ? "Context replaced" : "Context updated",
        details: {
          context: @context,
          replaced: replace
        }
      )
    end

    # Get context
    # @param context [Hash, nil] Additional context to merge
    # @return [Hash] Merged context
    def get_context(context = nil)
      if context
        {
          **@context,
          **context
        }
      else
        @context
      end
    end

    # Spawn a child instance
    # @param context [Hash] Child context
    # @param options [Hash] Override options
    # @return [ChildInstance] Child instance
    def spawn(context = {}, options = {})
      Featurevisor::ChildInstance.new(
        parent: self,
        context: get_context(context),
        sticky_features: options[:sticky_features] || options[:stickyFeatures],
        sticky_variables: options[:sticky_variables] || options[:stickyVariables]
      )
    end

    # Evaluate a flag
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation result
    def evaluate_flag(feature_key, context = {}, options = {})
      Featurevisor::Evaluate.evaluate_with_modules(
        get_evaluation_dependencies(context, options).merge(
          type: "flag",
          feature_key: feature_key
        )
      )
    end

    # Check if a feature is enabled
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Boolean] True if feature is enabled
    def is_enabled(feature_key, context = {}, options = {})
      begin
        evaluation = evaluate_flag(feature_key, context, options)
        evaluation[:enabled] == true
      rescue => e
        report_diagnostic(level: "error", code: "evaluation_error", message: "isEnabled failed", originalError: e, details: { featureKey: feature_key })
        false
      end
    end

    # Evaluate a variation
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation result
    def evaluate_variation(feature_key, context = {}, options = {})
      Featurevisor::Evaluate.evaluate_with_modules(
        get_evaluation_dependencies(context, options).merge(
          type: "variation",
          feature_key: feature_key
        )
      )
    end

    # Get variation value
    # @param feature_key [String] Feature key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [String, nil] Variation value or nil
    def get_variation(feature_key, context = {}, options = {})
      begin
        evaluation = evaluate_variation(feature_key, context, options)

        if evaluation.key?(:variation_value)
          evaluation[:variation_value]
        elsif evaluation[:variation]
          evaluation[:variation][:value]
        else
          nil
        end
      rescue => e
        report_diagnostic(level: "error", code: "evaluation_error", message: "getVariation failed", originalError: e, details: { featureKey: feature_key })
        nil
      end
    end

    # Evaluate a variable
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation result
    def evaluate_variable(feature_or_variable_key, variable_key_or_context = nil, context_or_options = {}, options = {})
      if variable_key_or_context.nil? || variable_key_or_context.is_a?(Hash)
        context = variable_key_or_context || {}
        return evaluate_variable_without_feature(feature_or_variable_key, context, context_or_options)
      end

      Featurevisor::Evaluate.evaluate_with_modules(
        get_evaluation_dependencies(context_or_options, options).merge(
          type: "variable",
          feature_key: feature_or_variable_key,
          variable_key: variable_key_or_context
        )
      )
    end

    # Get variable value
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] Variable value or nil
    def get_variable(feature_or_variable_key, variable_key_or_context = nil, context_or_options = {}, options = {})
      begin
        evaluation = evaluate_variable(feature_or_variable_key, variable_key_or_context, context_or_options, options)

        if evaluation.key?(:variable_value)
          variable_type = evaluation.dig(:variable_schema, :type) || evaluation.dig(:variable, :type)
          if variable_type == "json" &&
             evaluation[:variable_value].is_a?(String)
            JSON.parse(evaluation[:variable_value], symbolize_names: true)
          else
            evaluation[:variable_value]
          end
        else
          nil
        end
      rescue => e
        report_diagnostic(level: "error", code: "evaluation_error", message: "getVariable failed", originalError: e, details: { variableKey: variable_key_or_context || feature_or_variable_key })
        nil
      end
    end

    # Get variable as boolean
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Boolean, nil] Boolean value or nil
    def get_variable_boolean(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "boolean")
    end

    # Get variable as string
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [String, nil] String value or nil
    def get_variable_string(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "string")
    end

    # Get variable as integer
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Integer, nil] Integer value or nil
    def get_variable_integer(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "integer")
    end

    # Get variable as double
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Float, nil] Float value or nil
    def get_variable_double(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "double")
    end

    # Get variable as array
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Array, nil] Array value or nil
    def get_variable_array(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "array")
    end

    # Get variable as object
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash, nil] Object value or nil
    def get_variable_object(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "object")
    end

    # Get variable as JSON
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] JSON value or nil
    def get_variable_json(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "json")
    end

    # Get all evaluations
    # @param context [Hash] Context
    # @param feature_keys [Array<String>] Feature keys to evaluate
    # @param options [Hash] Override options
    # @return [Hash] All evaluations
    def get_feature_evaluations(context = {}, feature_keys = [], options = {})
      result = {}

      keys = feature_keys.size > 0 ? feature_keys : @datafile.get_feature_keys

      keys.each do |feature_key|
        # Convert symbol keys to strings for evaluation functions
        feature_key_str = feature_key.to_s

        # isEnabled
        evaluated_feature = {
          enabled: is_enabled(feature_key_str, context, options)
        }

        # variation
        if @datafile.has_variations?(feature_key_str)
          variation = get_variation(feature_key_str, context, options)
          evaluated_feature[:variation] = variation unless variation.nil?
        end

        # variables
        variable_keys = @datafile.get_variable_keys(feature_key_str)
        if variable_keys.size > 0
          evaluated_feature[:variables] = {}

          variable_keys.each do |variable_key|
            evaluated_feature[:variables][variable_key] = get_variable(
              feature_key_str,
              variable_key,
              context,
              options
            )
          end
        end

        result[feature_key] = evaluated_feature
      end

      result
    end

    def get_variable_evaluations(context = {}, variable_keys = [], options = {})
      keys = variable_keys.empty? ? @datafile.get_variable_keys : variable_keys
      keys.to_h { |key| [key, get_variable(key.to_s, context, options)] }
    end

    private

    def evaluate_variable_without_feature(variable_key, context = {}, options = {})
      evaluation_options = {
        type: "variable",
        variable_key: variable_key.to_s,
        context: get_context(context)
      }
      evaluation_options[:default_variable_value] = options[:default_variable_value] if options.key?(:default_variable_value)
      begin
        evaluation_options = @modules_manager.run_before_evaluation_modules(evaluation_options)
        resolved_key = evaluation_options[:variable_key]
        variable = @datafile.get_global_variable(resolved_key)
        sticky = options[:__featurevisor_child_sticky_variables] || @sticky_variables
        evaluation = { type: "variable", variable_key: resolved_key, reason: Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND }

        if sticky.key?(resolved_key) || sticky.key?(resolved_key.to_sym)
          sticky_value = sticky.key?(resolved_key) ? sticky[resolved_key] : sticky[resolved_key.to_sym]
          evaluation.merge!(reason: Featurevisor::EvaluationReason::STICKY, variable: variable,
                            variable_value: sticky_value)
        elsif variable
          unless required_features_are_matched(variable[:requiredFeatures], evaluation_options[:context], options)
            value_key = variable[:useDefaultWhenDisabled] ? :defaultValue : :disabledValue
            evaluation.merge!(reason: Featurevisor::EvaluationReason::REQUIRED_FEATURES_UNMET,
                              variable: variable)
            evaluation[:variable_value] = variable[value_key] if variable.key?(value_key)
          else
            (variable[:overrides] || []).each_with_index do |override, index|
              next unless required_features_are_matched(override[:requiredFeatures], evaluation_options[:context], options)
              conditions_match = !override[:conditions] || @datafile.all_conditions_are_matched(
                @datafile.parse_conditions_if_stringified(override[:conditions]), evaluation_options[:context]
              )
              segments_match = !override[:segments] || @datafile.all_segments_are_matched(
                @datafile.parse_segments_if_stringified(override[:segments]), evaluation_options[:context]
              )
              next unless conditions_match && segments_match

              evaluation.merge!(reason: Featurevisor::EvaluationReason::VARIABLE_OVERRIDE_RULE,
                                variable: variable,
                                variable_override_index: index, variable_override_key: override[:key],
                                variable_override_path: override[:keyPath])
              evaluation[:variable_value] = override[:value] if override.key?(:value)
              break
            end
            if evaluation[:reason] == Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND
              evaluation.merge!(reason: Featurevisor::EvaluationReason::VARIABLE_DEFAULT,
                                variable: variable)
              evaluation[:variable_value] = variable[:defaultValue] if variable.key?(:defaultValue)
            end
          end
          report_diagnostic(level: "warn", code: "variable_deprecated", message: "Variable \"#{resolved_key}\" is deprecated",
                            details: { variableKey: resolved_key, evaluation: evaluation }) if variable[:deprecated]
        end

        if !evaluation.key?(:variable_value) && evaluation_options.key?(:default_variable_value)
          evaluation[:variable_value] = evaluation_options[:default_variable_value]
        end
        evaluation = @modules_manager.run_global_after_modules(evaluation, evaluation_options)
        report_diagnostic(level: "debug", code: evaluation[:reason], message: "Global variable evaluated", details: evaluation)
        evaluation
      rescue => e
        evaluation = { type: "variable", variable_key: evaluation_options[:variable_key],
                       reason: Featurevisor::EvaluationReason::ERROR, error: e }
        report_diagnostic(level: "error", code: "evaluation_error", message: "Global variable evaluation failed",
                          originalError: e, details: evaluation)
        evaluation
      end
    end

    def required_features_are_matched(requirements, context, options)
      return true if requirements.nil?

      items = requirements.is_a?(Array) ? requirements : [requirements]
      clean_options = options.reject { |key, _| %i[default_variation_value default_variable_value].include?(key) }
      items.all? do |required|
        if required.is_a?(String)
          key = required
          expected_enabled = true
          expected_variation = nil
        else
          key = required[:feature]
          expected_enabled = required.key?(:enabled) ? required[:enabled] : true
          expected_variation = required[:variation]
        end
        next false unless is_enabled(key, context, clean_options) == expected_enabled
        expected_variation.nil? || get_variation(key, context, clean_options) == expected_variation
      end
    end

    # Get evaluation dependencies
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation dependencies
    def get_evaluation_dependencies(context, options = {})
      {
        context: get_context(context),
        diagnostics: @diagnostics,
        modules_manager: @modules_manager,
        datafile: @datafile,
        sticky: options[:__featurevisor_child_sticky_features] || @sticky_features,
        sticky_variables: options[:__featurevisor_child_sticky_variables] || @sticky_variables,
      }.tap do |dependencies|
        dependencies[:default_variation_value] = options[:default_variation_value] if options.key?(:default_variation_value)
        dependencies[:default_variable_value] = options[:default_variable_value] if options.key?(:default_variable_value)
      end
    end

    # Get value by type
    # @param value [Object] Value to convert
    # @param type [String] Target type
    # @return [Object] Converted value
    def get_value_by_type(value, type)
      return nil if value.nil?

      case type
      when "string"
        value.is_a?(String) ? value : nil
      when "integer"
        return value if value.is_a?(Integer)
        value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i : nil
      when "double"
        value.is_a?(Numeric) && value.finite? ? value.to_f : nil
      when "boolean"
        value == true || value == false ? value : nil
      when "array"
        value.is_a?(Array) ? value : nil
      when "object"
        value.is_a?(Hash) ? value : nil
      # @NOTE: `json` is not handled here intentionally
      else
        value
      end
    rescue
      nil
    end

    def merge_datafiles(previous, incoming)
      previous ||= EMPTY_DATAFILE
      incoming ||= EMPTY_DATAFILE

      {
        schemaVersion: incoming[:schemaVersion],
        revision: incoming[:revision],
        featurevisorVersion: incoming[:featurevisorVersion],
        segments: {
          **(previous[:segments] || {}),
          **(incoming[:segments] || {})
        },
        features: {
          **(previous[:features] || {}),
          **(incoming[:features] || {})
        },
        variables: {
          **(previous[:variables] || {}),
          **(incoming[:variables] || {})
        }
      }.compact
    end

    def create_module_api(mod)
      instance = self
      {
        get_revision: -> { instance.get_revision },
        on_diagnostic: lambda do |handler, options = {}|
          subscription = {
            id: SecureRandom.uuid,
            module_id: mod.id,
            handler: handler,
            level: options[:level] || options[:log_level] || "info"
          }
          @module_diagnostic_subscriptions << subscription
          -> { @module_diagnostic_subscriptions.reject! { |item| item[:id] == subscription[:id] } }
        end,
        report_diagnostic: ->(diagnostic) { report_diagnostic(diagnostic, mod) }
      }
    end

    def clear_module_diagnostic_subscriptions(mod)
      @module_diagnostic_subscriptions.reject! { |item| item[:module_id] == mod.id }
    end

    def report_diagnostic(diagnostic, source_module = nil)
      diagnostic = (diagnostic || {}).dup
      diagnostic[:level] ||= "info"
      diagnostic[:module] = source_module.name if source_module && source_module.name
      details = camelize_diagnostic_value((diagnostic[:details] || {}).dup)
      legacy_module_name = diagnostic.delete(:module_name)
      legacy_original_error = diagnostic.delete(:original_error)
      diagnostic[:moduleName] = legacy_module_name if !diagnostic.key?(:moduleName) && !legacy_module_name.nil?
      diagnostic[:originalError] = legacy_original_error if !diagnostic.key?(:originalError) && !legacy_original_error.nil?
      diagnostic.each do |key, value|
        next if %i[level code message module moduleName originalError details].include?(key)

        details[key] = value
      end
      diagnostic.select! { |key, _| %i[level code message module moduleName originalError details].include?(key) }
      diagnostic[:details] = details

      @module_diagnostic_subscriptions.dup.each do |subscription|
        next if source_module && subscription[:module_id] == source_module.id
        next unless should_report_diagnostic?(diagnostic[:level], subscription[:level])

        begin
          subscription[:handler].call(diagnostic)
        rescue => e
          Kernel.warn("[Featurevisor] Diagnostic handler failed: #{e}")
        end
      end

      if @on_diagnostic
        if should_report_diagnostic?(diagnostic[:level], @diagnostics.level)
          begin
            @on_diagnostic.call(diagnostic)
          rescue => e
            Kernel.warn("[Featurevisor] Diagnostic handler failed: #{e}")
          end
        end
      else
        DiagnosticReporter.new(level: @diagnostics.level).log(
          diagnostic[:level],
          diagnostic[:message],
          diagnostic
        )
      end

      if diagnostic[:level] == "error"
        @emitter.trigger("error", diagnostic: diagnostic)
      end
    end

    def should_report_diagnostic?(diagnostic_level, subscriber_level)
      levels = Featurevisor::LOG_LEVELS
      diagnostic_index = levels.index(diagnostic_level || "info")
      subscriber_index = levels.index(subscriber_level || "info")

      return false if diagnostic_index.nil? || subscriber_index.nil?

      subscriber_index >= diagnostic_index
    end

    def camelize_diagnostic_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          normalized_key = key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }.to_sym
          result[normalized_key] = camelize_diagnostic_value(item)
        end
      when Array
        value.map { |item| camelize_diagnostic_value(item) }
      else
        value
      end
    end
    private :camelize_diagnostic_value
  end

  # Create a new Featurevisor instance
  # @param options [Hash] Instance options
  # @return [Instance] New instance
  def self.create_featurevisor(options = {})
    Instance.new(options)
  end
end
