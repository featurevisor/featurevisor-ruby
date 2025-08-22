# frozen_string_literal: true

module Featurevisor
  # Events module for generating event parameters
  module Events
    # Get parameters for sticky set event
    # @param previous_sticky [Hash] Previous sticky features
    # @param new_sticky [Hash] New sticky features
    # @param replace [Boolean] Whether features were replaced
    # @return [Hash] Event parameters
    def self.get_params_for_sticky_set_event(previous_sticky = {}, new_sticky = {}, replace = false)
      keys_before = previous_sticky.keys
      keys_after = new_sticky.keys

      all_keys = (keys_before + keys_after).uniq

      {
        features: all_keys,
        replaced: replace
      }
    end

    # Get parameters for datafile set event
    # @param previous_reader [DatafileReader] Previous datafile reader
    # @param new_reader [DatafileReader] New datafile reader
    # @return [Hash] Event parameters
    def self.get_params_for_datafile_set_event(previous_reader, new_reader)
      previous_revision = previous_reader.get_revision
      previous_feature_keys = previous_reader.get_feature_keys

      new_revision = new_reader.get_revision
      new_feature_keys = new_reader.get_feature_keys

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

        if previous_feature && new_feature && previous_feature[:hash] != new_feature[:hash]
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

      {
        revision: new_revision,
        previous_revision: previous_revision,
        revision_changed: previous_revision != new_revision,
        features: all_affected_features
      }
    end
  end
end
