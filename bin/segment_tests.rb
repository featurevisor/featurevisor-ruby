# frozen_string_literal: true

module FeaturevisorCLI
  module SegmentTests
    module_function

    def prepare(datafile, segments)
      return datafile if segments.empty?

      definitions = segments.transform_keys(&:to_sym).merge((datafile[:segments] || {}).transform_keys(&:to_sym))
      features = (datafile[:features] || {}).dup
      keys = {}
      segments.each_key do |key|
        helper = "__featurevisor_segment_test__#{key}"
        helper += "_" while features.key?(helper.to_sym) || features.key?(helper)
        keys[key.to_s] = helper
        features[helper.to_sym] = { bucketBy: "__segment_test__", conditions: key.to_s,
                                   traffic: [{ key: "segment", conditions: "*", percentage: 100_000 }] }
      end
      datafile.merge(features: features, segments: definitions, _segment_test_keys: keys)
    end

    def references!(key, datafile, segments)
      pending = [[:segment, key, nil]]
      seen = {}
      expression = nil
      expression = lambda do |value|
        case value
        when String
          next if value == "*"
          if value.lstrip.match?(/\A[\{\[\"]/)
            begin
              expression.call(JSON.parse(value, symbolize_names: true))
            rescue JSON::ParserError
              nil
            end
          else
            pending << [:segment, value, nil]
          end
        when Array
          value.each { |child| expression.call(child) }
        when Hash
          if value.key?(:variable)
            pending << [value[:feature] ? :feature : :variable, value[:feature] || value[:variable], value[:feature] && value[:variable]]
          elsif value.key?(:feature)
            pending << [:feature, value[:feature], nil]
          else
            %i[and or not].each { |group| expression.call(value[group]) if value.key?(group) }
          end
        end
      end
      cursor = 0
      while cursor < pending.length
        kind, name, variable = pending[cursor]
        cursor += 1
        identity = [kind, name.to_s, variable]
        next if seen[identity]
        seen[identity] = true
        definitions = datafile[{ feature: :features, segment: :segments, variable: :variables }.fetch(kind)] || {}
        definition = kind == :segment ? TestChecks.keyed(segments, name) : nil
        definition ||= TestChecks.keyed(definitions, name)
        unless definition.is_a?(Hash)
          raise TestChecks::CheckError, "#{kind} #{name.inspect} is absent from the selected datafile and test definitions"
        end
        if variable && !TestChecks.keyed(definition[:variablesSchema], variable)
          raise TestChecks::CheckError, "variable #{variable.inspect} is absent from feature #{name.inspect} in the selected datafile"
        end
        normalized, = Featurevisor::Normalize.entity(kind, name, definition)
        expression.call(normalized[:conditions])
        if kind == :feature
          (Array(normalized[:force]) + Array(normalized[:traffic])).each { |entry| expression.call(entry[:conditions]) }
          if variable
            (Array(normalized[:traffic]) + Array(normalized[:variations])).each do |entry|
              Array(TestChecks.keyed(entry[:variableOverrides], variable)).each { |override| expression.call(override[:conditions]) }
            end
          end
        elsif kind == :variable
          (Array(normalized[:overrides]) + Array(normalized[:overrideProgram])).each { |entry| expression.call(entry[:conditions]) }
          compose = normalized[:compose]
          if compose.is_a?(String)
            pending << [:variable, compose, nil]
          elsif compose.is_a?(Array)
            compose.each { |reference| expression.call(reference) }
          end
        end
      end
    end
  end
end
