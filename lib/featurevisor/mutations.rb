# frozen_string_literal: true

module Featurevisor
  module Mutations
    DANGEROUS_KEYS = %w[__proto__ prototype constructor].freeze
    OPERATIONS = %w[set append prepend appendUnique removeValue before after remove].freeze
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    private_constant :DANGEROUS_KEYS, :OPERATIONS, :MAX_SAFE_INTEGER

    def self.apply(value, operations)
      raise ArgumentError, "Invalid variable mutation operations" unless operations.is_a?(Array)

      operations.reduce(value) do |current, operation|
        validate(operation)
        update_at_path(current, operation, 0)
      end
    end

    def self.validate(operation)
      unless operation.is_a?(Hash) && operation.key?(:op) && operation.key?(:path)
        raise ArgumentError, "Invalid variable mutation operation"
      end
      op = operation[:op]
      raise ArgumentError, "Invalid variable mutation operation" unless OPERATIONS.include?(op)
      if op != "remove" && !operation.key?(:value)
        raise ArgumentError, "Variable mutation operation requires a value"
      end
      if %w[appendUnique removeValue].include?(op)
        value = operation[:value]
        unless primitive?(value) && (!value.is_a?(Numeric) || !value.respond_to?(:finite?) || value.finite?)
          raise ArgumentError, "Variable mutation operation requires a primitive value"
        end
      end
      raise ArgumentError, "Invalid variable mutation path" unless operation[:path].is_a?(Array)

      operation[:path].each do |part|
        key = if part.is_a?(String)
                part
              elsif !array_index(part).nil?
                nil
              else
                select = selector(part)
                raise ArgumentError, "Invalid variable mutation path" unless select
                select[:property]
              end
        raise ArgumentError, "Unsafe variable mutation key" if key && DANGEROUS_KEYS.include?(key)
      end
    end
    private_class_method :validate

    def self.primitive?(value)
      value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end
    private_class_method :primitive?

    def self.same?(left, right)
      return true if left.nil? && right.nil?
      return left == right if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left == right if left.is_a?(String) && right.is_a?(String)
      return left == right if [true, false].include?(left) && [true, false].include?(right)

      left.equal?(right)
    end
    private_class_method :same?

    def self.array_index(value)
      return nil unless value.is_a?(Numeric)
      return nil if value.respond_to?(:finite?) && !value.finite?
      return nil unless value >= 0 && value <= MAX_SAFE_INTEGER && value.to_i == value

      value.to_i
    end
    private_class_method :array_index

    def self.selector(part)
      return nil unless part.is_a?(Hash)
      select = part[:select] || part["select"]
      return nil unless select.is_a?(Hash)
      property = select[:property] || select["property"]
      values = select[:values] || select["values"]
      return nil unless property.is_a?(String) && values.is_a?(Array) && values.all? { |value| primitive?(value) }

      { property: property, values: values }
    end
    private_class_method :selector

    def self.hash_key(hash, key)
      return key if hash.key?(key)
      symbol = key.to_sym
      hash.key?(symbol) ? symbol : symbol
    end
    private_class_method :hash_key

    def self.selected_index(array, select)
      array.each_with_index do |candidate, index|
        next unless candidate.is_a?(Hash)
        key = hash_key(candidate, select[:property])
        next unless candidate.key?(key)
        value = candidate[key]
        return index if primitive?(value) && select[:values].any? { |expected| same?(value, expected) }
      end
      -1
    end
    private_class_method :selected_index

    def self.path_key(container, part)
      if part.is_a?(String)
        raise ArgumentError, "Variable mutation expected an object" unless container.is_a?(Hash)
        return hash_key(container, part)
      end
      raise ArgumentError, "Variable mutation expected an array" unless container.is_a?(Array)

      index = array_index(part)
      return index unless index.nil?

      select = selector(part)
      raise ArgumentError, "Invalid variable mutation path" unless select

      selected_index(container, select)
    end
    private_class_method :path_key

    def self.exists?(container, key)
      container.is_a?(Hash) ? container.key?(key) : key >= 0 && key < container.length
    end
    private_class_method :exists?

    def self.replace(container, key, value)
      result = container.dup
      if result.is_a?(Array) && key == result.length
        result << value
      else
        result[key] = value
      end
      result
    end
    private_class_method :replace

    def self.update_array(array, op, item)
      if op == "removeValue"
        return array unless array.any? { |value| same?(value, item) }
        return array.reject { |value| same?(value, item) }
      end
      return array if op == "appendUnique" && array.any? { |value| same?(value, item) }

      op == "prepend" ? [item, *array] : [*array, item]
    end
    private_class_method :update_array

    def self.update_final(container, part, operation)
      return container if container.nil?
      op = operation[:op]
      if %w[before after].include?(op) && part.is_a?(String)
        raise ArgumentError, "Variable mutation before/after requires an array element path"
      end
      key = path_key(container, part)
      found = exists?(container, key)

      if op == "remove"
        return container unless found
        result = container.dup
        result.is_a?(Array) ? result.delete_at(key) : result.delete(key)
        return result
      end

      item = operation[:value]
      if op == "set"
        return container if key.is_a?(Integer) && (key.negative? || key > container.length)
        return container if found && same?(container[key], item)
        return replace(container, key, item)
      end
      if %w[before after].include?(op)
        return container unless found
        result = container.dup
        result.insert(key + (op == "after" ? 1 : 0), item)
        return result
      end

      current = found ? container[key] : nil
      return container if current.nil? && key.is_a?(Integer)
      return container if current.nil? && op == "removeValue"
      raise ArgumentError, "Variable mutation expected an array" if !current.nil? && !current.is_a?(Array)
      array = current || []
      result = update_array(array, op, item)
      result.equal?(current) ? container : replace(container, key, result)
    end
    private_class_method :update_final

    def self.update_at_path(value, operation, offset)
      path = operation[:path]
      if offset == path.length
        return same?(value, operation[:value]) ? value : operation[:value] if operation[:op] == "set"
        raise ArgumentError, "Cannot remove the root variable value" if operation[:op] == "remove"
        if %w[before after].include?(operation[:op])
          raise ArgumentError, "Variable mutation before/after requires an array element path"
        end
        return value if value.nil?
        raise ArgumentError, "Variable mutation expected an array" unless value.is_a?(Array)
        return update_array(value, operation[:op], operation[:value])
      end

      return update_final(value, path[offset], operation) if offset == path.length - 1
      return value if value.nil?
      key = path_key(value, path[offset])
      return value unless exists?(value, key)
      current = value[key]
      return value if current.nil?
      result = update_at_path(current, operation, offset + 1)
      result.equal?(current) ? value : replace(value, key, result)
    end
    private_class_method :update_at_path
  end
end
