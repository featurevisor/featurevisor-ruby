# frozen_string_literal: true

module Featurevisor
  module UnifiedConditions
    def self.matches?(conditions, options)
      match(conditions, options)
    rescue Normalize::ParseFailure
      false
    end

    def self.match(conditions, options)
      raise Normalize::ParseFailure if conditions.is_a?(Normalize::InvalidConditions)
      return true if conditions == "*"
      if conditions.is_a?(String)
        datafile = options[:__featurevisor_datafile_source]&.call || options[:datafile]
        segment = datafile.get_segment(conditions)
        return false unless segment
        raise Normalize::ParseFailure if segment[:conditions].is_a?(Normalize::InvalidConditions)
        if datafile.attribute_only_conditions?(segment[:conditions])
          return datafile.all_conditions_are_matched(segment[:conditions], options[:context])
        end
        session = options[:__featurevisor_session] ||= EvaluationSession.new
        return session.segment(conditions) { match(segment[:conditions], options) }
      end
      if conditions.is_a?(Array)
        return !conditions.empty? && conditions.all? { |child| match(child, options) }
      end
      return false unless conditions.is_a?(Hash)
      if conditions.key?(:variable)
        begin
          return options[:__featurevisor_instance].send(:variable_condition_matches?, conditions, options)
        rescue RequirementError
          raise
        rescue => error
          raise RequirementError, error.message
        end
      end
      if conditions.key?(:feature)
        clean = options.reject { |key, _| %i[feature_key variable_key default_variable_value default_variation_value].include?(key) }
        clean = clean.merge(__featurevisor_prerequisite: true, dependency_purpose: "condition")
        flag = Evaluate.evaluate_with_modules(clean.merge(type: "flag", feature_key: conditions[:feature]))
        enabled = conditions[:enabled].nil? ? true : conditions[:enabled]
        return false unless (flag[:enabled] == true) == enabled
        return true unless conditions.key?(:variation)
        variation = Evaluate.evaluate_with_modules(clean.merge(type: "variation", feature_key: conditions[:feature]))
        value = variation.key?(:variation_value) ? variation[:variation_value] : variation.dig(:variation, :value)
        return value == conditions[:variation]
      end
      if conditions.key?(:attribute)
        return options[:datafile].all_conditions_are_matched(conditions, options[:context])
      end
      %i[and or not].each do |group|
        next unless conditions[group].is_a?(Array)
        children = conditions[group]
        return false if children.empty?
        return children.any? { |child| match(child, options) } if group == :or
        result = children.all? { |child| match(child, options) }
        return group == :not ? !result : result
      end
      false
    end
    private_class_method :match

    def self.attribute_only?(conditions)
      case conditions
      when Array
        conditions.all? { |child| attribute_only?(child) }
      when Hash
        return false if conditions.is_a?(Normalize::InvalidConditions) || conditions.key?(:feature) || conditions.key?(:variable)
        return true if conditions.key?(:attribute)
        group = %i[and or not].find { |name| conditions.key?(name) }
        group.nil? || attribute_only?(conditions[group])
      else
        false
      end
    end
    private_class_method :attribute_only?
  end
end
