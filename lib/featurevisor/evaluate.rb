# frozen_string_literal: true

module Featurevisor
  # Evaluation reason constants
  module EvaluationReason
    # Feature specific
    FEATURE_NOT_FOUND = "feature_not_found" # feature is not found in datafile
    DISABLED = "disabled" # feature is disabled
    REQUIRED = "required" # required features are not enabled
    OUT_OF_RANGE = "out_of_range" # out of range when mutually exclusive experiments are involved via Groups

    # Variations specific
    NO_VARIATIONS = "no_variations" # feature has no variations
    VARIATION_DISABLED = "variation_disabled" # feature is disabled, and variation's disabledVariationValue is used

    # Variable specific
    VARIABLE_NOT_FOUND = "variable_not_found" # variable's schema is not defined in the feature
    VARIABLE_DEFAULT = "variable_default" # default variable value used
    VARIABLE_DISABLED = "variable_disabled" # feature is disabled, and variable's disabledValue is used
    VARIABLE_OVERRIDE_VARIATION = "variable_override_variation" # variable overridden from inside a variation
    VARIABLE_OVERRIDE_RULE = "variable_override_rule" # variable overridden from inside a rule
    REQUIRED_FEATURES_UNMET = "required_features_unmet"

    # Common
    NO_MATCH = "no_match" # no rules matched
    FORCED = "forced" # against a forced rule
    STICKY = "sticky" # against a sticky feature
    RULE = "rule" # against a regular rule
    ALLOCATED = "allocated" # regular allocation based on bucketing

    ERROR = "error" # error
  end

  # Evaluation types
  EVALUATION_TYPES = %w[flag variation variable].freeze

  # Evaluation module for feature flag evaluation
  module Evaluate
    def self.required_features_are_matched(requirements, datafile, options)
      return true if requirements.nil?

      items = requirements.is_a?(Array) ? requirements : [requirements]
      clean_options = options.reject do |key, _|
        %i[feature_key variable_key default_variation_value default_variable_value].include?(key)
      end
      items.all? do |required|
        if required.is_a?(String)
          key = required
          enabled = true
          variation = nil
        elsif required.key?(:feature)
          key = required[:feature]
          enabled = required.key?(:enabled) ? required[:enabled] : true
          variation = required[:variation]
        else
          key = required[:key]
          enabled = true
          variation = required[:variation]
        end

        flag = evaluate_with_modules(clean_options.merge(type: "flag", feature_key: key, datafile: datafile))
        next false unless (flag[:enabled] == true) == enabled
        next true if variation.nil?

        evaluated_variation = evaluate_with_modules(clean_options.merge(type: "variation", feature_key: key, datafile: datafile))
        value = evaluated_variation.key?(:variation_value) ? evaluated_variation[:variation_value] : evaluated_variation.dig(:variation, :value)
        value == variation
      end
    end

    def self.variable_override_matches?(override, datafile, context, options)
      return false unless required_features_are_matched(override[:requiredFeatures], datafile, options)

      conditions_match = !override[:conditions] || datafile.all_conditions_are_matched(
        datafile.parse_conditions_if_stringified(override[:conditions]), context
      )
      segments_match = !override[:segments] || datafile.all_segments_are_matched(
        datafile.parse_segments_if_stringified(override[:segments]), context
      )
      conditions_match && segments_match &&
        (override.key?(:conditions) || override.key?(:segments) || override.key?(:requiredFeatures))
    end

    # Evaluate with modules
    # @param options [Hash] Evaluation options
    # @return [Hash] Evaluation result
    def self.evaluate_with_modules(options)
      begin
        modules_manager = options[:modules_manager]

        # Run before modules
        result_options = options
        if modules_manager
          result_options = modules_manager.run_before_modules(result_options)
        end

        # Evaluate
        evaluation = evaluate(result_options)

        # Default: variation
        if result_options.key?(:default_variation_value) &&
           evaluation[:type] == "variation" &&
           !evaluation.key?(:variation_value) &&
           !evaluation.key?(:variation)
          evaluation[:variation_value] = result_options[:default_variation_value]
        end

        # Default: variable
        if result_options.key?(:default_variable_value) &&
           evaluation[:type] == "variable" &&
           !evaluation.key?(:variable_value)
          evaluation[:variable_value] = result_options[:default_variable_value]
        end

        # Run after modules
        if modules_manager
          evaluation = modules_manager.run_after_modules(evaluation, result_options)
        end

        evaluation
      rescue => e
        type = options[:type]
        feature_key = options[:feature_key]
        variable_key = options[:variable_key]
        diagnostics = options[:diagnostics]

        evaluation = {
          type: type,
          feature_key: feature_key,
          variable_key: variable_key,
          reason: Featurevisor::EvaluationReason::ERROR,
          error: e
        }

        diagnostics.error("Error during evaluation", evaluation)

        evaluation
      end
    end

    # Main evaluation function
    # @param options [Hash] Evaluation options
    # @return [Hash] Evaluation result
    def self.evaluate(options)
      type = options[:type]
      feature_key = options[:feature_key]
      variable_key = options[:variable_key]
      context = options[:context]
      diagnostics = options[:diagnostics]
      datafile = options[:datafile]
      sticky = options[:sticky]
      modules_manager = options[:modules_manager]
      evaluation = nil

      begin
        # Root flag evaluation
        flag = nil
        if type != "flag"
          # needed by variation and variable evaluations
          flag = evaluate(options.merge(type: "flag"))

          if flag[:enabled] == false
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::DISABLED
            }

            feature = datafile.get_feature(feature_key)

            # serve variable default value if feature is disabled (if explicitly specified)
            if type == "variable"
              if feature && variable_key &&
                 feature[:variablesSchema] &&
                 has_key?(feature[:variablesSchema], variable_key)
                variable_schema = fetch_with_symbol_key(feature[:variablesSchema], variable_key)

                if variable_schema.key?(:disabledValue)
                  # disabledValue: <value>
                  evaluation = {
                    type: type,
                    feature_key: feature_key,
                    reason: Featurevisor::EvaluationReason::VARIABLE_DISABLED,
                    variable_key: variable_key,
                    variable_value: variable_schema[:disabledValue],
                    variable_schema: variable_schema,
                    enabled: false
                  }
                elsif variable_schema[:useDefaultWhenDisabled]
                  # useDefaultWhenDisabled: true
                  evaluation = {
                    type: type,
                    feature_key: feature_key,
                    reason: Featurevisor::EvaluationReason::VARIABLE_DEFAULT,
                    variable_key: variable_key,
                    variable_value: variable_schema[:defaultValue],
                    variable_schema: variable_schema,
                    enabled: false
                  }
                end
              end
            end

            # serve disabled variation value if feature is disabled (if explicitly specified)
            if type == "variation" && feature && feature.key?(:disabledVariationValue)
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::VARIATION_DISABLED,
                variation_value: feature[:disabledVariationValue],
                enabled: false
              }
            end

            diagnostics.debug("feature is disabled", evaluation)

            return evaluation
          end
        end

        # Sticky
        if sticky && has_key?(sticky, feature_key)
          sticky_feature = fetch_with_symbol_key(sticky, feature_key)

          # flag
          if type == "flag" && sticky_feature.key?(:enabled)
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::STICKY,
              sticky: sticky_feature,
              enabled: sticky_feature[:enabled]
            }

            diagnostics.debug("using sticky enabled", evaluation)

            return evaluation
          end

          # variation
          if type == "variation"
            variation_value = sticky_feature[:variation]

            if sticky_feature.key?(:variation)
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::STICKY,
                variation_value: variation_value
              }

              diagnostics.debug("using sticky variation", evaluation)

              return evaluation
            end
          end

          # variable
          if type == "variable" && variable_key
            variables = sticky_feature[:variables]

            if variables && has_key?(variables, variable_key)
              variable_value = fetch_with_symbol_key(variables, variable_key)
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::STICKY,
                variable_key: variable_key,
                variable_value: variable_value
              }

              diagnostics.debug("using sticky variable", evaluation)

              return evaluation
            end
          end
        end

        # Feature
        feature = feature_key.is_a?(String) ? datafile.get_feature(feature_key) : feature_key

        # feature: not found
        unless feature
          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::FEATURE_NOT_FOUND
          }

          diagnostics.warn("feature not found", evaluation)

          return evaluation
        end

        # feature: deprecated
        if type == "flag" && feature[:deprecated]
          diagnostics.warn("feature is deprecated", { feature_key: feature_key })
        end

        # variableSchema
        variable_schema = nil

        if variable_key
          if feature[:variablesSchema] && has_key?(feature[:variablesSchema], variable_key)
            variable_schema = fetch_with_symbol_key(feature[:variablesSchema], variable_key)
          end

          # variable schema not found
          unless variable_schema
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND,
              variable_key: variable_key
            }

            diagnostics.warn("variable schema not found", evaluation)

            return evaluation
          end

          if variable_schema[:deprecated]
            diagnostics.warn("variable is deprecated", {
              feature_key: feature_key,
              variable_key: variable_key
            })
          end
        end

        # variation: no variations
        if type == "variation" && (!feature[:variations] || feature[:variations].empty?)
          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::NO_VARIATIONS
          }

          diagnostics.warn("no variations", evaluation)

          return evaluation
        end

        # Forced
        force_result = datafile.get_matched_force(feature, context)
        force = force_result[:force]
        force_index = force_result[:forceIndex]

        if force
          # flag
          if type == "flag" && force.key?(:enabled)
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::FORCED,
              force_index: force_index,
              force: force,
              enabled: force[:enabled]
            }

            diagnostics.debug("forced enabled found", evaluation)

            return evaluation
          end

          # variation
          if type == "variation" && force[:variation] && feature[:variations]
            variation = feature[:variations].find { |v| v[:value] == force[:variation] }

            if variation
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::FORCED,
                force_index: force_index,
                force: force,
                variation: variation
              }

              diagnostics.debug("forced variation found", evaluation)

              return evaluation
            end
          end

          # variable
          if variable_key && force[:variables] && has_key?(force[:variables], variable_key)
            variable_value = fetch_with_symbol_key(force[:variables], variable_key)
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::FORCED,
              force_index: force_index,
              force: force,
              variable_key: variable_key,
              variable_schema: variable_schema,
              variable_value: variable_value
            }

            diagnostics.debug("forced variable", evaluation)

            return evaluation
          end
        end

        # Required
        required_features = feature[:requiredFeatures] || feature[:required]
        if type == "flag" && required_features && !Array(required_features).empty?
          required_features_are_enabled = required_features_are_matched(required_features, datafile, options)

          unless required_features_are_enabled
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::REQUIRED,
              required: feature[:required],
              required_features: feature[:requiredFeatures],
              enabled: required_features_are_enabled
            }

            diagnostics.debug("required features not enabled", evaluation)

            return evaluation
          end
        end

        # Bucketing
        # bucketKey
        bucket_key = Featurevisor::Bucketer.get_bucket_key({
          feature_key: feature_key,
          bucket_by: feature[:bucketBy],
          context: context,
          diagnostics: diagnostics
        })

        # Run bucket key modules
        bucket_key = modules_manager.run_bucket_key_modules({
          feature_key: feature_key,
          context: context,
          bucket_by: feature[:bucketBy],
          bucket_key: bucket_key
        }) if modules_manager

        # bucketValue
        bucket_value = Featurevisor::Bucketer.get_bucketed_number(bucket_key)

        # Run bucket value modules
        bucket_value = modules_manager.run_bucket_value_modules({
          feature_key: feature_key,
          bucket_key: bucket_key,
          context: context,
          bucket_value: bucket_value
        }) if modules_manager

        matched_traffic = nil
        matched_allocation = nil

        if type != "flag"
          matched_traffic = datafile.get_matched_traffic(feature[:traffic], context)

          if matched_traffic
            matched_allocation = datafile.get_matched_allocation(matched_traffic, bucket_value)
          end
        else
          matched_traffic = datafile.get_matched_traffic(feature[:traffic], context)
        end

        if matched_traffic
          # percentage: 0
          if matched_traffic[:percentage] == 0
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::RULE,
              bucket_key: bucket_key,
              bucket_value: bucket_value,
              rule_key: matched_traffic[:key],
              traffic: matched_traffic,
              enabled: false
            }

            diagnostics.debug("matched rule with 0 percentage", evaluation)

            return evaluation
          end

          # flag
          if type == "flag"
            # flag: check if mutually exclusive
            if feature[:ranges] && feature[:ranges].length > 0
              matched_range = feature[:ranges].find do |range|
                bucket_value >= range[0] && bucket_value < range[1]
              end

              # matched
              if matched_range
                evaluation = {
                  type: type,
                  feature_key: feature_key,
                  reason: Featurevisor::EvaluationReason::ALLOCATED,
                  bucket_key: bucket_key,
                  bucket_value: bucket_value,
                  rule_key: matched_traffic[:key],
                  traffic: matched_traffic,
                  enabled: matched_traffic[:enabled].nil? ? true : matched_traffic[:enabled]
                }

                diagnostics.debug("matched", evaluation)

                return evaluation
              end

              # no match
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::OUT_OF_RANGE,
                bucket_key: bucket_key,
                bucket_value: bucket_value,
                enabled: false
              }

              diagnostics.debug("not matched", evaluation)

              return evaluation
            end

            # flag: override from rule
            if matched_traffic.key?(:enabled)
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::RULE,
                bucket_key: bucket_key,
                bucket_value: bucket_value,
                rule_key: matched_traffic[:key],
                traffic: matched_traffic,
                enabled: matched_traffic[:enabled]
              }

              diagnostics.debug("override from rule", evaluation)

              return evaluation
            end

            # treated as enabled because of matched traffic
            if bucket_value <= matched_traffic[:percentage]
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::RULE,
                bucket_key: bucket_key,
                bucket_value: bucket_value,
                rule_key: matched_traffic[:key],
                traffic: matched_traffic,
                enabled: true
              }

              diagnostics.debug("matched traffic", evaluation)

              return evaluation
            end
          end

          # variation
          if type == "variation" && feature[:variations]
            # override from rule
            if matched_traffic[:variation]
              variation = feature[:variations].find { |v| v[:value] == matched_traffic[:variation] }

              if variation
                evaluation = {
                  type: type,
                  feature_key: feature_key,
                  reason: Featurevisor::EvaluationReason::RULE,
                  bucket_key: bucket_key,
                  bucket_value: bucket_value,
                  rule_key: matched_traffic[:key],
                  traffic: matched_traffic,
                  variation: variation
                }

                diagnostics.debug("override from rule", evaluation)

                return evaluation
              end
            end

            # regular allocation
            if matched_allocation && matched_allocation[:variation]
              variation = feature[:variations].find { |v| v[:value] == matched_allocation[:variation] }

              if variation
                evaluation = {
                  type: type,
                  feature_key: feature_key,
                  reason: Featurevisor::EvaluationReason::ALLOCATED,
                  bucket_key: bucket_key,
                  bucket_value: bucket_value,
                  rule_key: matched_traffic[:key],
                  traffic: matched_traffic,
                  variation: variation
                }

                diagnostics.debug("allocated variation", evaluation)

                return evaluation
              end
            end
          end
        end

        # variable
        if type == "variable" && variable_key
          # override from rule
          if matched_traffic &&
             matched_traffic[:variableOverrides] &&
             has_key?(matched_traffic[:variableOverrides], variable_key)
            overrides = fetch_with_symbol_key(matched_traffic[:variableOverrides], variable_key)

            override_index = overrides.find_index { |o| variable_override_matches?(o, datafile, context, options) }

            unless override_index.nil?
              override = overrides[override_index]

              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::VARIABLE_OVERRIDE_RULE,
                bucket_key: bucket_key,
                bucket_value: bucket_value,
                rule_key: matched_traffic[:key],
                traffic: matched_traffic,
                variable_key: variable_key,
                variable_schema: variable_schema,
                variable_value: override[:value],
                variable_override_index: override_index,
                variable_override_key: override[:key]
              }

              diagnostics.debug("variable override from rule", evaluation)

              return evaluation
            end
          end

          if matched_traffic &&
             matched_traffic[:variables] &&
             has_key?(matched_traffic[:variables], variable_key)
            variable_value = fetch_with_symbol_key(matched_traffic[:variables], variable_key)
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::RULE,
              bucket_key: bucket_key,
              bucket_value: bucket_value,
              rule_key: matched_traffic[:key],
              traffic: matched_traffic,
              variable_key: variable_key,
              variable_schema: variable_schema,
              variable_value: variable_value
            }

            diagnostics.debug("override from rule", evaluation)

            return evaluation
          end

          # check variations
          variation_value = nil

          if force && force[:variation]
            variation_value = force[:variation]
          elsif matched_traffic && matched_traffic[:variation]
            variation_value = matched_traffic[:variation]
          elsif matched_allocation && matched_allocation[:variation]
            variation_value = matched_allocation[:variation]
          end

          if variation_value && feature[:variations].is_a?(Array)
            variation = feature[:variations].find { |v| v[:value] == variation_value }

            if variation && variation[:variableOverrides] && has_key?(variation[:variableOverrides], variable_key)
              overrides = fetch_with_symbol_key(variation[:variableOverrides], variable_key)

              override_index = overrides.find_index { |o| variable_override_matches?(o, datafile, context, options) }

              unless override_index.nil?
                override = overrides[override_index]
                evaluation = {
                  type: type,
                  feature_key: feature_key,
                  reason: Featurevisor::EvaluationReason::VARIABLE_OVERRIDE_VARIATION,
                  bucket_key: bucket_key,
                  bucket_value: bucket_value,
                  rule_key: matched_traffic&.[](:key),
                  traffic: matched_traffic,
                  variable_key: variable_key,
                  variable_schema: variable_schema,
                  variable_value: override[:value],
                  variable_override_index: override_index,
                  variable_override_key: override[:key]
                }

                diagnostics.debug("variable override from variation", evaluation)

                return evaluation
              end
            end

            if variation &&
               variation[:variables] &&
               has_key?(variation[:variables], variable_key)
              variable_value = fetch_with_symbol_key(variation[:variables], variable_key)
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::ALLOCATED,
                bucket_key: bucket_key,
                bucket_value: bucket_value,
                rule_key: matched_traffic&.[](:key),
                traffic: matched_traffic,
                variable_key: variable_key,
                variable_schema: variable_schema,
                variable_value: variable_value
              }

              diagnostics.debug("allocated variable", evaluation)

              return evaluation
            end
          end
        end

        # Nothing matched
        if type == "variation"
          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::NO_MATCH,
            bucket_key: bucket_key,
            bucket_value: bucket_value
          }

          diagnostics.debug("no matched variation", evaluation)

          return evaluation
        end

        if type == "variable"
          if variable_schema
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::VARIABLE_DEFAULT,
              bucket_key: bucket_key,
              bucket_value: bucket_value,
              variable_key: variable_key,
              variable_schema: variable_schema,
              variable_value: variable_schema[:defaultValue]
            }

            diagnostics.debug("using default value", evaluation)

            return evaluation
          end

          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND,
            variable_key: variable_key,
            bucket_key: bucket_key,
            bucket_value: bucket_value
          }

          diagnostics.debug("variable not found", evaluation)

          return evaluation
        end

        evaluation = {
          type: type,
          feature_key: feature_key,
          reason: Featurevisor::EvaluationReason::NO_MATCH,
          bucket_key: bucket_key,
          bucket_value: bucket_value,
          enabled: false
        }

        diagnostics.debug("nothing matched", evaluation)

        evaluation
      rescue => e
        evaluation = {
          type: type,
          feature_key: feature_key,
          variable_key: variable_key,
          reason: Featurevisor::EvaluationReason::ERROR,
          error: e
        }

        diagnostics.error("Error during evaluation", evaluation)

        evaluation
      end
    end

    def self.fetch_with_symbol_key(obj, key)
      return obj[key] if obj.is_a?(Hash) && obj.key?(key)

      symbol_key = key.to_sym
      return obj[symbol_key] if obj.is_a?(Hash) && obj.key?(symbol_key)

      nil
    end

    def self.has_key?(obj, key)
      return false unless obj.is_a?(Hash)

      obj.key?(key) || obj.key?(key.to_sym)
    end
  end
end
