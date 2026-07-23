# frozen_string_literal: true

module Featurevisor
  # Bucketer module for handling feature flag bucketing
  module Bucketer
    # Maximum bucketed number (100% * 1000 to include three decimal places)
    MAX_BUCKETED_NUMBER = 100_000

    # Hash seed for consistent bucketing
    HASH_SEED = 1

    # Maximum hash value for 32-bit integers
    MAX_HASH_VALUE = 2**32

    # Default separator for bucket keys
    DEFAULT_BUCKET_KEY_SEPARATOR = "."

    # Get bucketed number from a bucket key
    # @param bucket_key [String] The bucket key to hash
    # @return [Integer] Bucket value between 0 and 100000
    def self.get_bucketed_number(bucket_key)
      hash_value = Featurevisor.murmur_hash_v3(bucket_key, HASH_SEED)
      ratio = hash_value.to_f / MAX_HASH_VALUE

      (ratio * MAX_BUCKETED_NUMBER).floor
    end

    # Get bucket key from feature configuration and context
    # @param options [Hash] Options hash containing:
    #   - feature_key [String] The feature key
    #   - bucket_by [String, Array<String>, Hash] Bucketing strategy
    #   - context [Hash] User context
    #   - diagnostics [DiagnosticReporter] Diagnostic reporter
    # @return [String] The bucket key
    # @raise [StandardError] If bucket_by is invalid
    def self.get_bucket_key(options)
      feature_key = options[:feature_key]
      bucket_by = options[:bucket_by]
      context = options[:context]
      diagnostics = options[:diagnostics]

      type, attribute_keys = parse_bucket_by(bucket_by, diagnostics, feature_key)

      bucket_key = build_bucket_key(attribute_keys, context, type, feature_key)

      bucket_key.join(DEFAULT_BUCKET_KEY_SEPARATOR)
    end

    private

    # Parse bucket_by configuration to determine type and attribute keys
    # @param bucket_by [String, Array<String>, Hash] Bucketing strategy
    # @param diagnostics [DiagnosticReporter] Diagnostic reporter
    # @param feature_key [String] Feature key for error logging
    # @return [Array] Tuple of [type, attribute_keys]
    def self.parse_bucket_by(bucket_by, diagnostics, feature_key)
      if bucket_by.is_a?(String)
        ["plain", [bucket_by]]
      elsif bucket_by.is_a?(Array)
        ["and", bucket_by]
      elsif bucket_by.is_a?(Hash) && bucket_by[:or].is_a?(Array)
        ["or", bucket_by[:or]]
      else
        diagnostics.error("invalid bucketBy", { feature_key: feature_key, bucket_by: bucket_by })
        raise StandardError, "invalid bucketBy"
      end
    end

    # Build bucket key array from attribute keys and context
    # @param attribute_keys [Array<String>] Array of attribute keys
    # @param context [Hash] User context
    # @param type [String] Bucketing type ("plain", "and", "or")
    # @param feature_key [String] Feature key to append
    # @return [Array] Array of bucket key components
    def self.build_bucket_key(attribute_keys, context, type, feature_key)
      bucket_key = []

      attribute_keys.each do |attribute_key|
        attribute_value = Featurevisor::Conditions.get_value_from_context(context, attribute_key)

        next if attribute_value.nil? && !context_path_exists?(context, attribute_key)

        if type == "plain" || type == "and"
          bucket_key << attribute_value
        elsif type == "or" && bucket_key.empty?
          # For "or" type, only take the first available value
          bucket_key << attribute_value
        end
      end

      bucket_key << feature_key
      bucket_key.map { |value| javascript_string(value) }
    end

    def self.context_path_exists?(context, path)
      path.split(".").reduce(context) do |current, key|
        return false unless current.is_a?(Hash)
        return false unless current.key?(key.to_sym) || current.key?(key)

        current.key?(key.to_sym) ? current[key.to_sym] : current[key]
      end
      true
    end

    def self.javascript_string(value)
      return "" if value.nil?
      return value ? "true" : "false" if value == true || value == false
      if value.is_a?(Float)
        return "NaN" if value.nan?
        return value.positive? ? "Infinity" : "-Infinity" if value.infinite?
        return "0" if value.zero?
        return value.to_i.to_s if value == value.to_i && value.abs < 1e21
        if value.abs >= 1e-6 && value.abs < 1e21
          return scientific_to_fixed(value.to_s)
        end

        coefficient, exponent = value.to_s.downcase.split("e")
        return "#{coefficient.delete_suffix('.0')}e#{Integer(exponent) >= 0 ? '+' : ''}#{Integer(exponent)}"
      end
      return value.map { |item| javascript_string(item) }.join(",") if value.is_a?(Array)
      return "[object Object]" if value.is_a?(Hash)

      value.to_s
    end

    def self.scientific_to_fixed(value)
      return value unless value.downcase.include?("e")

      coefficient, exponent_text = value.downcase.split("e")
      exponent = Integer(exponent_text)
      negative = coefficient.start_with?("-")
      digits = coefficient.delete_prefix("-").delete(".")
      decimal_position = coefficient.delete_prefix("-").index(".") || coefficient.delete_prefix("-").length
      decimal_position += exponent

      result = if decimal_position <= 0
                 "0.#{"0" * -decimal_position}#{digits}"
               elsif decimal_position >= digits.length
                 "#{digits}#{"0" * (decimal_position - digits.length)}"
               else
                 "#{digits[0...decimal_position]}.#{digits[decimal_position..]}"
               end

      result = result.sub(/(\.\d*?)0+\z/, '\1').delete_suffix(".")
      negative ? "-#{result}" : result
    end
    private_class_method :scientific_to_fixed
  end
end
