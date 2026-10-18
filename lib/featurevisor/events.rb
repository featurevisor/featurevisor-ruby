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
    def self.get_params_for_datafile_set_event(previous_reader, new_reader, replace = false, incoming = nil)
      previous_revision = previous_reader.get_revision
      previous_feature_keys = previous_reader.get_feature_keys

      new_revision = new_reader.get_revision
      new_feature_keys = new_reader.get_feature_keys
      previous_variable_keys = previous_reader.get_variable_keys
      new_variable_keys = new_reader.get_variable_keys

      if previous_feature_keys.empty? && previous_variable_keys.empty? && previous_reader.get_segment_keys.empty?
        return {
          revision: new_revision,
          previousRevision: previous_revision,
          revisionChanged: previous_revision != new_revision,
          features: new_feature_keys,
          variables: new_variable_keys,
          replaced: replace
        }
      end

      # results
      removed_features = []
      changed_features = []
      added_features = []

      # checking against existing datafile
      previous_feature_keys.each do |previous_feature_key|
        if !new_reader.features.key?(previous_feature_key)
          # feature was removed in new datafile
          removed_features << previous_feature_key
          next
        end

        # feature exists in both datafiles, check if it was changed
        previous_feature = previous_reader.features[previous_feature_key]
        new_feature = new_reader.features[previous_feature_key]

        if previous_feature && new_feature &&
           (previous_feature[:hash].nil? || previous_feature[:hash].empty? ||
             new_feature[:hash].nil? || new_feature[:hash].empty? ||
             previous_feature[:hash] != new_feature[:hash])
          # feature was changed in new datafile
          changed_features << previous_feature_key
        end
      end

      # checking against new datafile
      new_feature_keys.each do |new_feature_key|
        if !previous_reader.features.key?(new_feature_key)
          # feature was added in new datafile
          added_features << new_feature_key
        end
      end

      # combine all affected feature keys
      all_affected_features = (removed_features + changed_features + added_features).uniq
      all_affected_variables = (previous_variable_keys + new_variable_keys).uniq.select do |key|
        previous = previous_reader.variables[key]
        current = new_reader.variables[key]
        previous.nil? || current.nil? ||
          previous[:hash].nil? || previous[:hash].empty? || current[:hash].nil? || current[:hash].empty? ||
          previous[:hash] != current[:hash]
      end


      new_datafile = new_reader.get_datafile
      changed_segments = (previous_reader.get_segment_keys + new_reader.get_segment_keys).uniq.select do |key|
        previous = previous_reader.segments[key]
        current = new_reader.segments[key]
        !previous.equal?(current) && previous != current
      end
      index = previous_reader.dependency_index || Dependencies.create_index(previous_reader.get_datafile)
      if replace || incoming.nil?
        incoming = Dependencies::COLLECTIONS.to_h do |name, _|
          [name, (previous_reader.public_send(name).keys + new_datafile[name].keys).uniq.to_h { |key| [key, true] }]
        end
      end
      Dependencies.add_changes(all_affected_features, all_affected_variables, changed_segments,
                               index)
      index.update(new_datafile, incoming, previous_reader.get_datafile)
      index.reorder(new_datafile) if replace
      Dependencies.add_changes(all_affected_features, all_affected_variables, changed_segments,
                               index)
      new_reader.dependency_index = index

      {
        revision: new_revision,
        previousRevision: previous_revision,
        revisionChanged: previous_revision != new_revision,
        features: all_affected_features,
        variables: all_affected_variables,
        replaced: replace
      }
    end

  end
end
