# frozen_string_literal: true

require "json"

module Featurevisor
  # DatafileReader class for reading and processing Featurevisor datafiles
  class DatafileReader
    attr_reader :schema_version, :revision, :segments, :features, :logger, :regex_cache

    # Initialize a new DatafileReader
    # @param options [Hash] Options hash containing datafile and logger
    # @option options [Hash] :datafile Datafile content
    # @option options [Logger] :logger Logger instance
    def initialize(options)
      datafile = options[:datafile]
      @logger = options[:logger]

      @schema_version = datafile[:schemaVersion]
      @revision = datafile[:revision]
      @segments = (datafile[:segments] || {}).transform_keys(&:to_sym)
      @features = (datafile[:features] || {}).transform_keys(&:to_sym)

      # Transform nested structures to use symbol keys
      @features.each do |_key, feature|
        if feature[:variablesSchema]
          feature[:variablesSchema] = feature[:variablesSchema].transform_keys(&:to_sym)
        end
        if feature[:variations]
          feature[:variations].each do |variation|
            if variation[:variables]
              variation[:variables] = variation[:variables].transform_keys(&:to_sym)
            end
            if variation[:variableOverrides]
              variation[:variableOverrides] = variation[:variableOverrides].transform_keys(&:to_sym)
            end
          end
        end
        if feature[:force]
          feature[:force].each do |force_rule|
            if force_rule[:variables]
              force_rule[:variables] = force_rule[:variables].transform_keys(&:to_sym)
            end
          end
        end
        if feature[:traffic]
          feature[:traffic].each do |traffic_rule|
            if traffic_rule[:variables]
              traffic_rule[:variables] = traffic_rule[:variables].transform_keys(&:to_sym)
            end
          end
        end
      end
      @regex_cache = {}
    end

    # Get the revision of the datafile
    # @return [String] Revision string
    def get_revision
      @revision
    end

    # Get the schema version of the datafile
    # @return [String] Schema version string
    def get_schema_version
      @schema_version
    end

    # Get a segment by key
    # @param segment_key [String] Segment key to retrieve
    # @return [Hash, nil] Segment data or nil if not found
    def get_segment(segment_key)
      segment = @segments[segment_key.to_sym] || @segments[segment_key]

      return nil unless segment

      segment[:conditions] = parse_conditions_if_stringified(segment[:conditions])
      segment
    end

    # Get all feature keys
    # @return [Array<Symbol>] Array of feature keys
    def get_feature_keys
      @features.keys
    end

    # Get a feature by key
    # @param feature_key [String] Feature key to retrieve
    # @return [Hash, nil] Feature data or nil if not found
    def get_feature(feature_key)
      @features[feature_key.to_sym] || @features[feature_key]
    end

    # Get variable keys for a feature
    # @param feature_key [String] Feature key
    # @return [Array<String>] Array of variable keys
    def get_variable_keys(feature_key)
      feature = get_feature(feature_key)

      return [] unless feature

      (feature[:variablesSchema] || {}).keys
    end

    # Check if a feature has variations
    # @param feature_key [String] Feature key
    # @return [Boolean] True if feature has variations
    def has_variations?(feature_key)
      feature = get_feature(feature_key)

      return false unless feature

      feature[:variations].is_a?(Array) && feature[:variations].size > 0
    end

    # Get a regex object with caching
    # @param regex_string [String] Regex pattern string
    # @param regex_flags [String] Regex flags (optional)
    # @return [Regexp] Compiled regex object
    def get_regex(regex_string, regex_flags = "")
      flags = regex_flags || ""
      cache_key = "#{regex_string}-#{flags}"

      return @regex_cache[cache_key] if @regex_cache[cache_key]

      regex = Regexp.new(regex_string, flags)
      @regex_cache[cache_key] = regex
      @regex_cache[cache_key]
    end

    # Check if all conditions are matched against context
    # @param conditions [Array<Hash>, Hash, String] Conditions to evaluate
    # @param context [Hash] Context to evaluate against
    # @return [Boolean] True if all conditions match
    def all_conditions_are_matched(conditions, context)
      if conditions.is_a?(String)
        return true if conditions == "*"
        return false
      end

      get_regex_proc = ->(regex_string, regex_flags) { get_regex(regex_string, regex_flags) }

      if conditions.is_a?(Hash) && (conditions[:attribute] || conditions["attribute"])
        begin
          result = Conditions.condition_is_matched(conditions, context, get_regex_proc)
          return result
        rescue => e
          @logger.warn("Error in condition evaluation: #{e.message}", {
            error: e.class.name,
            details: {
              condition: conditions,
              context: context
            }
          })
          return false
        end
      end

      if conditions.is_a?(Hash) && conditions[:and] && conditions[:and].is_a?(Array)
        return conditions[:and].all? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions["and"] && conditions["and"].is_a?(Array)
        return conditions["and"].all? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions[:or] && conditions[:or].is_a?(Array)
        return conditions[:or].any? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions["or"] && conditions["or"].is_a?(Array)
        return conditions["or"].any? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions[:not] && conditions[:not].is_a?(Array)
        return conditions[:not].all? do
          all_conditions_are_matched({ and: conditions[:not] }, context) == false
        end
      end

      if conditions.is_a?(Hash) && conditions["not"] && conditions["not"].is_a?(Array)
        return conditions["not"].all? do
          all_conditions_are_matched({ "and" => conditions["not"] }, context) == false
        end
      end

      if conditions.is_a?(Array)
        return conditions.all? { |c| all_conditions_are_matched(c, context) }
      end

      false
    end

    # Check if a segment is matched against context
    # @param segment [Hash] Segment to evaluate
    # @param context [Hash] Context to evaluate against
    # @return [Boolean] True if segment matches
    def segment_is_matched(segment, context)
      all_conditions_are_matched(segment[:conditions], context)
    end

    # Check if all segments are matched against context
    # @param group_segments [String, Array, Hash] Segments to evaluate
    # @param context [Hash] Context to evaluate against
    # @return [Boolean] True if all segments match
    def all_segments_are_matched(group_segments, context)
      if group_segments == "*"
        return true
      end

      if group_segments.is_a?(String)
        segment = get_segment(group_segments)

        if segment
          return segment_is_matched(segment, context)
        end

        return false
      end

      if group_segments.is_a?(Hash)
        if group_segments[:and] && group_segments[:and].is_a?(Array)
          return group_segments[:and].all? { |group_segment| all_segments_are_matched(group_segment, context) }
        end

        if group_segments["and"] && group_segments["and"].is_a?(Array)
          return group_segments["and"].all? { |group_segment| all_segments_are_matched(group_segment, context) }
        end

        if group_segments[:or] && group_segments[:or].is_a?(Array)
          return group_segments[:or].any? { |group_segment| all_segments_are_matched(group_segment, context) }
        end

        if group_segments["or"] && group_segments["or"].is_a?(Array)
          return group_segments["or"].any? { |group_segment| all_segments_are_matched(group_segment, context) }
        end

        if group_segments[:not] && group_segments[:not].is_a?(Array)
          return group_segments[:not].all? do
            all_segments_are_matched({ and: group_segments[:not] }, context) == false
          end
        end

        if group_segments["not"] && group_segments["not"].is_a?(Array)
          return group_segments["not"].all? do
            all_segments_are_matched({ "and" => group_segments["not"] }, context) == false
          end
        end
      end

      if group_segments.is_a?(Array)
        return group_segments.all? { |group_segment| all_segments_are_matched(group_segment, context) }
      end

      false
    end

    # Get matched traffic based on context
    # @param traffic [Array<Hash>] Traffic array to search
    # @param context [Hash] Context to evaluate against
    # @return [Hash, nil] Matched traffic or nil
    def get_matched_traffic(traffic, context)
      traffic.find do |t|
        segments = parse_segments_if_stringified(t[:segments])
        matched = all_segments_are_matched(segments, context)
        next false unless matched
        true
      end
    end

    # Get matched allocation based on bucket value
    # @param traffic [Hash] Traffic object
    # @param bucket_value [Numeric] Bucket value to match
    # @return [Hash, nil] Matched allocation or nil
    def get_matched_allocation(traffic, bucket_value)
      return nil unless traffic[:allocation]

      traffic[:allocation].find do |allocation|
        start, end_val = allocation[:range]
        start <= bucket_value && end_val >= bucket_value
      end
    end

    # Get matched force based on context
    # @param feature_key [String, Hash] Feature key or feature object
    # @param context [Hash] Context to evaluate against
    # @return [Hash] Force result with force and forceIndex
    def get_matched_force(feature_key, context)
      result = {
        force: nil,
        forceIndex: nil
      }

      feature = feature_key.is_a?(String) ? get_feature(feature_key) : feature_key

      return result unless feature && feature[:force]

      feature[:force].each_with_index do |current_force, i|
        if current_force[:conditions] && all_conditions_are_matched(
          parse_conditions_if_stringified(current_force[:conditions]), context
        )
          result[:force] = current_force
          result[:forceIndex] = i
          break
        end

        if current_force[:segments] && all_segments_are_matched(
          parse_segments_if_stringified(current_force[:segments]), context
        )
          result[:force] = current_force
          result[:forceIndex] = i
          break
        end
      end

      result
    end

    # Parse conditions if they are stringified
    # @param conditions [String, Array, Hash] Conditions to parse
    # @return [Array, Hash, String] Parsed conditions
    def parse_conditions_if_stringified(conditions)
      return conditions unless conditions.is_a?(String)

      return conditions if conditions == "*"

      begin
        JSON.parse(conditions)
      rescue => e
        @logger.error("Error parsing conditions", {
          error: e,
          details: {
            conditions: conditions
          }
        })
        conditions
      end
    end

    # Parse segments if they are stringified
    # @param segments [String, Array, Hash] Segments to parse
    # @return [Array, Hash, String] Parsed segments
    def parse_segments_if_stringified(segments)
      if segments.is_a?(String) && (segments.start_with?("{") || segments.start_with?("["))
        return JSON.parse(segments)
      end

      segments
    end
  end
end
