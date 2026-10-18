# frozen_string_literal: true

module Featurevisor
  # Evaluation reason constants
  module EvaluationReason
    # Feature specific
    FEATURE_NOT_FOUND = "feature_not_found" # feature is not found in datafile
    DISABLED = "disabled" # feature is disabled

    # Variations specific
    NO_VARIATIONS = "no_variations" # feature has no variations
    VARIATION_DISABLED = "variation_disabled" # feature is disabled, and variation's disabledVariationValue is used

    # Variable specific
    VARIABLE_NOT_FOUND = "variable_not_found" # variable's schema is not defined in the feature
    VARIABLE_DEFAULT = "variable_default" # default variable value used
    VARIABLE_DISABLED = "variable_disabled" # feature is disabled, and variable's disabledValue is used
    VARIABLE_OVERRIDE_VARIATION = "variable_override_variation" # variable overridden from inside a variation
    VARIABLE_OVERRIDE_RULE = "variable_override_rule" # variable overridden from inside a rule
    CONDITIONS_UNMET = "conditions_unmet"
    VARIABLE_COMPOSED = "variable_composed"

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
    def self.variable_override_matches?(override, datafile, context, options)
      override.key?(:conditions) && UnifiedConditions.matches?(override[:conditions], options)
    end

    # Evaluate with modules
    # @param options [Hash] Evaluation options
    # @return [Hash] Evaluation result
    def self.evaluate_with_modules(options)
      begin
        session = options[:__featurevisor_session] || EvaluationSession.new
        options = options.merge(__featurevisor_session: session)
        if options[:__featurevisor_prerequisite]
          options[:sticky] = options[:__featurevisor_sticky_features_source].call if options[:__featurevisor_sticky_features_source]
          options[:sticky_variables] = options[:__featurevisor_sticky_variables_source].call if options[:__featurevisor_sticky_variables_source]
          options[:datafile] = options[:__featurevisor_datafile_source].call if options[:__featurevisor_datafile_source]
        end
        options[:dependency_of] = session.dependency_of if options[:__featurevisor_prerequisite]
        options[:dependency_purpose] ||= "condition" if options[:__featurevisor_prerequisite]
        return session.run(options, prerequisite: options[:__featurevisor_prerequisite]) do
        modules_manager = options[:modules_manager]
        # The usual read has no modules. Keep its evaluation options intact so
        # it does not allocate two filtered hashes and a merged hash.
        result_options = options
        if modules_manager && !modules_manager.get_all.empty?
          private_options = options.select { |key, _| private_evaluation_option?(key) }
          public_options = options.reject { |key, _| private_evaluation_option?(key) }
          result_options = modules_manager.run_before_evaluation_modules(public_options)
          result_options = result_options.reject { |key, _| private_evaluation_option?(key) }.merge(private_options)
        end
        { sticky: :__featurevisor_sticky_features_source,
          sticky_variables: :__featurevisor_sticky_variables_source }.each do |field, source|
          if result_options[field].equal?(options[field])
            result_options[field] = options[source].call if options[source]
          else
            replacement = result_options[field]
            result_options[source] = -> { replacement }
          end
        end
        session.update_current(result_options)

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
        # A callback during evaluation may add a module. In that case its
        # after hook still receives only public options.
        if modules_manager && !modules_manager.get_all.empty?
          evaluation = modules_manager.run_after_evaluation_modules(
            evaluation, result_options.reject { |key, _| private_evaluation_option?(key) }
          )
        end

        evaluation
        end
      rescue => e
        raise if e.is_a?(RequirementError) && options[:__featurevisor_prerequisite]
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

        session.remember(options, evaluation) if session

        diagnostics.error("Error during evaluation", evaluation)

        evaluation
      end
    end

    def self.private_evaluation_option?(key)
      key.to_s.start_with?("__featurevisor_")
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
              sticky_feature: sticky_feature,
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
        force_result = datafile.get_matched_force(feature, context, options)
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

        if type == "flag" && feature.key?(:conditions) &&
           !UnifiedConditions.matches?(feature[:conditions], options)
          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::CONDITIONS_UNMET,
            conditions: feature[:conditions],
            enabled: false
          }
          diagnostics.debug("conditions did not match", evaluation)
          return evaluation
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
          matched_traffic = datafile.get_matched_traffic(feature[:traffic], context, options)

          if matched_traffic
            matched_allocation = datafile.get_matched_allocation(matched_traffic, bucket_value)
          end
        else
          matched_traffic = datafile.get_matched_traffic(feature[:traffic], context, options)
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
                variable_override_key: override[:key],
                variable_override_path: override[:keyPath]
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
                  variable_override_key: override[:key],
                  variable_override_path: override[:keyPath]
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
        raise if e.is_a?(RequirementError)
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
