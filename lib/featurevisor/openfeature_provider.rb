# frozen_string_literal: true

require "json"
require "time"
require "open_feature/sdk"
require_relative "../featurevisor"

module Featurevisor
  class OpenFeatureProvider
    Provider = OpenFeature::SDK::Provider

    attr_reader :metadata, :featurevisor

    def initialize(options = {}, featurevisor: nil, targeting_key_field: "userId", key_separator: ":", variation_key: "variation", on_track: nil, **featurevisor_options)
      raise ArgumentError, "options must be a Hash" unless options.is_a?(Hash)

      @metadata = Provider::ProviderMetadata.new(name: "Featurevisor").freeze
      @targeting_key_field = targeting_key_field.empty? ? "userId" : targeting_key_field
      @key_separator = key_separator.empty? ? ":" : key_separator
      @variation_key = variation_key.empty? ? "variation" : variation_key
      @on_track = on_track
      @datafile_error = nil
      @shutdown = false
      @owns_featurevisor = featurevisor.nil?
      if featurevisor
        @featurevisor = featurevisor
      else
        resolved_options = options.merge(featurevisor_options)
        initial_datafile = resolved_options.delete(:datafile)
        @featurevisor = Featurevisor.create_featurevisor(resolved_options)
      end
      @error_unsubscribe = @featurevisor.on("error", lambda do |event|
        diagnostic = event[:diagnostic]
        @datafile_error = diagnostic[:message] if diagnostic&.dig(:code) == "invalid_datafile"
      end)
      @datafile_unsubscribe = @featurevisor.on("datafile_set", ->(*) { @datafile_error = nil })
      @featurevisor.set_datafile(initial_datafile, true) if @owns_featurevisor && initial_datafile
    end

    def init(_evaluation_context = nil); end
    def shutdown
      return if @shutdown

      @shutdown = true
      @error_unsubscribe&.call
      @datafile_unsubscribe&.call
      featurevisor.close if @owns_featurevisor
    end
    def hooks = []

    def track(tracking_event_name:, evaluation_context: nil, tracking_event_details: nil)
      @on_track&.call(tracking_event_name, evaluation_context, tracking_event_details)
    end

    def fetch_boolean_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :boolean)
    end

    def fetch_string_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :string)
    end

    def fetch_number_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :number)
    end

    def fetch_integer_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :integer)
    end

    def fetch_float_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :float)
    end

    def fetch_object_value(flag_key:, default_value:, evaluation_context: nil)
      resolve(flag_key, default_value, evaluation_context, :object)
    end

    private

    def resolve(flag_key, default_value, evaluation_context, expected_type)
      return error(default_value, Provider::ErrorCode::PARSE_ERROR, @datafile_error) if @datafile_error

      feature_key, selector = split_key(flag_key)
      context = normalize(evaluation_context&.fields || {})
      targeting_key = evaluation_context&.targeting_key
      context[@targeting_key_field] = targeting_key if targeting_key && !targeting_key.empty?

      if selector.nil? || selector.empty?
        return type_mismatch(flag_key, default_value, expected_type) unless expected_type == :boolean
        evaluation = featurevisor.evaluate_flag(feature_key, context)
        value = evaluation[:enabled]
      elsif selector == @variation_key
        evaluation = featurevisor.evaluate_variation(feature_key, context)
        value = evaluation[:variation_value] || evaluation.dig(:variation, :value)
      else
        evaluation = featurevisor.evaluate_variable(feature_key, selector, context)
        value = evaluation[:variable_value]
        if evaluation.dig(:variable_schema, :type) == "json" && value.is_a?(String)
          begin
            value = JSON.parse(value)
          rescue JSON::ParserError
            # Type validation below returns TYPE_MISMATCH when object was requested.
          end
        end
      end

      metadata = metadata_for(evaluation)
      code = error_code(evaluation[:reason])
      return error(default_value, code, error_message(evaluation), metadata) if code
      value = default_value if value.nil?
      value = normalize(value) if expected_type == :object
      return type_mismatch(flag_key, default_value, expected_type, metadata) unless matches?(value, expected_type)

      Provider::ResolutionDetails.new(
        value: value,
        reason: reason(evaluation[:reason]),
        variant: variant(evaluation),
        flag_metadata: metadata
      )
    end

    def split_key(key)
      index = key.index(@key_separator)
      index ? [key[0...index], key[(index + @key_separator.length)..]] : [key, nil]
    end

    def metadata_for(evaluation)
      metadata = {
        "featureKey" => evaluation[:feature_key],
        "featurevisorReason" => evaluation[:reason],
        "schemaVersion" => featurevisor.get_schema_version
      }
      metadata["revision"] = featurevisor.get_revision if featurevisor.get_revision
      {
        variable_key: "variableKey",
        rule_key: "ruleKey",
        bucket_key: "bucketKey",
        bucket_value: "bucketValue",
        force_index: "forceIndex",
        variable_override_index: "variableOverrideIndex"
      }.each do |key, metadata_key|
        metadata[metadata_key] = evaluation[key] unless evaluation[key].nil?
      end
      metadata
    end

    def reason(value)
      return Provider::Reason::ERROR if %w[feature_not_found variable_not_found no_variations error].include?(value)
      return Provider::Reason::TARGETING_MATCH if %w[required forced sticky rule variable_override_variation variable_override_rule].include?(value)
      return Provider::Reason::SPLIT if value == "allocated"
      return Provider::Reason::DISABLED if %w[disabled variation_disabled variable_disabled].include?(value)
      Provider::Reason::DEFAULT
    end

    def error_code(value)
      return Provider::ErrorCode::FLAG_NOT_FOUND if %w[feature_not_found variable_not_found no_variations].include?(value)
      return Provider::ErrorCode::GENERAL if value == "error"
      nil
    end

    def error_message(evaluation)
      return evaluation[:error].message if evaluation[:error].respond_to?(:message)
      return %(Feature "#{evaluation[:feature_key]}" was not found) if evaluation[:reason] == "feature_not_found"
      return %(Variable "#{evaluation[:variable_key]}" was not found for feature "#{evaluation[:feature_key]}") if evaluation[:reason] == "variable_not_found"
      return %(Feature "#{evaluation[:feature_key]}" has no variations) if evaluation[:reason] == "no_variations"
      "Featurevisor evaluation failed"
    end

    def variant(evaluation) = evaluation[:variation_value] || evaluation.dig(:variation, :value)

    def matches?(value, type)
      case type
      when :boolean then value == true || value == false
      when :string then value.is_a?(String)
      when :number then finite_number?(value)
      when :integer then value.is_a?(Integer)
      when :float then value.is_a?(Float) && value.finite?
      when :object then value.is_a?(Hash) || value.is_a?(Array)
      else false
      end
    end

    def finite_number?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) && (!value.respond_to?(:finite?) || value.finite?)
    end

    def normalize(value)
      case value
      when Time, DateTime then value.iso8601
      when Hash then value.to_h { |key, item| [key.to_s, normalize(item)] }
      when Array then value.map { |item| normalize(item) }
      else value
      end
    end

    def error(value, code, message, metadata = {})
      Provider::ResolutionDetails.new(value: value, reason: Provider::Reason::ERROR, error_code: code, error_message: message, flag_metadata: metadata)
    end

    def type_mismatch(key, value, expected_type, metadata = {})
      error(value, Provider::ErrorCode::TYPE_MISMATCH, %(Flag "#{key}" did not resolve to a #{expected_type} value), metadata)
    end
  end
end
