# frozen_string_literal: true

require "json"

module Featurevisor
  module Normalize
    class InvalidConditions < Hash
      def initialize
        super
        self[:or] = []
      end
    end

    class ParseFailure < StandardError; end

    def self.legacy(value, features = false)
      return value if value.is_a?(InvalidConditions)
      case value
      when String
        features ? { feature: value } : value
      when Array
        value.empty? ? "*" : value.map { |entry| legacy(entry, features) }
      when Hash
        group = %i[and or not].find { |name| value[name].is_a?(Array) }
        return value unless group
        return "*" if group == :and && value[group].empty?
        { group => value[group].map { |entry| legacy(entry, features) } }
      else
        value
      end
    end

    def self.entity(kind, key, source, legacy = false)
      errors = []
      parse = lambda do |value|
        next value unless value.is_a?(String) && value.lstrip.match?(/\A[\{\[\"]/)
        begin
          JSON.parse(value, symbolize_names: true)
        rescue JSON::ParserError => error
          errors << { level: "error", code: "conditions_parse_error", message: "Error parsing conditions",
                      original_error: error,
                      details: { conditions: value, entityType: kind.to_s, entityKey: key.to_s } }
          InvalidConditions.new
        end
      end
      select = lambda do |entry, old = false|
        result = entry.reject { |name, _| %i[segments requiredFeatures requiredVariables required].include?(name) }
        parts = []
        if entry.key?(:conditions)
          value = parse.call(entry[:conditions])
          parts << (old ? self.legacy(value) : value)
        end
        parts << self.legacy(parse.call(entry[:segments])) if entry.key?(:segments)
        if entry.key?(:requiredFeatures)
          features = entry[:requiredFeatures]
          features = [features] unless features.is_a?(Array)
          parts << features.map { |value| self.legacy(value, true) } unless features.empty?
        end
        if parts.any? { |part| part.is_a?(InvalidConditions) }
          result[:conditions] = InvalidConditions.new
        elsif parts.length == 1
          result[:conditions] = parts.first
        elsif !parts.empty?
          result[:conditions] = parts.flat_map { |part| part.is_a?(Array) ? (part.empty? ? [{ and: [] }] : part) : [part] }
        end
        result
      end
      with_overrides = lambda do |entry|
        next entry unless entry[:variableOverrides]
        entry.merge(variableOverrides: entry[:variableOverrides].transform_values do |values|
          values.map { |override| select.call(override, legacy) }
        end)
      end
      if kind.to_s == "segment"
        value = parse.call(source[:conditions])
        result = source.merge(conditions: legacy ? self.legacy(value) : value)
      else
        result = select.call(source)
        if kind.to_s == "feature"
          result[:traffic] = (source[:traffic] || []).map { |entry| with_overrides.call(select.call(entry)) }
          result[:force] = source[:force].map { |entry| select.call(entry, legacy) } if source[:force]
          result[:variations] = source[:variations].map { |entry| with_overrides.call(entry) } if source[:variations]
        else
          %i[overrides overrideProgram].each do |name|
            result[name] = source[name].map { |entry| select.call(entry, legacy && name == :overrides) } if source[name]
          end
        end
      end
      [result, errors]
    end

    def self.datafile(source)
      errors = []
      result = source.dup
      { features: :feature, segments: :segment, variables: :variable }.each do |name, kind|
        next unless source[name]
        result[name] = source[name].each_with_object({}) do |(key, entry), values|
          values[key], diagnostics = entity(kind, key, entry, true)
          errors.concat(diagnostics)
        end
      end
      [result, errors]
    end
  end
end
