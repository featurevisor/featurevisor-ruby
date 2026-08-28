# frozen_string_literal: true

require "json"

module Featurevisor
  # Events module for generating event parameters
  module Events
    # Get parameters for sticky set event
    # @param previous_sticky [Hash] Previous sticky features
    # @param new_sticky [Hash] New sticky features
    # @param replace [Boolean] Whether features were replaced
    # @return [Hash] Event parameters
    def self.get_params_for_sticky_features_set_event(previous_sticky = {}, new_sticky = {}, replace = false)
      keys_before = previous_sticky.keys
      keys_after = new_sticky.keys

      all_keys = (keys_before + keys_after).uniq

      {
        features: all_keys,
        replaced: replace
      }
    end

    def self.get_params_for_sticky_variables_set_event(previous_sticky = {}, new_sticky = {}, replace = false)
      {
        variables: (previous_sticky.keys + new_sticky.keys).uniq,
        replaced: replace
      }
    end

    # Get parameters for datafile set event
    # @param previous_reader [InstanceEvaluationDataProvider] Previous datafile
    # @param new_reader [InstanceEvaluationDataProvider] New datafile
    # @return [Hash] Event parameters
    def self.get_params_for_datafile_set_event(previous_reader, new_reader, replace = false)
      previous_revision = previous_reader.get_revision
      previous_feature_keys = previous_reader.get_feature_keys

      new_revision = new_reader.get_revision
      new_feature_keys = new_reader.get_feature_keys
      previous_variable_keys = previous_reader.get_variable_keys
      new_variable_keys = new_reader.get_variable_keys

      # results
      removed_features = []
      changed_features = []
      added_features = []

      # checking against existing datafile
      previous_feature_keys.each do |previous_feature_key|
        if !new_feature_keys.include?(previous_feature_key)
          # feature was removed in new datafile
          removed_features << previous_feature_key
          next
        end

        # feature exists in both datafiles, check if it was changed
        previous_feature = previous_reader.get_feature(previous_feature_key)
        new_feature = new_reader.get_feature(previous_feature_key)

        if previous_feature && new_feature &&
           (previous_feature[:hash].nil? || new_feature[:hash].nil? || previous_feature[:hash] != new_feature[:hash])
          # feature was changed in new datafile
          changed_features << previous_feature_key
        end
      end

      # checking against new datafile
      new_feature_keys.each do |new_feature_key|
        if !previous_feature_keys.include?(new_feature_key)
          # feature was added in new datafile
          added_features << new_feature_key
        end
      end

      # combine all affected feature keys
      all_affected_features = (removed_features + changed_features + added_features).uniq
      all_affected_variables = (previous_variable_keys + new_variable_keys).uniq.select do |key|
        previous = previous_reader.get_global_variable(key)
        current = new_reader.get_global_variable(key)
        previous.nil? || current.nil? || previous[:hash].nil? || current[:hash].nil? || previous[:hash] != current[:hash]
      end


      changed_segments = (previous_reader.get_segment_keys + new_reader.get_segment_keys).uniq.select do |key|
        previous_reader.get_segment(key) != new_reader.get_segment(key)
      end.map(&:to_s)
      feature_keys = (previous_feature_keys + new_feature_keys).uniq
      loop do
        before = all_affected_features.length
        feature_keys.each do |key|
          next if all_affected_features.include?(key)

          candidates = [previous_reader.get_feature(key), new_reader.get_feature(key)].compact
          all_affected_features << key if candidates.any? do |feature|
            dependency = feature_dependencies(feature)
            !(dependency[:segments].map(&:to_s) & changed_segments).empty? ||
              !(dependency[:features].map(&:to_s) & all_affected_features.map(&:to_s)).empty?
          end
        end
        break if before == all_affected_features.length
      end

      (previous_variable_keys + new_variable_keys).uniq.each do |key|
        next if all_affected_variables.include?(key)

        candidates = [previous_reader.get_global_variable(key), new_reader.get_global_variable(key)].compact
        all_affected_variables << key if candidates.any? do |variable|
          dependency = global_variable_dependencies(variable)
          !(dependency[:segments].map(&:to_s) & changed_segments).empty? ||
            !(dependency[:features].map(&:to_s) & all_affected_features.map(&:to_s)).empty?
        end
      end

      {
        revision: new_revision,
        previousRevision: previous_revision,
        revisionChanged: previous_revision != new_revision,
        features: all_affected_features,
        variables: all_affected_variables,
        replaced: replace
      }
    end

    def self.required_feature_keys(values)
      items = values.is_a?(Array) ? values : [values].compact
      items.filter_map do |required|
        required.is_a?(String) ? required : (required[:feature] || required[:key])
      end
    end
    private_class_method :required_feature_keys

    def self.segment_keys(value)
      return [] if value.nil? || value == "*"
      if value.is_a?(String)
        if value.start_with?("{", "[")
          begin
            return segment_keys(JSON.parse(value, symbolize_names: true))
          rescue JSON::ParserError
            return []
          end
        end
        return [value]
      end
      return value.flat_map { |item| segment_keys(item) }.uniq if value.is_a?(Array)
      return [] unless value.is_a?(Hash)

      %i[and or not].flat_map { |key| segment_keys(value[key] || value[key.to_s]) }.uniq
    end
    private_class_method :segment_keys

    def self.override_dependencies(groups)
      overrides = groups.is_a?(Hash) ? groups.values.flatten : []
      {
        segments: overrides.flat_map { |override| segment_keys(override[:segments]) }.uniq,
        features: overrides.flat_map { |override| required_feature_keys(override[:requiredFeatures]) }.uniq
      }
    end
    private_class_method :override_dependencies

    def self.feature_dependencies(feature)
      requirements = feature.key?(:requiredFeatures) ? feature[:requiredFeatures] : feature[:required]
      segments = []
      features = required_feature_keys(requirements)
      Array(feature[:traffic]).each do |traffic|
        segments.concat(segment_keys(traffic[:segments]))
        nested = override_dependencies(traffic[:variableOverrides])
        segments.concat(nested[:segments])
        features.concat(nested[:features])
      end
      Array(feature[:force]).each { |force| segments.concat(segment_keys(force[:segments])) }
      Array(feature[:variations]).each do |variation|
        nested = override_dependencies(variation[:variableOverrides])
        segments.concat(nested[:segments])
        features.concat(nested[:features])
      end
      { segments: segments.uniq, features: features.uniq }
    end
    private_class_method :feature_dependencies

    def self.global_variable_dependencies(variable)
      segments = []
      features = required_feature_keys(variable[:requiredFeatures])
      Array(variable[:overrides]).each do |override|
        segments.concat(segment_keys(override[:segments]))
        features.concat(required_feature_keys(override[:requiredFeatures]))
      end
      { segments: segments.uniq, features: features.uniq }
    end
    private_class_method :global_variable_dependencies
  end
end
