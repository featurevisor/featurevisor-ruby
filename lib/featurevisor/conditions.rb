# frozen_string_literal: true

require "date"
require "time"

module Featurevisor
  # Conditions module for evaluating feature flags and segments
  module Conditions
    MISSING = Object.new.freeze
    private_constant :MISSING

    # Get value from context object using dot notation path
    # @param obj [Hash] Context object
    # @param path [String] Dot-separated path to the value
    # @return [Object, nil] Value at the path or nil if not found
    def self.get_value_from_context(obj, path)
      return nil if obj.nil? || path.nil?

      value = get_value_with_presence(obj, path)
      value.equal?(MISSING) ? nil : value
    end

    def self.get_value_with_presence(obj, path)
      return MISSING unless obj.is_a?(Hash) && path.is_a?(String)

      path.split(".").reduce(obj) do |current, key|
        break MISSING unless current.is_a?(Hash)

        if current.key?(key.to_sym)
          current[key.to_sym]
        elsif current.key?(key)
          current[key]
        else
          break MISSING
        end
      end
    end
    private_class_method :get_value_with_presence

    def self.strict_equal?(left, right)
      return true if left.nil? && right.nil?
      return left.to_f == right.to_f if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left == right if left.is_a?(String) && right.is_a?(String)
      return left == right if (left == true || left == false) && (right == true || right == false)

      false
    end
    private_class_method :strict_equal?

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

      raw_context_value = get_value_with_presence(context, attribute)
      context_value_from_path = raw_context_value.equal?(MISSING) ? nil : raw_context_value
      attribute_exists = !raw_context_value.equal?(MISSING)

      case operator
      when "equals"
        attribute_exists && strict_equal?(context_value_from_path, value)
      when "notEquals"
        !attribute_exists || !strict_equal?(context_value_from_path, value)
      when "before", "after"
        date_in_context = portable_date(context_value_from_path)
        date_in_condition = portable_date(value)
        return false unless date_in_context && date_in_condition

        if operator == "before"
          date_in_context < date_in_condition
        else
          date_in_context > date_in_condition
        end
      when "in", "notIn"
        # in / notIn (where condition value is an array)
        if attribute_exists && value.is_a?(Array) &&
           (context_value_from_path.is_a?(String) || context_value_from_path.is_a?(Numeric) || context_value_from_path.nil?)
          matched = value.any? { |candidate| strict_equal?(candidate, context_value_from_path) }
          if operator == "in"
            matched
          else # notIn
            !matched
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
        attribute_exists
      when "notExists"
        !attribute_exists
      when "includes", "notIncludes"
        # includes / notIncludes (where context value is an array)
        if context_value_from_path.is_a?(Array) &&
           (value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.nil?)
          matched = context_value_from_path.any? { |candidate| strict_equal?(candidate, value) }
          if operator == "includes"
            matched
          else # notIncludes
            !matched
          end
        else
          false
        end
      else
        false
      end
    end

    def self.portable_date(value)
      return value if value.is_a?(Time) || value.is_a?(DateTime)
      return value.to_time if value.is_a?(Date)
      return nil unless value.is_a?(String)
      return nil unless value.match?(/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:\d{2})\z/)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end
    private_class_method :portable_date
  end
end
