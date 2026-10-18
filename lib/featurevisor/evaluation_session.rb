# frozen_string_literal: true

require "json"

module Featurevisor
  class RequirementError < StandardError; end
  class RequirementCycleError < RequirementError; end

  # One evaluation owns its prerequisite stack and completed prerequisite values.
  class EvaluationSession
    def initialize
      @root = nil
      @root_current = nil
      @active = nil
      @memo = nil
      @sticky_inputs = nil
      @segments = nil
    end

    def dependency_of
      @active ? @active.last&.dig(:current) : @root_current
    end

    def update_current(options)
      current = dependency_of
      return if current && current[:type] == options[:type] &&
                current[:feature_key] == options[:feature_key] && current[:variable_key] == options[:variable_key]

      identity = identity_of(options)
      if @active
        @active.last[:current] = identity
      else
        @root_current = identity
      end
    end

    def run(options, prerequisite: false)
      # A root needs its original and redirected identities, but no dependency
      # stack, memo or retained sticky maps until a handoff is actually reached.
      if !@root && !@active && !prerequisite
        @root = @root_current = identity_of(options)
        begin
          return yield
        ensure
          clear
        end
      end

      @active ||= @root ? [{ identity: @root, current: @root_current }] : []
      identity = identity_of(options)
      raise RequirementCycleError, "Circular evaluation requirement" if @active.any? { |frame| frame[:identity] == identity || frame[:current] == identity }
      raise RequirementError, "Evaluation dependency depth exceeded" if @active.length + (@segments&.length || 0) > 256

      requester = dependency_of
      key = prerequisite ? fingerprint(identity, requester, options) : nil
      borrowed = options[:dependency_purpose] == "composition"
      return @memo[key] if key && @memo&.key?(key)

      @active << { identity: identity, current: identity }
      begin
        result = yield
        if prerequisite && options[:__featurevisor_project_variable]
          result = options[:__featurevisor_project_variable].call(result)
        end
        if key && key == fingerprint(identity, requester, options)
          minimal = minimal_result(result, borrowed)
          (@memo ||= {})[key] = borrowed ? minimal : duplicate(minimal) if minimal
        end
        result
      rescue => e
        @pending_error = { identity: identity, requester: requester, key: key }
        raise
      ensure
        @active.pop
        clear if @active.empty?
      end
    end

    def segment(key)
      @segments ||= []
      raise RequirementCycleError, "Circular dependency" if @segments.include?(key)
      active_length = @active ? @active.length : (@root ? 1 : 0)
      raise RequirementError, "Evaluation dependency depth exceeded" if @segments.length + [active_length - 1, 0].max >= 256
      @segments << key
      begin
        yield
      ensure
        @segments.pop
      end
    end

    def remember(options, result)
      return unless options[:__featurevisor_prerequisite]

      identity = identity_of(options)
      pending = @pending_error
      @pending_error = nil
      return unless pending && pending[:identity] == identity && pending[:requester] == dependency_of

      key = fingerprint(identity, dependency_of, options)
      return unless key && key == pending[:key]
      borrowed = options[:dependency_purpose] == "composition"
      minimal = minimal_result(result, borrowed)
      (@memo ||= {})[key] = borrowed ? minimal : duplicate(minimal) if minimal
    end

    private

    def clear
      @root = @root_current = nil
      @active&.clear
      @memo&.clear
      @sticky_inputs&.clear
      @segments&.clear
      @active = nil
      @pending_error = nil
    end

    def identity_of(options)
      identity = {}
      identity[:type] = options[:type] unless options[:type].nil?
      identity[:feature_key] = options[:feature_key] unless options[:feature_key].nil?
      identity[:variable_key] = options[:variable_key] unless options[:variable_key].nil?
      identity
    end

    def fingerprint(identity, requester, options)
      @sticky_inputs ||= {}
      # Keep referenced maps alive until the root ends so object_id cannot be reused.
      [options[:sticky], options[:sticky_variables]].each do |input|
        @sticky_inputs[input.object_id] = input if input
      end
      JSON.generate(canonical([
        identity, requester, options[:dependency_purpose], options[:context], options[:sticky]&.object_id, options[:sticky_variables]&.object_id,
        options[:__featurevisor_generation]&.call,
        options[:__featurevisor_child_generation]&.call,
        options[:datafile]&.object_id
      ]))
    rescue ArgumentError, TypeError, JSON::GeneratorError
      nil
    end

    def canonical(value, ancestors = [])
      raise ArgumentError, "Too deep" if ancestors.length > 64

      case value
      when NilClass, TrueClass, FalseClass, String, Integer
        value
      when Float
        raise ArgumentError, "Nonfinite number" unless value.finite?
        value
      when Array
        raise ArgumentError, "Circular value" if ancestors.include?(value.object_id)
        ["array", value.map { |entry| canonical(entry, ancestors + [value.object_id]) }]
      when Hash
        raise ArgumentError, "Circular value" if ancestors.include?(value.object_id)
        keys = value.keys
        raise ArgumentError, "Unsupported key" unless keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
        pairs = keys.sort_by { |key| [key.to_s, key.is_a?(String) ? 0 : 1] }.map do |key|
          [key.is_a?(String) ? "string" : "symbol", key.to_s,
           canonical(value[key], ancestors + [value.object_id])]
        end
        ["object", pairs]
      else
        raise ArgumentError, "Unsupported value"
      end
    end

    def minimal_result(result, borrowed = false)
      return nil unless result.is_a?(Hash)

      keys = %i[type feature_key variable_key reason enabled variation_value variable_value __featurevisor_decoded_json]
      value = result.select { |key, _| keys.include?(key) }
      value[:variation] = { value: result[:variation][:value] } if result[:variation].is_a?(Hash)
      value[:variable_schema] = { type: result[:variable_schema][:type] } if result[:variable_schema].is_a?(Hash)
      if result[:variable].is_a?(Hash)
        value[:variable] = { type: result[:variable][:type] }
        value[:variable][:compose] = true if result[:variable][:compose]
      end
      return value if borrowed
      canonical(value)
      duplicate(value)
    rescue ArgumentError, TypeError
      nil
    end

    def duplicate(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
