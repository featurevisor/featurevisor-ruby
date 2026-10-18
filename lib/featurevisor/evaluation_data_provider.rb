# frozen_string_literal: true

require "json"

module Featurevisor
  # Private datafile and matching adapter used by the evaluator.
  class InstanceEvaluationDataProvider
    attr_reader :schema_version, :revision, :featurevisor_version, :segments, :features, :variables, :diagnostics, :regex_cache, :normalized
    attr_accessor :dependency_index

    # Initialize a new evaluation data provider.
    # @param options [Hash] Options hash containing datafile and diagnostics
    # @option options [Hash] :datafile Datafile content
    # @option options [DiagnosticReporter] :diagnostics Diagnostic reporter
    def initialize(options)
      datafile = options[:datafile]
      @diagnostics = options[:diagnostics]

      @schema_version = datafile[:schemaVersion]
      @revision = datafile[:revision]
      @featurevisor_version = datafile[:featurevisorVersion]
      @segments = (datafile[:segments] || {}).transform_keys(&:to_sym)
      @features = (datafile[:features] || {}).transform_keys(&:to_sym)
      @variables = (datafile[:variables] || {}).transform_keys(&:to_sym)
      @normalized = { feature: {}, segment: {}, variable: {} }
      @normalization_slots = { feature: {}, segment: {}, variable: {} }
      @normalization_mutex = Mutex.new
      @regex_cache = {}
      @conditions_cache = {}
      @segments_cache = {}
      @attribute_conditions_cache = {}
      @get_regex = method(:get_regex)
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

    def get_datafile
      {
        schemaVersion: @schema_version,
        revision: @revision,
        featurevisorVersion: @featurevisor_version,
        segments: @segments,
        features: @features,
        variables: @variables
      }.compact
    end

    # Get a segment by key
    # @param segment_key [String] Segment key to retrieve
    # @return [Hash, nil] Segment data or nil if not found
    def get_segment(segment_key)
      read_entity(:segment, segment_key, @segments)
    end

    def get_segment_keys
      @segments.keys
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
      read_entity(:feature, feature_key, @features)
    end

    # Get variable keys for a feature
    # @param feature_key [String] Feature key
    # @return [Array<String>] Array of variable keys
    def get_variable_keys(feature_key = nil)
      return @variables.keys if feature_key.nil?

      feature = get_feature(feature_key)

      return [] unless feature

      (feature[:variablesSchema] || {}).keys
    end

    def get_global_variable(variable_key)
      read_entity(:variable, variable_key, @variables)
    end

    def attribute_only_conditions?(conditions)
      key = conditions.object_id
      cached = @attribute_conditions_cache[key]
      return cached[1] if cached

      # Retain the syntax with its identity. Cache classification, never matches.
      @attribute_conditions_cache[key] = [conditions, UnifiedConditions.send(:attribute_only?, conditions)]
      @attribute_conditions_cache[key][1]
    end

    def retain_normalized(previous, incoming)
      @normalization_mutex, @normalization_slots, @normalized = previous.normalization_snapshot
      { feature: :features, segment: :segments, variable: :variables }.each do |kind, name|
        (incoming[name] || {}).each_key do |key|
          @normalization_slots[kind][key.to_sym] = []
          @normalized[kind].delete(key.to_sym)
        end
      end
    end

    # Share individual cold slots, never a chain of previous providers.
    def normalization_snapshot
      @normalization_mutex.synchronize do
        { feature: @features, segment: @segments, variable: @variables }.each do |kind, definitions|
          next if @normalization_slots[kind].size == definitions.size
          definitions.each_key { |key| @normalization_slots[kind][key] ||= [] }
        end
        [@normalization_mutex, @normalization_slots.transform_values(&:dup), @normalized.transform_values(&:dup)]
      end
    end

    def read_entity(kind, key, definitions)
      name = key.to_sym
      cached = @normalized[kind][name]
      return cached if cached
      source = definitions[name] || definitions[key]
      return nil unless source
      errors = []
      value = @normalization_mutex.synchronize do
        slot = @normalization_slots[kind][name] ||= []
        if slot.empty?
          normalized, errors = Normalize.entity(kind, name, source)
          slot << normalized
        end
        @normalized[kind][name] = slot.first
      end
      # Publication precedes diagnostics, and application callbacks never hold the mutex.
      errors.each do |error|
        @diagnostics.error(error[:message], { code: error[:code], error: error[:original_error], details: error[:details] })
      end
      value
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

      ruby_flags = 0
      ruby_flags |= Regexp::IGNORECASE if flags.include?("i")
      # Ruby's MULTILINE option controls dot matching newlines, which is the
      # JavaScript `s` behavior. Ruby anchors already operate per line.
      ruby_flags |= Regexp::MULTILINE if flags.include?("s")
      invalid_flags = flags.delete("gimsuy")
      raise ArgumentError, "invalid regular expression flags: #{invalid_flags}" unless invalid_flags.empty?

      regex = Regexp.new(Conditions.normalize_portable_regex(regex_string), ruby_flags)
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

      if conditions.is_a?(Hash) && (conditions[:attribute] || conditions["attribute"])
        begin
          result = Conditions.condition_is_matched(conditions, context, @get_regex)
          return result
        rescue => e
          @diagnostics.warn(e.message, {
            code: "condition_match_error",
            error: e,
            condition: conditions,
            context: context
          })
          return false
        end
      end

      if conditions.is_a?(Hash) && conditions[:and] && conditions[:and].is_a?(Array)
        return !conditions[:and].empty? && conditions[:and].all? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions["and"] && conditions["and"].is_a?(Array)
        return !conditions["and"].empty? && conditions["and"].all? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions[:or] && conditions[:or].is_a?(Array)
        return conditions[:or].any? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions["or"] && conditions["or"].is_a?(Array)
        return conditions["or"].any? { |c| all_conditions_are_matched(c, context) }
      end

      if conditions.is_a?(Hash) && conditions[:not] && conditions[:not].is_a?(Array)
        return false if conditions[:not].empty?
        return !all_conditions_are_matched({ and: conditions[:not] }, context)
      end

      if conditions.is_a?(Hash) && conditions["not"] && conditions["not"].is_a?(Array)
        return false if conditions["not"].empty?
        return !all_conditions_are_matched({ "and" => conditions["not"] }, context)
      end



      if conditions.is_a?(Array)
        return !conditions.empty? && conditions.all? { |c| all_conditions_are_matched(c, context) }
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
          return false if group_segments[:not].empty?
          return !all_segments_are_matched({ and: group_segments[:not] }, context)
        end

        if group_segments["not"] && group_segments["not"].is_a?(Array)
          return false if group_segments["not"].empty?
          return !all_segments_are_matched({ "and" => group_segments["not"] }, context)
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
    def get_matched_traffic(traffic, context, options = nil)
      traffic.find do |t|
        next t.key?(:conditions) && UnifiedConditions.matches?(t[:conditions], options) if options
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
    def get_matched_force(feature_key, context, options = nil)
      result = {
        force: nil,
        forceIndex: nil
      }

      feature = feature_key.is_a?(String) ? get_feature(feature_key) : feature_key

      return result unless feature && feature[:force]

      feature[:force].each_with_index do |current_force, i|
        if options
          if current_force.key?(:conditions) && UnifiedConditions.matches?(current_force[:conditions], options)
            result[:force] = current_force
            result[:forceIndex] = i
            break
          end
          next
        end
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
      return @conditions_cache[conditions] if @conditions_cache.key?(conditions)

      begin
        @conditions_cache[conditions] = JSON.parse(conditions)
      rescue => e
        @diagnostics.error("Error parsing conditions", {
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
        return @segments_cache[segments] if @segments_cache.key?(segments)

        return @segments_cache[segments] = JSON.parse(segments)
      end

      segments
    end

    # Cache parsed expressions, never context dependent matching results.
    # A new provider owns a new generation after each datafile update.
    def clear_caches
      @dependency_index = nil
      @normalization_mutex.synchronize do
        @normalized.each_value(&:clear)
        @normalization_slots.each_value(&:clear)
      end
      @regex_cache.clear
      @conditions_cache.clear
      @segments_cache.clear
      @attribute_conditions_cache.clear
    end
  end

  private_constant :InstanceEvaluationDataProvider
end
