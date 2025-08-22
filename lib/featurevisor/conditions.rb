# frozen_string_literal: true

require "date"

module Featurevisor
  # Conditions module for evaluating feature flags and segments
  module Conditions
    # Get value from context object using dot notation path
    # @param obj [Hash] Context object
    # @param path [String] Dot-separated path to the value
    # @return [Object, nil] Value at the path or nil if not found
    def self.get_value_from_context(obj, path)
      return nil if obj.nil? || path.nil?

      if path.index(".") == -1
        return obj[path.to_sym] || obj[path]
      end

      path.split(".").reduce(obj) { |o, i| o&.[](i.to_sym) || o&.[](i) }
    end

    # Check if a condition is matched against context
    # @param condition [Hash] Condition to evaluate
    # @param context [Hash] Context to evaluate against
    # @param get_regex [Proc] Function to get regex for pattern matching
    # @return [Boolean] True if condition matches
    def self.condition_is_matched(condition, context, get_regex)
      attribute = condition["attribute"] || condition[:attribute]
      operator = condition["operator"] || condition[:operator]
      value = condition["value"] || condition[:value]
      regex_flags = condition["regexFlags"] || condition[:regexFlags]

      context_value_from_path = get_value_from_context(context, attribute)

      case operator
      when "equals"
        context_value_from_path == value
      when "notEquals"
        context_value_from_path != value
      when "before", "after"
        # date comparisons
        value_in_context = context_value_from_path
        date_in_context = value_in_context.is_a?(Date) ? value_in_context : Date.parse(value_in_context.to_s)
        date_in_condition = value.is_a?(Date) ? value : Date.parse(value.to_s)

        if operator == "before"
          date_in_context < date_in_condition
        else
          date_in_context > date_in_condition
        end
      when "in", "notIn"
        # in / notIn (where condition value is an array)
        if value.is_a?(Array) && (context_value_from_path.is_a?(String) || context_value_from_path.is_a?(Numeric) || context_value_from_path.nil?)
          # Check if the attribute key actually exists in the context
          key_exists = context.key?(attribute.to_sym) || context.key?(attribute.to_s)

          # If key doesn't exist, notIn should fail (return false), in should also fail
          if !key_exists
            return false
          end

          value_in_context = context_value_from_path.to_s

          if operator == "in"
            value.include?(value_in_context)
          else # notIn
            !value.include?(value_in_context)
          end
        else
          false
        end
      when "contains", "notContains", "startsWith", "endsWith", "semverEquals", "semverNotEquals", "semverGreaterThan", "semverGreaterThanOrEquals", "semverLessThan", "semverLessThanOrEquals", "matches", "notMatches"
        # string operations
        if context_value_from_path.is_a?(String) && value.is_a?(String)
          value_in_context = context_value_from_path

          case operator
          when "contains"
            value_in_context.include?(value)
          when "notContains"
            !value_in_context.include?(value)
          when "startsWith"
            value_in_context.start_with?(value)
          when "endsWith"
            value_in_context.end_with?(value)
          when "semverEquals"
            Featurevisor.compare_versions(value_in_context, value) == 0
          when "semverNotEquals"
            Featurevisor.compare_versions(value_in_context, value) != 0
          when "semverGreaterThan"
            Featurevisor.compare_versions(value_in_context, value) == 1
          when "semverGreaterThanOrEquals"
            Featurevisor.compare_versions(value_in_context, value) >= 0
          when "semverLessThan"
            Featurevisor.compare_versions(value_in_context, value) == -1
          when "semverLessThanOrEquals"
            Featurevisor.compare_versions(value_in_context, value) <= 0
          when "matches"
            regex = get_regex.call(value, regex_flags || "")
            regex.match?(value_in_context)
          when "notMatches"
            regex = get_regex.call(value, regex_flags || "")
            !regex.match?(value_in_context)
          end
        else
          false
        end
      when "greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals"
        # numeric operations
        if context_value_from_path.is_a?(Numeric) && value.is_a?(Numeric)
          value_in_context = context_value_from_path

          case operator
          when "greaterThan"
            value_in_context > value
          when "greaterThanOrEquals"
            value_in_context >= value
          when "lessThan"
            value_in_context < value
          when "lessThanOrEquals"
            value_in_context <= value
          end
        else
          false
        end
      when "exists"
        context_value_from_path != nil
      when "notExists"
        context_value_from_path.nil?
      when "includes", "notIncludes"
        # includes / notIncludes (where context value is an array)
        if context_value_from_path.is_a?(Array) && value.is_a?(String)
          value_in_context = context_value_from_path

          if operator == "includes"
            value_in_context.include?(value)
          else # notIncludes
            !value_in_context.include?(value)
          end
        else
          false
        end
      else
        false
      end
    rescue => e
      # Log error but don't stop execution
      warn "Error in condition evaluation: #{e.message}"
      false
    end
  end
end
