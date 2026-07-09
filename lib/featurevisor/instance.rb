# frozen_string_literal: true

require "json"
require "securerandom"

module Featurevisor
  # Instance class for managing feature flag evaluations
  class Instance
    attr_reader :context, :logger, :sticky, :datafile_reader, :modules_manager, :emitter

    # Empty datafile template
    EMPTY_DATAFILE = {
      schemaVersion: "2",
      revision: "unknown",
      segments: {},
      features: {}
    }.freeze

    # Initialize a new Featurevisor instance
    # @param options [Hash] Instance options
    # @option options [Hash, String] :datafile Datafile content or JSON string
    # @option options [Hash] :context Initial context
    # @option options [String] :log_level Log level
    # @option options [Logger] :logger Logger instance
    # @option options [Hash] :sticky Sticky features
    # @option options [Array<Hash, FeaturevisorModule>] :modules Array of modules
    # @option options [Proc] :on_diagnostic Diagnostic handler
    def initialize(options = {})
      # from options
      @context = options[:context] || {}
      @logger = options[:logger] || Featurevisor.create_logger(level: options[:log_level] || "info")
      @on_diagnostic = options[:on_diagnostic] || options[:onDiagnostic]
      @emitter = Featurevisor::Emitter.new
      @sticky = options[:sticky] || {}
      @closed = false
      @module_diagnostic_subscriptions = []

      # datafile
      @datafile_reader = DatafileReader.new(
        datafile: EMPTY_DATAFILE,
        logger: @logger
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
        message: "Featurevisor SDK initialized"
      )
    end

    # Set the log level
    # @param level [String] Log level
    def set_log_level(level)
      @logger.set_level(level)
    end

    # Set the datafile
    # @param datafile [Hash, String] Datafile content or JSON string
    # @param replace [Boolean] Whether to replace instead of merge
    def set_datafile(datafile, replace = false)
      return if @closed

      begin
        parsed_datafile = datafile.is_a?(String) ? JSON.parse(datafile, symbolize_names: true) : datafile
        next_datafile = replace ? parsed_datafile : merge_datafiles(@datafile_reader.get_datafile, parsed_datafile)
        new_datafile_reader = DatafileReader.new(
          datafile: next_datafile,
          logger: @logger
        )

        details = Featurevisor::Events.get_params_for_datafile_set_event(@datafile_reader, new_datafile_reader, replace)
        @datafile_reader = new_datafile_reader

        @emitter.trigger("datafile_set", details)
        report_diagnostic(
          level: "info",
          code: "datafile_set",
          message: "Datafile set",
          details: details
        )
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

      report_diagnostic(
        level: "info",
        code: "sticky_set",
        message: "Sticky features set",
        details: params
      )
      @emitter.trigger("sticky_set", params)
    end

    # Get the revision
    # @return [String] Revision string
    def get_revision
      @datafile_reader.get_revision
    end

    # Get a feature by key
    # @param feature_key [String] Feature key
    # @return [Hash, nil] Feature data or nil if not found
    def get_feature(feature_key)
      @datafile_reader.get_feature(feature_key)
    end

    # Add a module
    # @param mod [Hash, FeaturevisorModule] Module to add
    # @return [Proc, nil] Remove function or nil if module already exists
    def add_module(mod)
      @modules_manager.add(mod)
    end

    def remove_module(name_or_module)
      @modules_manager.remove(name_or_module)
    end

    # Subscribe to an event
    # @param event_name [String] Event name
    # @param callback [Proc] Callback function
    # @return [Proc] Unsubscribe function
    def on(event_name, callback)
      @emitter.on(event_name, callback)
    end

    # Close the instance
    def close
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
        sticky: options[:sticky]
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
        @logger.error("isEnabled", { feature_key: feature_key, error: e })
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

        if evaluation[:variation_value]
          evaluation[:variation_value]
        elsif evaluation[:variation]
          evaluation[:variation][:value]
        else
          nil
        end
      rescue => e
        @logger.error("getVariation", { feature_key: feature_key, error: e })
        nil
      end
    end

    # Evaluate a variable
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation result
    def evaluate_variable(feature_key, variable_key, context = {}, options = {})
      Featurevisor::Evaluate.evaluate_with_modules(
        get_evaluation_dependencies(context, options).merge(
          type: "variable",
          feature_key: feature_key,
          variable_key: variable_key
        )
      )
    end

    # Get variable value
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] Variable value or nil
    def get_variable(feature_key, variable_key, context = {}, options = {})
      begin
        evaluation = evaluate_variable(feature_key, variable_key, context, options)

        if !evaluation[:variable_value].nil?
          if evaluation[:variable_schema] &&
             evaluation[:variable_schema][:type] == "json" &&
             evaluation[:variable_value].is_a?(String)
            JSON.parse(evaluation[:variable_value], symbolize_names: true)
          else
            evaluation[:variable_value]
          end
        else
          nil
        end
      rescue => e
        @logger.error("getVariable", { feature_key: feature_key, variable_key: variable_key, error: e })
        nil
      end
    end

    # Get variable as boolean
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Boolean, nil] Boolean value or nil
    def get_variable_boolean(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "boolean")
    end

    # Get variable as string
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [String, nil] String value or nil
    def get_variable_string(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "string")
    end

    # Get variable as integer
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Integer, nil] Integer value or nil
    def get_variable_integer(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "integer")
    end

    # Get variable as double
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Float, nil] Float value or nil
    def get_variable_double(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "double")
    end

    # Get variable as array
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Array, nil] Array value or nil
    def get_variable_array(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "array")
    end

    # Get variable as object
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash, nil] Object value or nil
    def get_variable_object(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "object")
    end

    # Get variable as JSON
    # @param feature_key [String] Feature key
    # @param variable_key [String] Variable key
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Object, nil] JSON value or nil
    def get_variable_json(feature_key, variable_key, context = {}, options = {})
      variable_value = get_variable(feature_key, variable_key, context, options)
      get_value_by_type(variable_value, "json")
    end

    # Get all evaluations
    # @param context [Hash] Context
    # @param feature_keys [Array<String>] Feature keys to evaluate
    # @param options [Hash] Override options
    # @return [Hash] All evaluations
    def get_all_evaluations(context = {}, feature_keys = [], options = {})
      result = {}

              keys = feature_keys.size > 0 ? feature_keys : @datafile_reader.get_feature_keys

      keys.each do |feature_key|
        # Convert symbol keys to strings for evaluation functions
        feature_key_str = feature_key.to_s

        # isEnabled
        evaluated_feature = {
          enabled: is_enabled(feature_key_str, context, options)
        }

        # variation
        if @datafile_reader.has_variations?(feature_key_str)
          variation = get_variation(feature_key_str, context, options)
          evaluated_feature[:variation] = variation if variation
        end

        # variables
        variable_keys = @datafile_reader.get_variable_keys(feature_key_str)
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

    private

    # Get evaluation dependencies
    # @param context [Hash] Context
    # @param options [Hash] Override options
    # @return [Hash] Evaluation dependencies
    def get_evaluation_dependencies(context, options = {})
      {
        context: get_context(context),
        logger: @logger,
        modules_manager: @modules_manager,
        datafile_reader: @datafile_reader,
        sticky: options[:__featurevisor_child_sticky] || @sticky,
        default_variation_value: options[:default_variation_value],
        default_variable_value: options[:default_variable_value]
      }
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
        value.is_a?(String) ? Integer(value, 10) : (value.is_a?(Integer) ? value : nil)
      when "double"
        value.is_a?(String) ? Float(value) : (value.is_a?(Numeric) ? value.to_f : nil)
      when "boolean"
        value == true
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
      diagnostic[:module] ||= source_module.name if source_module && source_module.name
      details = (diagnostic[:details] || {}).dup
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

        subscription[:handler].call(diagnostic)
      end

      if @on_diagnostic
        @on_diagnostic.call(diagnostic) if should_report_diagnostic?(diagnostic[:level], @logger.level)
      else
        @logger.log(diagnostic[:level], diagnostic[:message], diagnostic)
      end

      if %w[error fatal].include?(diagnostic[:level])
        @emitter.trigger("error", diagnostic)
      end
    end

    def should_report_diagnostic?(diagnostic_level, subscriber_level)
      levels = Featurevisor::LOG_LEVELS
      diagnostic_index = levels.index(diagnostic_level || "info")
      subscriber_index = levels.index(subscriber_level || "info")

      return false if diagnostic_index.nil? || subscriber_index.nil?

      subscriber_index >= diagnostic_index
    end
  end

  # Create a new Featurevisor instance
  # @param options [Hash] Instance options
  # @return [Instance] New instance
  def self.create_instance(options = {})
    Instance.new(options)
  end
end
