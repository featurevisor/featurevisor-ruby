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
      @evaluation_generation = 0
      @datafile_mutex = Mutex.new
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
        on_change: method(:invalidate_evaluation_memo),
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
      return unless diagnostic_interested?(level)

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
    # @return [Boolean] Whether the datafile was accepted, even if unchanged
    def set_datafile(datafile, replace = false)
      return false if @closed

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
        normalization_errors = []
        if parsed_datafile[:schemaVersion] == "2"
          parsed_datafile, normalization_errors = Normalize.datafile(parsed_datafile)
        end
        # Serialize merge and publication, leaving application callbacks outside.
        details = @datafile_mutex.synchronize do
          return false if @closed
          next_datafile = replace ? parsed_datafile : merge_datafiles(@datafile.get_datafile, parsed_datafile)
          new_datafile = InstanceEvaluationDataProvider.new(
            datafile: next_datafile,
            diagnostics: @diagnostics
          )
          new_datafile.retain_normalized(@datafile, parsed_datafile) unless replace
          event = Featurevisor::Events.get_params_for_datafile_set_event(@datafile, new_datafile, replace, parsed_datafile)
          @datafile = new_datafile
          @evaluation_generation += 1
          event
        end

        normalization_errors.each { |diagnostic| report_diagnostic(diagnostic) }

        report_diagnostic(
          level: "info",
          code: "datafile_set",
          message: "Datafile set",
          details: details
        )
        @emitter.trigger("datafile_set", details)
        true
      rescue => e
        report_diagnostic(
          level: "error",
          code: "invalid_datafile",
          message: "Could not parse datafile",
          original_error: e
        )
        false
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
      @evaluation_generation += 1

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
      @evaluation_generation += 1
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

    def invalidate_evaluation_memo
      @evaluation_generation += 1
    end
    private :invalidate_evaluation_memo

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
      @datafile_mutex.synchronize do
        return if @closed
        @closed = true
      end
      @modules_manager.close_all
      @module_diagnostic_subscriptions = []
      @emitter.clear_all
      @on_diagnostic = nil
      @datafile.clear_caches
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
      @evaluation_generation += 1

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
        raise if e.is_a?(RequirementError) && options[:__featurevisor_prerequisite]
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
        raise if e.is_a?(RequirementError) && options[:__featurevisor_prerequisite]
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
          if variable_type == "json" && !evaluation[:__featurevisor_decoded_json] && !evaluation.dig(:variable, :compose) &&
             evaluation[:variable_value].is_a?(String)
            JSON.parse(evaluation[:variable_value], symbolize_names: true)
          else
            evaluation[:variable_value]
          end
        else
          nil
        end
      rescue => e
        getter_options = variable_key_or_context.is_a?(String) ? options : context_or_options
        raise if e.is_a?(RequirementError) && getter_options[:__featurevisor_prerequisite]
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

    # Get variable as a number, whole or fractional
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Float, nil] Float value or nil
    def get_variable_number(*args)
      variable_value = get_variable(*args)
      get_value_by_type(variable_value, "number")
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
        context: options[:__featurevisor_effective_context] ? context : get_context(context)
      }
      session = options[:__featurevisor_session] || EvaluationSession.new
      evaluation_options[:dependency_of] = session.dependency_of if options[:__featurevisor_prerequisite]
      evaluation_options[:dependency_purpose] = options[:dependency_purpose] || "condition" if options[:__featurevisor_prerequisite]
      evaluation_options[:default_variable_value] = options[:default_variable_value] if options.key?(:default_variable_value)
      begin
        # Only prerequisite entries fingerprint effective dependency inputs.
        session_options = options[:__featurevisor_prerequisite] ? global_variable_session_options(evaluation_options, options) : evaluation_options
        return session.run(session_options,
                           prerequisite: options[:__featurevisor_prerequisite]) do
        unless @modules_manager.get_all.empty?
          evaluation_options = @modules_manager.run_before_evaluation_modules(evaluation_options)
        end
        session.update_current(evaluation_options)
        resolved_key = evaluation_options[:variable_key]
        variable = @datafile.get_global_variable(resolved_key)
        sticky = options[:__featurevisor_sticky_variables_source]&.call || options[:__featurevisor_child_sticky_variables] || @sticky_variables
        evaluation = { type: "variable", variable_key: resolved_key, reason: Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND }

        if sticky.key?(resolved_key) || sticky.key?(resolved_key.to_sym)
          sticky_value = sticky.key?(resolved_key) ? sticky[resolved_key] : sticky[resolved_key.to_sym]
          evaluation.merge!(reason: Featurevisor::EvaluationReason::STICKY, variable: variable,
                            variable_value: sticky_value)
        elsif variable
          dependencies = get_evaluation_dependencies(evaluation_options[:context], options.merge(__featurevisor_effective_context: true, __featurevisor_session: session))
          if variable.key?(:conditions) && !UnifiedConditions.matches?(variable[:conditions], dependencies)
            value_key = !variable[:compose] && variable[:useDefaultWhenDisabled] ? :defaultValue : :disabledValue
            evaluation.merge!(reason: Featurevisor::EvaluationReason::CONDITIONS_UNMET,
                              conditions: variable[:conditions], variable: variable)
            evaluation[:variable_value] = variable[value_key] if variable.key?(value_key)
            evaluation[:variable_value] = nil if variable[:compose] && !variable.key?(value_key)
            if variable[:compose].is_a?(Array) && evaluation[:variable_value].is_a?(Hash)
              evaluation[:variable_value] = evaluation[:variable_value].dup
            end
          else
            if variable[:compose]
              evaluation.merge!(reason: Featurevisor::EvaluationReason::VARIABLE_COMPOSED,
                                variable: variable, variable_value: compose_value(variable[:compose], dependencies))
            end
            program = variable[:overrideProgram]
            overrides = program || (variable[:compose] ? [] : variable[:overrides]) || []
            accumulated_value = variable[:compose] ? evaluation[:variable_value] : variable[:defaultValue]
            applied_paths = []
            index = 0
            while index < overrides.length
              override = overrides[index]
              matched = !override.key?(:conditions) || UnifiedConditions.matches?(override[:conditions], dependencies)
              if matched
                if program
                  accumulated_value = Mutations.apply(accumulated_value, override[:operations])
                  if variable[:compose].is_a?(Array) && override[:operations].any? { |operation| operation[:op] == "set" && operation[:path].empty? }
                    accumulated_value = accumulated_value.dup
                  end
                  applied_paths << (override[:keyPath] || [override[:key]])
                end
                evaluation.merge!(reason: Featurevisor::EvaluationReason::VARIABLE_OVERRIDE_RULE,
                                  variable: variable, variable_override_index: index,
                                  variable_override_key: override[:key], variable_override_path: override[:keyPath])
                evaluation[:variable_value] = program ? accumulated_value : override[:value]
                evaluation[:variable_override_paths] = applied_paths.dup if program
                break unless program
              end
              next_index = program ? override[matched ? :onMatch : :onMiss] : index + 1
              if program && (!next_index.is_a?(Integer) || next_index <= index || next_index > overrides.length)
                raise ArgumentError, "Invalid variable override program jump"
              end
              index = next_index
            end
            if evaluation[:reason] == Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND
              evaluation.merge!(reason: Featurevisor::EvaluationReason::VARIABLE_DEFAULT,
                                variable: variable)
              evaluation[:variable_value] = variable[:defaultValue] if variable.key?(:defaultValue)
            end
          end
          report_diagnostic(level: "warn", code: "deprecated_variable", message: "Variable \"#{resolved_key}\" is deprecated",
                            details: { variableKey: resolved_key, evaluation: evaluation }) if variable[:deprecated]
        end

        if !evaluation.key?(:variable_value) && evaluation_options.key?(:default_variable_value)
          evaluation[:variable_value] = evaluation_options[:default_variable_value]
        end
        unless @modules_manager.get_all.empty?
          evaluation = @modules_manager.run_after_evaluation_modules(evaluation, evaluation_options)
        end
        report_diagnostic(level: "debug", code: evaluation[:reason], message: "Global variable evaluated", details: evaluation)
        evaluation
        end
      rescue => e
        raise if e.is_a?(RequirementError) && options[:__featurevisor_prerequisite]
        evaluation = { type: "variable", variable_key: evaluation_options[:variable_key],
                       reason: Featurevisor::EvaluationReason::ERROR, error: e }
        session.remember(global_variable_session_options(evaluation_options, options).merge(__featurevisor_prerequisite: true), evaluation) if options[:__featurevisor_prerequisite]
        report_diagnostic(level: "error", code: "evaluation_error", message: "Global variable evaluation failed",
                          originalError: e, details: evaluation)
        evaluation
      end
    end

    def global_variable_session_options(evaluation_options, options)
      evaluation_options.merge(
        sticky: options[:__featurevisor_sticky_features_source]&.call || options[:__featurevisor_child_sticky_features] || @sticky_features,
        sticky_variables: options[:__featurevisor_sticky_variables_source]&.call || options[:__featurevisor_child_sticky_variables] || @sticky_variables,
        datafile: @datafile,
        __featurevisor_generation: -> { @evaluation_generation },
        __featurevisor_child_generation: options[:__featurevisor_child_generation],
        __featurevisor_project_variable: options[:__featurevisor_project_variable]
      )
    end

    def project_variable_dependency(evaluation)
      return evaluation unless evaluation.key?(:variable_value)
      type = evaluation.dig(:variable_schema, :type) || evaluation.dig(:variable, :type)
      return evaluation unless type == "json" && !evaluation.dig(:variable, :compose) && evaluation[:variable_value].is_a?(String)

      evaluation.merge(variable_value: JSON.parse(evaluation[:variable_value], symbolize_names: true), __featurevisor_decoded_json: true)
    rescue JSON::ParserError => error
      report_diagnostic(level: "error", code: "evaluation_error", message: "getVariable failed", originalError: error,
                        details: { featureKey: evaluation[:feature_key], variableKey: evaluation[:variable_key] })
      evaluation.merge(variable_value: nil, __featurevisor_decoded_json: true)
    end

    def evaluate_required_variable(required, dependencies)
        options = {
        __featurevisor_sticky_features_source: dependencies[:__featurevisor_sticky_features_source],
        __featurevisor_sticky_variables_source: dependencies[:__featurevisor_sticky_variables_source],
        __featurevisor_child_generation: dependencies[:__featurevisor_child_generation],
        __featurevisor_session: dependencies[:__featurevisor_session],
        __featurevisor_prerequisite: true,
        __featurevisor_effective_context: true,
        dependency_purpose: "condition",
        __featurevisor_project_variable: method(:project_variable_dependency)
      }
      if required[:feature]
        get_variable(required[:feature], required[:variable], dependencies[:context], options)
      else
        get_variable(required[:variable], dependencies[:context], options)
      end
    end

    def composition_source(reference, dependencies)
      context = dependencies[:context]
      options = {
        __featurevisor_session: dependencies[:__featurevisor_session],
        __featurevisor_prerequisite: true,
        __featurevisor_effective_context: true,
        __featurevisor_sticky_features_source: dependencies[:__featurevisor_sticky_features_source],
        __featurevisor_sticky_variables_source: dependencies[:__featurevisor_sticky_variables_source],
        __featurevisor_child_generation: dependencies[:__featurevisor_child_generation],
        dependency_purpose: "composition",
        __featurevisor_project_variable: method(:project_variable_dependency)
      }
      if reference.key?(:variable)
        reference.key?(:feature) ? get_variable(reference[:feature], reference[:variable], context, options) : get_variable(reference[:variable], context, options)
      elsif reference[:variation]
        get_variation(reference[:feature], context, options)
      else
        is_enabled(reference[:feature], context, options)
      end
    end

    def compose_value(compose, dependencies)
      return composition_source({ variable: compose }, dependencies) if compose.is_a?(String)
      raise RequirementError, "Invalid composition" unless compose.is_a?(Array) && !compose.empty?
      compose.each_with_object({}) do |reference, result|
        key = reference[:key]
        if !key.is_a?(String) || key.empty? || %w[__proto__ prototype constructor].include?(key)
          raise RequirementError, "Invalid composition property"
        end
        result[key.to_sym] = composition_source(reference, dependencies)
      end
    end

    def variable_condition_matches?(required, dependencies)
      value = evaluate_required_variable(required, dependencies)
      if required.key?(:path)
        raise ArgumentError, "Variable requirement path must be compiled" unless required[:path].is_a?(Array)
        required[:path].each do |part|
          raise ArgumentError, "Unsafe variable requirement path" if %w[__proto__ prototype constructor].include?(part)
          index = Mutations.send(:array_index, part)
          if part.is_a?(Numeric) && index.nil?
            raise ArgumentError, "Invalid variable requirement path"
          end
          value = if !index.nil?
                    value.is_a?(Array) && index < value.length ? value[index] : Conditions.missing_value
                  elsif part.is_a?(String)
                    if value.is_a?(Hash)
                      key = value.key?(part.to_sym) ? part.to_sym : part
                      value.key?(key) ? value[key] : Conditions.missing_value
                    elsif value.is_a?(Array) && part == "length"
                      value.length
                    elsif value.is_a?(Array) && part.match?(/\A(?:0|[1-9]\d*)\z/) && part.to_i < value.length
                      value[part.to_i]
                    else
                      Conditions.missing_value
                    end
                  else
                    raise ArgumentError, "Invalid variable requirement path"
                  end
        end
      end
      Conditions.value_is_matched(value, required, ->(pattern, flags) { @datafile.get_regex(pattern, flags) })
    rescue RequirementError
      raise
    rescue => error
      raise RequirementError, error.message
    end

    # Get evaluation dependencies
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation dependencies
    def get_evaluation_dependencies(context, options = {})
      sticky_source = options[:__featurevisor_sticky_features_source] ||
                      -> { options[:__featurevisor_child_sticky_features] || @sticky_features }
      variable_source = options[:__featurevisor_sticky_variables_source] ||
                        -> { options[:__featurevisor_child_sticky_variables] || @sticky_variables }
      {
        context: options[:__featurevisor_effective_context] ? context : get_context(context),
        diagnostics: @diagnostics,
        modules_manager: @modules_manager,
        datafile: @datafile,
        __featurevisor_instance: self,
        sticky: sticky_source.call,
        sticky_variables: variable_source.call,
        __featurevisor_project_variable: options[:__featurevisor_project_variable],
        __featurevisor_session: options[:__featurevisor_session],
        __featurevisor_prerequisite: options[:__featurevisor_prerequisite],
        __featurevisor_generation: -> { @evaluation_generation },
        __featurevisor_child_generation: options[:__featurevisor_child_generation],
        __featurevisor_sticky_features_source: sticky_source,
        __featurevisor_sticky_variables_source: variable_source,
        __featurevisor_datafile_source: -> { @datafile },
      }.tap do |dependencies|
        dependencies[:dependency_purpose] = options[:dependency_purpose] if options[:dependency_purpose]
        dependencies[:dependency_of] = options[:__featurevisor_session].dependency_of if options[:__featurevisor_prerequisite] && options[:__featurevisor_session]
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
      when "number"
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
          next -> {} if @closed

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
      return unless diagnostic_interested?((diagnostic || {})[:level] || "info", source_module)

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

    # Check live subscriptions before copying and formatting evaluation details.
    # Errors also reach the error event, independently of diagnostic levels.
    def diagnostic_interested?(level, source_module = nil)
      return true if level == "error"

      # The default console reporter and explicit handlers have historically
      # handled unrecognized levels differently. Preserve both policies.
      instance_interested = if @on_diagnostic
                              should_report_diagnostic?(level, @diagnostics.level)
                            else
                              LOG_LEVELS.index(level).to_i <= LOG_LEVELS.index(@diagnostics.level).to_i
                            end
      instance_interested ||
        @module_diagnostic_subscriptions.any? do |subscription|
          (!source_module || subscription[:module_id] != source_module.id) &&
            should_report_diagnostic?(level, subscription[:level])
        end
    end
    private :diagnostic_interested?

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
