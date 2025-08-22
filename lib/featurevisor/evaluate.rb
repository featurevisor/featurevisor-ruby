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
    VARIABLE_OVERRIDE = "variable_override" # variable overridden from inside a variation

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

    # Evaluate with hooks
    # @param options [Hash] Evaluation options
    # @return [Hash] Evaluation result
    def self.evaluate_with_hooks(options)
      begin
        hooks_manager = options[:hooks_manager]
        hooks = hooks_manager.get_all

        # Run before hooks
        result_options = options
        hooks.each do |hook|
          if hook.respond_to?(:call_before)
            result_options = hook.call_before(result_options)
          end
        end

        # Evaluate
        evaluation = evaluate(result_options)

        # Default: variation
        if options[:default_variation_value] &&
           evaluation[:type] == "variation" &&
           evaluation[:variation_value].nil?
          evaluation[:variation_value] = options[:default_variation_value]
        end

        # Default: variable
        if options[:default_variable_value] &&
           evaluation[:type] == "variable" &&
           evaluation[:variable_value].nil?
          evaluation[:variable_value] = options[:default_variable_value]
        end

        # Run after hooks
        hooks.each do |hook|
          if hook.respond_to?(:call_after)
            evaluation = hook.call_after(evaluation, result_options)
          end
        end

        evaluation
      rescue => e
        type = options[:type]
        feature_key = options[:feature_key]
        variable_key = options[:variable_key]
        logger = options[:logger]

        evaluation = {
          type: type,
          feature_key: feature_key,
          variable_key: variable_key,
          reason: Featurevisor::EvaluationReason::ERROR,
          error: e
        }

        logger.error("error during evaluation", evaluation)

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
      logger = options[:logger]
      datafile_reader = options[:datafile_reader]
      sticky = options[:sticky]
      hooks_manager = options[:hooks_manager]

      hooks = hooks_manager.get_all
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

            feature = datafile_reader.get_feature(feature_key)

            # serve variable default value if feature is disabled (if explicitly specified)
            if type == "variable"
              if feature && variable_key &&
                 feature[:variablesSchema] &&
                 (feature[:variablesSchema][variable_key] || feature[:variablesSchema][variable_key.to_sym])
                variable_schema = feature[:variablesSchema][variable_key] || feature[:variablesSchema][variable_key.to_sym]

                if variable_schema[:disabledValue]
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
            if type == "variation" && feature && feature[:disabledVariationValue]
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::VARIATION_DISABLED,
                variation_value: feature[:disabledVariationValue],
                enabled: false
              }
            end

            logger.debug("feature is disabled", evaluation)

            return evaluation
          end
        end

        # Sticky
        if sticky && (sticky[feature_key] || sticky[feature_key.to_sym])
          sticky_feature = sticky[feature_key] || sticky[feature_key.to_sym]

          # flag
          if type == "flag" && sticky_feature.key?(:enabled)
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::STICKY,
              sticky: sticky_feature,
              enabled: sticky_feature[:enabled]
            }

            logger.debug("using sticky enabled", evaluation)

            return evaluation
          end

          # variation
          if type == "variation"
            variation_value = sticky_feature[:variation]

            if variation_value
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::STICKY,
                variation_value: variation_value
              }

              logger.debug("using sticky variation", evaluation)

              return evaluation
            end
          end

          # variable
          if type == "variable" && variable_key
            variables = sticky_feature[:variables]

            if variables && (variables[variable_key] || variables[variable_key.to_sym])
              variable_value = variables[variable_key] || variables[variable_key.to_sym]
              evaluation = {
                type: type,
                feature_key: feature_key,
                reason: Featurevisor::EvaluationReason::STICKY,
                variable_key: variable_key,
                variable_value: variable_value
              }

              logger.debug("using sticky variable", evaluation)

              return evaluation
            end
          end
        end

        # Feature
        feature = feature_key.is_a?(String) ? datafile_reader.get_feature(feature_key) : feature_key

        # feature: not found
        unless feature
          evaluation = {
            type: type,
            feature_key: feature_key,
            reason: Featurevisor::EvaluationReason::FEATURE_NOT_FOUND
          }

          logger.warn("feature not found", evaluation)

          return evaluation
        end

        # feature: deprecated
        if type == "flag" && feature[:deprecated]
          logger.warn("feature is deprecated", { feature_key: feature_key })
        end

        # variableSchema
        variable_schema = nil

        if variable_key
          if feature[:variablesSchema] && (feature[:variablesSchema][variable_key] || feature[:variablesSchema][variable_key.to_sym])
            variable_schema = feature[:variablesSchema][variable_key] || feature[:variablesSchema][variable_key.to_sym]
          end

          # variable schema not found
          unless variable_schema
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND,
              variable_key: variable_key
            }

            logger.warn("variable schema not found", evaluation)

            return evaluation
          end

          if variable_schema[:deprecated]
            logger.warn("variable is deprecated", {
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

          logger.warn("no variations", evaluation)

          return evaluation
        end

        # Forced
        force_result = datafile_reader.get_matched_force(feature, context)
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

            logger.debug("forced enabled found", evaluation)

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

              logger.debug("forced variation found", evaluation)

              return evaluation
            end
          end

          # variable
          if variable_key && force[:variables] && (force[:variables][variable_key] || force[:variables][variable_key.to_sym])
            variable_value = force[:variables][variable_key] || force[:variables][variable_key.to_sym]
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

            logger.debug("forced variable", evaluation)

            return evaluation
          end
        end

        # Required
        if type == "flag" && feature[:required] && feature[:required].length > 0
          required_features_are_enabled = feature[:required].all? do |required|
            required_key = nil
            required_variation = nil

            if required.is_a?(String)
              required_key = required
            else
              required_key = required[:key]
              required_variation = required[:variation]
            end

            required_evaluation = evaluate(options.merge(type: "flag", feature_key: required_key))
            required_is_enabled = required_evaluation[:enabled]

            next false unless required_is_enabled

            if required_variation
              required_variation_evaluation = evaluate(options.merge(type: "variation", feature_key: required_key))

              required_variation_value = nil

              if required_variation_evaluation[:variation_value]
                required_variation_value = required_variation_evaluation[:variation_value]
              elsif required_variation_evaluation[:variation]
                required_variation_value = required_variation_evaluation[:variation][:value]
              end

              next required_variation_value == required_variation
            end

            true
          end

          unless required_features_are_enabled
            evaluation = {
              type: type,
              feature_key: feature_key,
              reason: Featurevisor::EvaluationReason::REQUIRED,
              required: feature[:required],
              enabled: required_features_are_enabled
            }

            logger.debug("required features not enabled", evaluation)

            return evaluation
          end
        end

        # Bucketing
        # bucketKey
        bucket_key = Featurevisor::Bucketer.get_bucket_key({
          feature_key: feature_key,
          bucket_by: feature[:bucketBy],
          context: context,
          logger: logger
        })

        # Run bucket key hooks
        bucket_key = hooks_manager.run_bucket_key_hooks({
          feature_key: feature_key,
          context: context,
          bucket_by: feature[:bucketBy],
          bucket_key: bucket_key
        })

        # bucketValue
        bucket_value = Featurevisor::Bucketer.get_bucketed_number(bucket_key)

        # Run bucket value hooks
        bucket_value = hooks_manager.run_bucket_value_hooks({
          feature_key: feature_key,
          bucket_key: bucket_key,
          context: context,
          bucket_value: bucket_value
        })

        matched_traffic = nil
        matched_allocation = nil

        if type != "flag"
          matched_traffic = datafile_reader.get_matched_traffic(feature[:traffic], context)

          if matched_traffic
            matched_allocation = datafile_reader.get_matched_allocation(matched_traffic, bucket_value)
          end
        else
          matched_traffic = datafile_reader.get_matched_traffic(feature[:traffic], context)
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

            logger.debug("matched rule with 0 percentage", evaluation)

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

                logger.debug("matched", evaluation)

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

              logger.debug("not matched", evaluation)

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

              logger.debug("override from rule", evaluation)

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

              logger.debug("matched traffic", evaluation)

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

                logger.debug("override from rule", evaluation)

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

                logger.debug("allocated variation", evaluation)

                return evaluation
              end
            end
          end
        end

        # variable
        if type == "variable" && variable_key
          # override from rule
          if matched_traffic &&
             matched_traffic[:variables] &&
             (matched_traffic[:variables][variable_key] || matched_traffic[:variables][variable_key.to_sym])
            variable_value = matched_traffic[:variables][variable_key] || matched_traffic[:variables][variable_key.to_sym]
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

            logger.debug("override from rule", evaluation)

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

            if variation && variation[:variableOverrides] && (variation[:variableOverrides][variable_key] || variation[:variableOverrides][variable_key.to_sym])
              overrides = variation[:variableOverrides][variable_key] || variation[:variableOverrides][variable_key.to_sym]

              logger.debug("checking variableOverrides", {
                feature_key: feature_key,
                variable_key: variable_key,
                overrides: overrides,
                context: context
              })

              override = overrides.find do |o|
                logger.debug("evaluating override", {
                  feature_key: feature_key,
                  variable_key: variable_key,
                  override: o,
                  context: context
                })

                result = if o[:conditions]
                  matched = datafile_reader.all_conditions_are_matched(
                    o[:conditions].is_a?(String) && o[:conditions] != "*" ?
                      JSON.parse(o[:conditions]) : o[:conditions],
                    context
                  )
                  logger.debug("conditions match result", {
                    feature_key: feature_key,
                    variable_key: variable_key,
                    conditions: o[:conditions],
                    matched: matched
                  })
                  matched
                elsif o[:segments]
                  segments = datafile_reader.parse_segments_if_stringified(o[:segments])
                  matched = datafile_reader.all_segments_are_matched(segments, context)
                  logger.debug("segments match result", {
                    feature_key: feature_key,
                    variable_key: variable_key,
                    segments: o[:segments],
                    parsed_segments: segments,
                    matched: matched
                  })
                  matched
                else
                  logger.debug("override has no conditions or segments", {
                    feature_key: feature_key,
                    variable_key: variable_key,
                    override: o
                  })
                  false
                end

                logger.debug("override evaluation result", {
                  feature_key: feature_key,
                  variable_key: variable_key,
                  result: result
                })

                result
              end

              if override
                evaluation = {
                  type: type,
                  feature_key: feature_key,
                  reason: Featurevisor::EvaluationReason::VARIABLE_OVERRIDE,
                  bucket_key: bucket_key,
                  bucket_value: bucket_value,
                  rule_key: matched_traffic&.[](:key),
                  traffic: matched_traffic,
                  variable_key: variable_key,
                  variable_schema: variable_schema,
                  variable_value: override[:value]
                }

                logger.debug("variable override", evaluation)

                return evaluation
              end
            end

            if variation &&
               variation[:variables] &&
               (variation[:variables][variable_key] || variation[:variables][variable_key.to_sym])
              variable_value = variation[:variables][variable_key] || variation[:variables][variable_key.to_sym]
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

              logger.debug("allocated variable", evaluation)

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

          logger.debug("no matched variation", evaluation)

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

            logger.debug("using default value", evaluation)

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

          logger.debug("variable not found", evaluation)

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

        logger.debug("nothing matched", evaluation)

        evaluation
      rescue => e
        evaluation = {
          type: type,
          feature_key: feature_key,
          variable_key: variable_key,
          reason: Featurevisor::EvaluationReason::ERROR,
          error: e
        }

        logger.error("error", evaluation)

        evaluation
      end
    end
  end
end
