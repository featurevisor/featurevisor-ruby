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

      # Most attributes are direct keys. Avoid allocating a path array for
      # every condition while retaining the existing nested path behaviour.
      unless path.empty? || path.include?(".")
        symbol = path.to_sym
        return obj[symbol] if obj.key?(symbol)
        return obj[path] if obj.key?(path)

        return MISSING
      end

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
      return left == right if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left == right if left.is_a?(String) && right.is_a?(String)
      return left == right if (left == true || left == false) && (right == true || right == false)

      false
    end
    private_class_method :strict_equal?

    def self.missing_value
      MISSING
    end

    def self.value_is_matched(raw_value, condition, get_regex)
      context = raw_value.equal?(MISSING) ? {} : { value: raw_value }
      condition_is_matched(condition.merge(attribute: "value"), context, get_regex)
    end

    # Check if a condition is matched against context
    # @param condition [Hash] Condition to evaluate
    # @param context [Hash] Context to evaluate against
    # @param get_regex [Proc] Function to get regex for pattern matching
    # @return [Boolean] True if condition matches
    def self.condition_is_matched(condition, context, get_regex)
      attribute = condition["attribute"] || condition[:attribute]
      operator = condition["operator"] || condition[:operator]
      value = if condition.key?(:value)
                condition[:value]
              elsif condition.key?("value")
                condition["value"]
              end
      regex_flags = condition["regexFlags"] || condition[:regexFlags]

      raw_context_value = get_value_with_presence(context, attribute)
      context_value_from_path = raw_context_value.equal?(MISSING) ? nil : raw_context_value
      attribute_exists = !raw_context_value.equal?(MISSING)

      case operator
      when "empty", "notEmpty"
        return false unless attribute_exists && !context_value_from_path.nil?

        size = if context_value_from_path.is_a?(String) || context_value_from_path.is_a?(Array) ||
                  context_value_from_path.is_a?(Hash)
                 context_value_from_path.size
               end
        !size.nil? && (operator == "empty" ? size.zero? : size.positive?)
      when "isNull"
        attribute_exists && context_value_from_path.nil?
      when "notNull"
        attribute_exists && !context_value_from_path.nil?
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
      when "includesAny", "notIncludesAny"
        return false unless context_value_from_path.is_a?(Array) && value.is_a?(Array)
        return false unless value.all? { |candidate| candidate.nil? || candidate.is_a?(String) || candidate.is_a?(Integer) || candidate.is_a?(Float) || candidate == true || candidate == false }

        matched = value.any? { |candidate| context_value_from_path.any? { |actual| strict_equal?(actual, candidate) } }
        operator == "includesAny" ? matched : !matched
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
      if value.is_a?(String)
        match = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|([+\-])([0-9]{2}):([0-9]{2}))\z/.match(value)
        return nil unless match
        return nil if value.start_with?("0000-")
        if match[2] && (match[2].to_i > 14 || match[3].to_i > 59 || (match[2] == "14" && match[3] != "00"))
          return nil
        end
        parsed = Time.iso8601(value)
        # Time.iso8601 must not normalize an invalid calendar date or clock time.
        return nil unless parsed.getlocal(match[1] ? "#{match[1]}#{match[2]}:#{match[3]}" : "+00:00").strftime("%Y-%m-%dT%H:%M:%S") == value[0, 19]
      elsif value.is_a?(Time) || value.is_a?(DateTime)
        return nil unless (1..9999).cover?(value.year)
        offset_seconds = value.is_a?(DateTime) ? value.offset * 86400 : value.utc_offset
        return nil if offset_seconds.abs > 14 * 3600
        parsed = value.to_time
      else
        return nil
      end
      milliseconds = (parsed.to_r * 1000).floor
      result = Time.at(Rational(milliseconds, 1000)).utc
      return nil if result.year < 1 || result.year > 9999
      result
    rescue ArgumentError, RangeError
      nil
    end
    private_class_method :portable_date

    def self.normalize_portable_regex(pattern)
      inside = {
        'd' => '0-9', 'D' => '\\u{0}-\\u{2F}\\u{3A}-\\u{10FFFF}',
        'w' => 'A-Za-z0-9_', 'W' => '\\u{0}-\\u{2F}\\u{3A}-\\u{40}\\u{5B}-\\u{5E}\\u{60}\\u{7B}-\\u{10FFFF}'
      }
      outside = { 'd' => '[0-9]', 'D' => '[^0-9]', 'w' => '(?-i:[A-Za-z0-9_])', 'W' => '(?-i:[^A-Za-z0-9_])' }
      output = +''
      in_class = false
      index = 0
      while index < pattern.length
        char = pattern[index]
        if char == '\\' && index + 1 < pattern.length
          code = pattern[index + 1]
          output << (in_class ? inside : outside).fetch(code, pattern[index, 2])
          index += 2
          next
        end
        in_class = true if char == '[' && !in_class
        in_class = false if char == ']' && in_class
        output << char
        index += 1
      end
      output
    end
  end
end
