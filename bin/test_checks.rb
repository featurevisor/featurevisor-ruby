require "json"
require "date"
require_relative "segment_tests"

module FeaturevisorCLI
  module TestChecks
    MISSING = Object.new.freeze
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    UNSAFE_PATH_PARTS = %w[__proto__ prototype constructor].freeze
    VALUELESS = %w[exists notExists isNull notNull empty notEmpty].freeze
    OPERATORS = (VALUELESS + %w[
      equals notEquals greaterThan greaterThanOrEquals lessThan lessThanOrEquals
      contains notContains startsWith endsWith matches notMatches semverEquals
      semverNotEquals semverGreaterThan semverGreaterThanOrEquals semverLessThan
      semverLessThanOrEquals before after in notIn includes notIncludes includesAny notIncludesAny
    ]).freeze

    class CheckError < StandardError; end

    module_function

    def evaluate(evaluator, datafile, checks, owner_variable:, diagnostics:, child_index: nil, segments: {}, context: {}, segment_matcher: nil)
      evaluate_result(
        evaluator,
        datafile,
        checks,
        owner_variable: owner_variable,
        diagnostics: diagnostics,
        child_index: child_index,
        segments: segments,
        context: context,
        segment_matcher: segment_matcher
      )[:failures]
    end

    def evaluate_result(evaluator, datafile, checks, owner_variable:, diagnostics:, child_index: nil, segments: {}, context: {}, segment_matcher: nil)
      unless checks.is_a?(Array) && !checks.empty?
        errors = [comparison_error("checks must be a nonempty array", "valid checks", checks, child_index: child_index)]
        return result_from_errors(errors, true)
      end

      resolver = Resolver.new(evaluator, datafile, diagnostics, owner_variable, segments, context, segment_matcher)
      begin
        validate_sibling_keys(checks, "checks")
      rescue CheckError => e
        errors = [comparison_error(e.message, "valid checks", checks, child_index: child_index)]
        return result_from_errors(errors, true)
      end
      validation_errors = checks.each_with_index.filter_map do |check, index|
        path = "checks[#{index}]"
        begin
          validate_node(check, owner_variable, path)
          nil
        rescue CheckError => e
          message = e.message.start_with?(path) ? e.message : "#{path}: #{e.message}"
          comparison_error(
            message,
            "valid check",
            check,
            check_index: index,
            check: check,
            child_index: child_index
          )
        end
      end
      unless validation_errors.empty?
        return result_from_errors(validation_errors, true)
      end
      begin
        checks.each_with_index do |check, index|
          preflight_node(check, datafile, owner_variable, segments, "checks[#{index}]")
        end
      rescue CheckError => e
        errors = [comparison_error(e.message, "valid references", checks, child_index: child_index)]
        return result_from_errors(errors, true)
      end

      has_error = false
      errors = checks.each_with_index.filter_map do |check, index|
        evaluated = []
        begin
          matched = evaluate_node(check, resolver, [index], evaluated)
          unless matched
            comparison_error(
              format_failed_check(check, evaluated),
              true,
              false,
              check_index: index,
              check: check,
              child_index: child_index,
              evaluated: evaluated
            )
          end
        rescue CheckError => e
          has_error = true
          comparison_error(
            e.message,
            "successful comparison",
            e.message,
            check_index: index,
            check: check,
            child_index: child_index,
            evaluated: evaluated
          )
        end
      end
      result_from_errors(errors, has_error)
    end

    def preflight!(datafile, checks, owner_variable:, segments: {})
      raise CheckError, "checks must be a nonempty array" unless checks.is_a?(Array) && !checks.empty?
      validate_sibling_keys(checks, "checks")
      checks.each_with_index { |check, index| validate_node(check, owner_variable, "checks[#{index}]") }
      checks.each_with_index do |check, index|
        preflight_node(check, datafile, owner_variable, segments, "checks[#{index}]")
      end
    end

    def result_from_errors(errors, has_error)
      { passed: errors.empty?, error: has_error, failures: errors.map { |error| error[:message] }, errors: errors }
    end

    def comparison_error(message, expected, actual, check_index: nil, check: nil, child_index: nil, evaluated: nil)
      details = {}
      details[:checkIndex] = check_index unless check_index.nil?
      details[:checkKey] = check[:key] if check.is_a?(Hash) && check.key?(:key)
      details[:checkDescription] = check[:description] if check.is_a?(Hash) && check.key?(:description)
      details[:evaluated] = evaluated if evaluated
      details[:childIndex] = child_index unless child_index.nil?
      { type: "check", message: message, expected: expected, actual: actual, details: details }
    end

    def validate_sibling_keys(nodes, path)
      seen = {}
      nodes.each_with_index do |node, index|
        next unless node.is_a?(Hash) && node.key?(:key)
        key = node[:key]
        raise CheckError, "#{path}[#{index}].key: key must be a nonempty string" unless key.is_a?(String) && !key.empty?
        if seen.key?(key)
          raise CheckError, "#{path}[#{index}].key: duplicate sibling key #{key.inspect}, first used at #{path}[#{seen[key]}]"
        end
        seen[key] = index
      end
    end

    def keyed(hash, key)
      return nil unless hash.is_a?(Hash)
      hash[key.to_sym] || hash[key.to_s]
    end

    def validate_reference_membership(reference, datafile, owner_variable, path)
      variable = reference[:variable] || owner_variable
      feature = reference[:feature]
      if feature
        definition = keyed(keyed(datafile, :features), feature)
        raise CheckError, "#{path}: feature #{feature.inspect} is absent from the selected datafile" unless definition.is_a?(Hash)
        variables = keyed(definition, :variablesSchema)
        unless keyed(variables, variable)
          raise CheckError, "#{path}: variable #{variable.inspect} is absent from feature #{feature.inspect} in the selected datafile"
        end
      elsif keyed(keyed(datafile, :variables), variable).nil?
        raise CheckError, "#{path}: global variable #{variable.inspect} is absent from the selected datafile"
      end
    end

    def preflight_node(node, datafile, owner_variable, segments, path)
      if segment_check?(node)
        definition = keyed(segments, node[:segment])
        unless definition.is_a?(Hash) && (definition.key?(:conditions) || definition.key?("conditions"))
          raise CheckError, "#{path}: segment #{node[:segment].inspect} definition is missing from the normalized test spec"
        end
        SegmentTests.references!(node[:segment], datafile, segments)
        return
      end
      %i[and or not].each do |group|
        next unless node.key?(group)
        node[group].each_with_index do |child, index|
          preflight_node(child, datafile, owner_variable, segments, "#{path}.#{group}[#{index}]")
        end
        return
      end
      if feature_check?(node)
        unless keyed(keyed(datafile, :features), node[:feature]).is_a?(Hash)
          raise CheckError, "#{path}: feature #{node[:feature].inspect} is absent from the selected datafile"
        end
        return
      end
      validate_reference_membership(node, datafile, owner_variable, path)
      validate_reference_membership(node[:compareTo], datafile, owner_variable, "#{path}.compareTo") if node.key?(:compareTo)
    end

    def validate_node(node, owner_variable, path)
      raise CheckError, "#{path}: check must be an object" unless node.is_a?(Hash)
      if node.key?(:key) && (!node[:key].is_a?(String) || node[:key].empty?)
        raise CheckError, "#{path}.key: key must be a nonempty string"
      end
      if node.key?(:description) && !node[:description].is_a?(String)
        raise CheckError, "#{path}.description: description must be a string"
      end
      if segment_check?(node)
        validate_segment_check(node, path)
        return
      end
      groups = %i[and or not].select { |key| node.key?(key) }
      unless groups.empty?
        allowed = [groups.first, :key, :description]
        unknown = node.keys.find { |key| !allowed.include?(key) }
        unless groups.length == 1 && unknown.nil?
          raise CheckError, "#{path}: group must contain exactly one of and, or or not plus optional key and description"
        end
        children = node[groups.first]
        raise CheckError, "#{path}.#{groups.first}: group must be a nonempty array" unless children.is_a?(Array) && !children.empty?
        validate_sibling_keys(children, "#{path}.#{groups.first}")
        children.each_with_index { |child, index| validate_node(child, owner_variable, "#{path}.#{groups.first}[#{index}]") }
        return
      end
      if feature_check?(node)
        validate_feature_check(node, path)
        return
      end
      operator = node[:operator]
      allowed = %i[variable feature path operator value compareTo regexFlags key description]
      unknown = node.keys.find { |key| !allowed.include?(key) }
      raise CheckError, "#{path}: unknown check property #{unknown.inspect}" if unknown
      raise CheckError, "#{path}: unknown check operator #{operator.inspect}" unless OPERATORS.include?(operator)
      if node.key?(:feature) && (!node[:feature].is_a?(String) || node[:feature].empty?)
        raise CheckError, "#{path}: feature must be a nonempty string"
      end
      if node.key?(:variable) && (!node[:variable].is_a?(String) || node[:variable].empty?)
        raise CheckError, "#{path}: variable must be a nonempty string"
      end
      raise CheckError, "#{path}: a feature reference requires an explicit variable" if node.key?(:feature) && !node.key?(:variable)
      raise CheckError, "#{path}: variable reference requires an explicit variable" unless node[:variable] || owner_variable
      raise CheckError, "#{path}: path must not be null" if node.key?(:path) && node[:path].nil?
      path_parts(node[:path])
      supplied = (node.key?(:value) ? 1 : 0) + (node.key?(:compareTo) ? 1 : 0)
      if VALUELESS.include?(operator)
        raise CheckError, "#{path}: operator #{operator.inspect} accepts neither value nor compareTo" unless supplied.zero?
      elsif supplied != 1
        raise CheckError, "#{path}: exactly one of value or compareTo is required"
      end
      validate_literal(node, path) if node.key?(:value)
      if node.key?(:regexFlags) && !%w[matches notMatches].include?(operator)
        raise CheckError, "#{path}: regexFlags are only allowed with matches or notMatches"
      end
      portable_regex_flags(node[:regexFlags], allow_nil: false) if node.key?(:regexFlags)
      return unless node.key?(:compareTo)
      other = node[:compareTo]
      raise CheckError, "#{path}.compareTo: reference must be an object" unless other.is_a?(Hash)
      if other.key?(:feature) && (!other[:feature].is_a?(String) || other[:feature].empty?)
        raise CheckError, "#{path}.compareTo: feature must be a nonempty string"
      end
      if other.key?(:variable) && (!other[:variable].is_a?(String) || other[:variable].empty?)
        raise CheckError, "#{path}.compareTo: variable must be a nonempty string"
      end
      raise CheckError, "#{path}.compareTo: a feature reference requires an explicit variable" if other.key?(:feature) && !other.key?(:variable)
      raise CheckError, "#{path}.compareTo: variable reference requires an explicit variable" unless other[:variable] || owner_variable
      unknown = other.keys.find { |key| !%i[variable feature path].include?(key) }
      raise CheckError, "#{path}.compareTo: unknown reference property #{unknown.inspect}" if unknown
      raise CheckError, "#{path}.compareTo: path must not be null" if other.key?(:path) && other[:path].nil?
      path_parts(other[:path])
    end

    def feature_check?(node)
      node.key?(:enabled) || node.key?(:variation) ||
        (node.key?(:feature) && !node.key?(:variable) && !node.key?(:operator))
    end

    def segment_check?(node)
      node.key?(:segment) || node.key?(:matches)
    end

    def validate_segment_check(node, path)
      unknown = node.keys.find { |key| !%i[segment matches key description].include?(key) }
      raise CheckError, "#{path}: segment check cannot contain property #{unknown.inspect}" if unknown
      unless node[:segment].is_a?(String) && !node[:segment].empty?
        raise CheckError, "#{path}: segment check requires a nonempty segment"
      end
      unless node.key?(:matches) && [true, false].include?(node[:matches])
        raise CheckError, "#{path}: segment #{node[:segment].inspect} matches must be a boolean"
      end
    end

    def validate_feature_check(node, path)
      unknown = node.keys.find { |key| !%i[feature enabled variation key description].include?(key) }
      raise CheckError, "#{path}: feature check cannot contain property #{unknown.inspect}" if unknown
      unless node[:feature].is_a?(String) && !node[:feature].empty?
        raise CheckError, "#{path}: feature must be a nonempty string"
      end
      unless node.key?(:enabled) || node.key?(:variation)
        raise CheckError, "#{path}: feature check requires enabled or variation"
      end
      if node.key?(:enabled) && ![true, false].include?(node[:enabled])
        raise CheckError, "#{path}: enabled must be a boolean"
      end
      if node.key?(:variation) && !node[:variation].nil? && !node[:variation].is_a?(String)
        raise CheckError, "#{path}: variation must be a string or null"
      end
    end

    def validate_literal(node, path)
      operator = node[:operator]
      value = node[:value]
      numeric = %w[greaterThan greaterThanOrEquals lessThan lessThanOrEquals]
      strings = %w[contains notContains startsWith endsWith matches notMatches semverEquals semverNotEquals semverGreaterThan semverGreaterThanOrEquals semverLessThan semverLessThanOrEquals before after]
      if %w[equals notEquals].include?(operator) && !primitive?(value)
        raise CheckError, "#{path}: operator #{operator.inspect} requires a scalar value"
      elsif numeric.include?(operator) && (!value.is_a?(Numeric) || !value.finite?)
        raise CheckError, "#{path}: operator #{operator.inspect} requires a numeric value"
      elsif strings.include?(operator) && !value.is_a?(String)
        raise CheckError, "#{path}: operator #{operator.inspect} requires a string value"
      elsif %w[in notIn].include?(operator) && (!value.is_a?(Array) || !value.all? { |item| membership_primitive?(item) })
        raise CheckError, "#{path}: operator #{operator.inspect} requires an array of string, number or null values"
      elsif %w[includes notIncludes].include?(operator) && !membership_primitive?(value)
        raise CheckError, "#{path}: operator #{operator.inspect} requires a scalar value"
      elsif %w[includesAny notIncludesAny].include?(operator) && (!value.is_a?(Array) || !value.all? { |item| primitive?(item) })
        raise CheckError, "#{path}: operator #{operator.inspect} requires an array of primitive values"
      end
      portable_regex(value, node[:regexFlags]) if %w[matches notMatches].include?(operator)
      portable_datetime(value) if %w[before after].include?(operator)
      Featurevisor.compare_versions(value, value) if operator.start_with?("semver")
    rescue TypeError, ArgumentError => e
      raise CheckError, e.message
    end

    def evaluate_node(node, resolver, path, evaluated)
      %i[and or not].each do |group|
        next unless node.key?(group)
        if %i[and not].include?(group)
          node[group].each_with_index do |child, index|
            matched = evaluate_node(child, resolver, path + [group.to_s, index], evaluated)
            return group == :not unless matched
          end
          return group != :not
        end
        node[group].each_with_index do |child, index|
          matched = evaluate_node(child, resolver, path + [group.to_s, index], evaluated)
          return true if matched
        end
        return false
      end

      return evaluate_segment_check(node, resolver, path, evaluated) if segment_check?(node)
      return evaluate_feature_check(node, resolver, path, evaluated) if feature_check?(node)

      left_ref = node.select { |key, _| %i[variable feature path].include?(key) }
      trace = {
        path: path,
        reference: normalized_reference(left_ref, resolver.owner_variable),
        operator: node[:operator],
        actual: missing_value,
        expected: node.key?(:compareTo) ? missing_value : report_operand(node.key?(:value) ? node[:value] : MISSING)
      }
      trace[:key] = node[:key] if node.key?(:key)
      trace[:description] = node[:description] if node.key?(:description)
      if node.key?(:compareTo)
        trace[:compareTo] = normalized_reference(node[:compareTo], resolver.owner_variable)
      end
      evaluated << trace
      begin
        left = resolver.resolve(left_ref)
      rescue CheckError => e
        raise CheckError, "#{format_path(path)} left operand (#{reference_label(left_ref, resolver.owner_variable)}): #{e.message}"
      end
      trace[:actual] = report_operand(left)
      trace[:actualMissing] = true if left.equal?(MISSING)
      if node.key?(:compareTo)
        right_ref = node[:compareTo]
        begin
          right = resolver.resolve(right_ref)
        rescue CheckError => e
          raise CheckError, "#{format_path(path)} compareTo operand (#{reference_label(right_ref, resolver.owner_variable)}): #{e.message}"
        end
      else
        right = node.key?(:value) ? node[:value] : MISSING
      end
      trace[:expected] = report_operand(right)
      trace[:expectedMissing] = true if node.key?(:compareTo) && right.equal?(MISSING)
      compare(node[:operator], left, right, node[:regexFlags])
    end

    def evaluate_feature_check(node, resolver, path, evaluated)
      feature = node[:feature]
      matched = true
      if node.key?(:enabled)
        matched = evaluate_feature_property(node, resolver, path, evaluated, :enabled) && matched
      end
      if node.key?(:variation)
        matched = evaluate_feature_property(node, resolver, path, evaluated, :variation) && matched
      end
      matched
    end

    def evaluate_segment_check(node, resolver, path, evaluated)
      trace = {
        path: path,
        reference: { segment: node[:segment] },
        property: "matches",
        operator: "equals",
        actual: missing_value,
        expected: node[:matches]
      }
      trace[:key] = node[:key] if node.key?(:key)
      trace[:description] = node[:description] if node.key?(:description)
      evaluated << trace
      actual = resolver.resolve_segment(node[:segment])
      trace[:actual] = actual
      actual == node[:matches]
    end

    def evaluate_feature_property(node, resolver, path, evaluated, property)
      trace = {
        path: path,
        reference: { feature: node[:feature] },
        property: property.to_s,
        operator: "equals",
        actual: missing_value,
        expected: node[property]
      }
      trace[:key] = node[:key] if node.key?(:key)
      trace[:description] = node[:description] if node.key?(:description)
      evaluated << trace
      actual = resolver.resolve_feature(node[:feature], property)
      trace[:actual] = report_operand(actual)
      strict_equal(actual, node[property])
    end

    def normalized_reference(reference, owner_variable)
      normalized = { variable: reference[:variable] || owner_variable }
      normalized[:feature] = reference[:feature] if reference.key?(:feature)
      normalized[:path] = reference[:path] if reference.key?(:path)
      normalized.delete(:variable) if normalized[:variable].nil?
      normalized
    end

    def missing_value
      { "$type" => "undefined" }
    end

    def report_operand(value)
      value.equal?(MISSING) ? missing_value : value
    end

    def format_path(path)
      path.each_with_index.map { |part, index| index.zero? ? "checks[#{part}]" : part.is_a?(Integer) ? "[#{part}]" : ".#{part}" }.join
    end

    def format_failed_check(check, evaluated)
      label = check_label(format_path([evaluated.first&.dig(:path)&.first || 0]), check)
      if evaluated.all? { |trace| trace.dig(:reference, :segment) }
        evidence = evaluated.map do |trace|
          "segment #{trace.dig(:reference, :segment).inspect}: expected matches=#{json(trace[:expected])}, actual matches=#{json(trace[:actual])}"
        end
        return "#{label}: segment expectations failed (#{evidence.join(', ')})"
      end
      if evaluated.all? { |trace| trace.dig(:reference, :feature) }
        evidence = evaluated.map do |trace|
          "expected #{trace[:property]}=#{json(trace[:expected])}, actual #{trace[:property]}=#{json(trace[:actual])}"
        end
        return "#{label}: feature #{evaluated.first.dig(:reference, :feature).inspect} expectations failed (#{evidence.join(', ')})"
      end
      if evaluated.all? { |trace| trace[:property] }
        evidence = evaluated.map do |trace|
          kind = trace.dig(:reference, :segment) ? "segment" : "feature"
          reference = trace.dig(:reference, :segment) || trace.dig(:reference, :feature)
          "#{kind} #{reference.inspect}: expected #{trace[:property]}=#{json(trace[:expected])}, actual #{trace[:property]}=#{json(trace[:actual])}"
        end
        return "#{label}: expectations failed (#{evidence.join(', ')})"
      end
      evidence = evaluated.map do |trace|
        reference = reference_label(trace[:reference], nil)
        "#{reference} #{trace[:operator]} failed (left=#{json(trace[:actual])}, right=#{json(trace[:expected])})"
      end
      "#{label}: #{evidence.join('; ')}"
    end

    def check_label(path, node)
      metadata = []
      metadata << "key=#{node[:key].inspect}" if node.key?(:key)
      metadata << "description=#{node[:description].inspect}" if node.key?(:description)
      metadata.empty? ? path : "#{path} [#{metadata.join(', ')}]"
    end

    def path_parts(path)
      return [] if path.nil?
      if path.is_a?(String)
        parts = path.split(".", -1)
        raise CheckError, "path must not contain empty dot components" if parts.any?(&:empty?)
        parts = parts.map do |part|
          if part.match?(/\A(?:0|[1-9]\d*)\z/)
            index = Integer(part, 10)
            raise CheckError, "path indices must be safe nonnegative integers" if index > MAX_SAFE_INTEGER
            index
          else
            part
          end
        end
      elsif path.is_a?(Array)
        parts = path
      else
        raise CheckError, "path must be a dot separated string or an array"
      end
      parts.each do |part|
        unless part.is_a?(String) || (part.is_a?(Integer) && part.between?(0, MAX_SAFE_INTEGER))
          raise CheckError, "path entries must be string keys or nonnegative integer indices"
        end
        raise CheckError, "unsafe path segment #{part.inspect} is not allowed" if part.is_a?(String) && UNSAFE_PATH_PARTS.include?(part)
        raise CheckError, "wildcards are not allowed in paths" if part == "*"
      end
      parts
    end

    def at_path(value, parts)
      parts.reduce(value) do |current, part|
        if part.is_a?(Integer)
          return MISSING unless current.is_a?(Array) && part < current.length
          current[part]
        else
          if current.is_a?(Array)
            if part == "length"
              current.length
            elsif part.match?(/\A(?:0|[1-9]\d*)\z/) && part.to_i < current.length
              current[part.to_i]
            else
              return MISSING
            end
          elsif current.is_a?(Hash)
            key = current.key?(part) ? part : part.to_sym
            return MISSING unless current.key?(key)
            current[key]
          else
            return MISSING
          end
        end
      end
    end

    def primitive?(value)
      value.nil? || value.is_a?(String) || value == true || value == false ||
        (value.is_a?(Numeric) && value.finite?)
    end

    def membership_primitive?(value)
      value.nil? || value.is_a?(String) || (value.is_a?(Numeric) && value.finite?)
    end

    def strict_equal(left, right)
      return left.nil? && right.nil? if left.nil? || right.nil?
      return left == right if [true, false].include?(left) && [true, false].include?(right)
      return left == right if left.is_a?(Numeric) && right.is_a?(Numeric) && left.finite? && right.finite?
      left.is_a?(String) && right.is_a?(String) && left == right
    end

    def compare(operator, left, right, regex_flags)
      return !left.equal?(MISSING) if operator == "exists"
      return left.equal?(MISSING) if operator == "notExists"
      return left.nil? if operator == "isNull"
      return !left.equal?(MISSING) && !left.nil? if operator == "notNull"
      if %w[empty notEmpty].include?(operator)
        return false if left.equal?(MISSING) || left.nil?
        unless left.is_a?(String) || left.is_a?(Array) || left.is_a?(Hash)
          raise CheckError, "operator #{operator.inspect} requires a string, array or object operand"
        end
        return operator == "empty" ? left.empty? : !left.empty?
      end
      return false if left.equal?(MISSING) || right.equal?(MISSING)
      if %w[equals notEquals].include?(operator)
        raise CheckError, "operator #{operator.inspect} only supports scalar values" unless primitive?(left) && primitive?(right)
        matched = strict_equal(left, right)
        return operator == "equals" ? matched : !matched
      end
      if %w[greaterThan greaterThanOrEquals lessThan lessThanOrEquals].include?(operator)
        unless left.is_a?(Numeric) && right.is_a?(Numeric) && ![left, right].any? { |value| [true, false].include?(value) } && left.finite? && right.finite?
          raise CheckError, "operator #{operator.inspect} requires numeric operands"
        end
        return { "greaterThan" => left > right, "greaterThanOrEquals" => left >= right,
                 "lessThan" => left < right, "lessThanOrEquals" => left <= right }[operator]
      end
      if %w[contains notContains startsWith endsWith matches notMatches].include?(operator)
        raise CheckError, "operator #{operator.inspect} requires string operands" unless left.is_a?(String) && right.is_a?(String)
        return left.include?(right) if operator == "contains"
        return !left.include?(right) if operator == "notContains"
        return left.start_with?(right) if operator == "startsWith"
        return left.end_with?(right) if operator == "endsWith"
        matched = !portable_regex(right, regex_flags).match(left).nil?
        return operator == "matches" ? matched : !matched
      end
      if operator.start_with?("semver")
        raise CheckError, "operator #{operator.inspect} requires string operands" unless left.is_a?(String) && right.is_a?(String)
        compared = Featurevisor.compare_versions(left, right)
        return { "semverEquals" => compared == 0, "semverNotEquals" => compared != 0,
                 "semverGreaterThan" => compared == 1, "semverGreaterThanOrEquals" => compared >= 0,
                 "semverLessThan" => compared == -1, "semverLessThanOrEquals" => compared <= 0 }[operator]
      end
      if %w[before after].include?(operator)
        begin
          left_date = portable_datetime(left)
          right_date = portable_datetime(right)
        rescue TypeError, ArgumentError => e
          raise CheckError, "date comparisons require valid portable timestamps: #{e.message}"
        end
        return operator == "before" ? left_date < right_date : left_date > right_date
      end
      if %w[in notIn].include?(operator)
        unless membership_primitive?(left) && right.is_a?(Array) && right.all? { |value| membership_primitive?(value) }
          raise CheckError, "operator #{operator.inspect} requires a scalar left operand and scalar array right operand"
        end
        matched = right.any? { |value| strict_equal(left, value) }
        return operator == "in" ? matched : !matched
      end
      if %w[includesAny notIncludesAny].include?(operator)
        unless left.is_a?(Array) && right.is_a?(Array) && right.all? { |value| primitive?(value) }
          raise CheckError, "operator #{operator.inspect} requires an array left operand and primitive array right operand"
        end
        matched = right.any? { |candidate| left.any? { |actual| strict_equal(actual, candidate) } }
        return operator == "includesAny" ? matched : !matched
      end
      if %w[includes notIncludes].include?(operator)
        unless left.is_a?(Array) && membership_primitive?(right)
          raise CheckError, "operator #{operator.inspect} requires an array left operand and scalar right operand"
        end
        matched = left.any? { |value| strict_equal(value, right) }
        return operator == "includes" ? matched : !matched
      end
      raise CheckError, "unknown check operator #{operator.inspect}"
    rescue ArgumentError => e
      raise CheckError, e.message
    end

    def portable_regex(pattern, flags)
      flags = portable_regex_flags(flags)
      if pattern.match?(/\(\?/) || pattern.match?(/\\(?:[1-9]|k<|k'|g<|g')/) || pattern.match?(/(?:[?*+]|\{\d+(?:,\d*)?\})\+/)
        raise CheckError, "regular expression uses syntax outside the portable subset"
      end
      native = 0
      native |= Regexp::IGNORECASE if flags.include?("i")
      native |= Regexp::MULTILINE if flags.include?("s")
      Regexp.new(pattern, native)
    rescue RegexpError => e
      raise CheckError, "invalid regular expression: #{e.message}"
    end

    def portable_regex_flags(flags, allow_nil: true)
      flags = "" if flags.nil? && allow_nil
      unless flags.is_a?(String) && flags.match?(/\A[gims]*\z/) && flags.chars.uniq.length == flags.length
        raise CheckError, "regexFlags must contain unique characters from g, i, m and s"
      end
      flags
    end

    def portable_datetime(value)
      match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})\z/.match(value)
      raise CheckError, "date comparisons require valid portable timestamps" unless match

      year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
      unless year.between?(1, 9999) && Date.valid_date?(year, month, day) &&
             hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)
        raise CheckError, "date comparisons require valid portable timestamps"
      end

      zone = match[8]
      offset = 0
      unless zone == "Z"
        offset_hour, offset_minute = zone[1..].split(":").map(&:to_i)
        unless offset_hour <= 14 && offset_minute <= 59 && (offset_hour < 14 || offset_minute.zero?)
          raise CheckError, "date comparisons require valid portable timestamps"
        end
        offset = (offset_hour * 3_600) + (offset_minute * 60)
        offset = -offset if zone.start_with?("-")
      end

      fraction = match[7] ? Rational(match[7][0, 3].ljust(3, "0").to_i, 1_000) : 0
      instant = Date.new(year, month, day, Date::GREGORIAN).jd * 86_400 + hour * 3_600 + minute * 60 + second + fraction - offset
      minimum = Date.new(1, 1, 1, Date::GREGORIAN).jd * 86_400
      maximum = Date.new(9999, 12, 31, Date::GREGORIAN).jd * 86_400 + 86_399 + Rational(999, 1_000)
      raise CheckError, "date comparisons require valid portable timestamps" unless instant.between?(minimum, maximum)
      instant
    rescue TypeError
      raise CheckError, "date comparisons require valid portable timestamps"
    end

    def json(value)
      return "<missing>" if value.equal?(MISSING)
      JSON.generate(value)
    rescue JSON::GeneratorError
      value.inspect
    end

    def reference_label(reference, owner_variable)
      variable = reference[:variable] || owner_variable || "<missing variable>"
      root = reference[:feature] ? "#{reference[:feature]}.#{variable}" : variable
      reference[:path].nil? || reference[:path] == [] ? root : "#{root}:#{json(reference[:path])}"
    end

    class Resolver
      attr_reader :owner_variable

      def initialize(evaluator, datafile, diagnostics, owner_variable, segments, context, segment_matcher)
        @evaluator = evaluator
        @datafile = datafile
        @diagnostics = diagnostics
        @owner_variable = owner_variable
        @segments = segments.is_a?(Hash) ? segments : {}
        @context = context.is_a?(Hash) ? context : {}
        @segment_matcher = segment_matcher
      end

      def resolve(reference)
        variable = reference[:variable] || @owner_variable
        feature = reference[:feature]
        raise CheckError, "variable reference requires a nonempty variable" unless variable.is_a?(String) && !variable.empty?
        if feature
          raise CheckError, "feature reference requires a nonempty feature" unless feature.is_a?(String) && !feature.empty?
          definition = (@datafile[:features] || {})[feature.to_sym]
          raise CheckError, "feature #{feature.inspect} is absent from the selected datafile" unless definition.is_a?(Hash)
          unless (definition[:variablesSchema] || {}).key?(variable.to_sym)
            raise CheckError, "variable #{variable.inspect} is absent from feature #{feature.inspect} in the selected datafile"
          end
        elsif !(@datafile[:variables] || {}).key?(variable.to_sym)
          raise CheckError, "global variable #{variable.inspect} is absent from the selected datafile"
        end
        @diagnostics.clear
        value = feature ? @evaluator.get_variable(feature, variable, {}) : @evaluator.get_variable(variable, {})
        diagnostic = @diagnostics.find { |item| (item[:level] || item["level"]).to_s == "error" }
        if diagnostic
          raise CheckError, "variable getter reported #{diagnostic[:code] || diagnostic["code"] || "an error"}: " \
                            "#{diagnostic[:message] || diagnostic["message"] || "evaluation failed"}"
        end
        TestChecks.at_path(value, TestChecks.path_parts(reference[:path]))
      rescue CheckError
        raise
      rescue => e
        raise CheckError, "variable getter failed: #{e.message}"
      end

      def resolve_feature(feature, getter)
        definition = (@datafile[:features] || {})[feature.to_sym]
        raise CheckError, "feature #{feature.inspect} is absent from the selected datafile" unless definition.is_a?(Hash)
        @diagnostics.clear
        value = getter == :enabled ? @evaluator.is_enabled(feature, {}) : @evaluator.get_variation(feature, {})
        diagnostic = @diagnostics.find { |item| (item[:level] || item["level"]).to_s == "error" }
        if diagnostic
          raise CheckError, "feature #{feature.inspect} #{getter} getter reported #{diagnostic[:code] || diagnostic["code"] || "an error"}: " \
                            "#{diagnostic[:message] || diagnostic["message"] || "evaluation failed"}"
        end
        value
      rescue CheckError
        raise
      rescue => e
        raise CheckError, "feature #{feature.inspect} #{getter} getter failed: #{e.message}"
      end

      def resolve_segment(segment)
        definition = @segments[segment.to_sym] || @segments[segment]
        unless definition.is_a?(Hash) && (definition.key?(:conditions) || definition.key?("conditions"))
          raise CheckError, "segment #{segment.inspect} definition is missing from the normalized test spec"
        end
        raise CheckError, "segment #{segment.inspect} cannot be evaluated" unless @segment_matcher.respond_to?(:call)
        @segment_matcher.call(segment, @context)
      rescue CheckError
        raise
      rescue => e
        raise CheckError, "segment #{segment.inspect} evaluation failed: #{e.message}"
      end
    end
  end
end
