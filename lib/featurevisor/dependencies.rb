# frozen_string_literal: true

require "json"

module Featurevisor
  module Dependencies
    def self.extract_entity_dependencies(entry)
      sources = {}
      add = lambda do |kind, key, dependent|
        source = [kind, key.to_sym]
        sources[source] = true
      end
      conditions = nil
      conditions = lambda do |value, dependent|
        case value
        when String
          next if value == "*"
          if value.lstrip.match?(/\A[\{\[\"]/)
            begin
              conditions.call(JSON.parse(value, symbolize_names: true), dependent)
            rescue JSON::ParserError
              nil
            end
          else
            add.call(:segment, value, dependent)
          end
        when Array
          value.each { |child| conditions.call(child, dependent) }
        when Hash
          if value.key?(:variable)
            add.call(value[:feature] ? :feature : :variable, value[:feature] || value[:variable], dependent)
          elsif value.key?(:feature)
            add.call(:feature, value[:feature], dependent)
          elsif !value.key?(:attribute)
            %i[and or not].each { |group| conditions.call(value[group], dependent) if value.key?(group) }
          end
        end
      end
      visit = nil
      visit = lambda do |entry, dependent|
        conditions.call(entry[:conditions], dependent) if entry.key?(:conditions)
        %i[force traffic variations overrides overrideProgram].each do |name|
          (entry[name] || []).each { |child| visit.call(child, dependent) }
        end
        (entry[:variableOverrides] || {}).each_value do |overrides|
          overrides.each { |child| visit.call(child, dependent) }
        end
      end
      visit.call(entry, nil)
      compose = entry[:compose]
      if compose.is_a?(String)
        add.call(:variable, compose, nil)
      elsif compose.is_a?(Array)
        compose.each do |reference|
          add.call(reference[:feature] ? :feature : :variable, reference[:feature] || reference[:variable], nil)
        end
      end
      sources.keys
    end

    COLLECTIONS = { segments: :segment, features: :feature, variables: :variable }.freeze

    # Edge identities do not retain old providers, definitions or caller values.
    class Index
      EMPTY = [].freeze

      def initialize
        @reverse = {}
        @owners = {}
        @order = {}
        @next_order = 0
      end

      def update(datafile, incoming, previous = nil)
        updates = []
        COLLECTIONS.each do |name, kind|
          definitions = datafile[name] || {}
          (incoming[name] || {}).each_key do |key|
            owner = [kind, key.to_sym]
            entry = definitions[key.to_sym]
            # Hashes do not identify edges. Reuse only an identical definition.
            next if previous && @owners.key?(owner) && entry && entry == (previous[name] || {})[key.to_sym]
            updates << [owner, entry && Dependencies.extract_entity_dependencies(entry)]
          end
        end
        updates.each do |owner, sources|
          (@owners.delete(owner) || []).each do |source|
            dependents = @reverse[source]
            dependents.delete(owner)
            @reverse.delete(source) if dependents.empty?
          end
          unless sources
            @order.delete(owner)
            next
          end
          unless @order.key?(owner)
            @order[owner] = @next_order
            @next_order += 1
          end
          @owners[owner] = sources
          sources.each { |source| (@reverse[source] ||= {})[owner] = true }
        end
      end

      def reorder(datafile)
        @order = {}
        COLLECTIONS.each do |name, kind|
          (datafile[name] || {}).each_key.with_index { |key, rank| @order[[kind, key.to_sym]] = rank }
        end
        @next_order = (@order.values.max || -1) + 1
      end

      def dependents(identity)
        dependents = @reverse[identity]
        dependents ? dependents.keys.sort_by { |owner| @order.fetch(owner) } : EMPTY
      end
    end

    def self.create_index(datafile)
      index = Index.new
      index.update(datafile, datafile)
      index
    end

    def self.add_changes(features, variables, changed_segments, index)
      kinds = %i[feature variable segment]
      affected = [features, variables, changed_segments].map { |keys| keys.to_h { |key| [key.to_sym, true] } }
      queues = affected.map(&:keys)
      cursors = [0, 0, 0]
      loop do
        advanced = false
        kinds.each_with_index do |kind, source|
          next if cursors[source] >= queues[source].length
          advanced = true
          key = queues[source][cursors[source]]
          cursors[source] += 1
          index.dependents([kind, key]).each do |target_kind, target_key|
            target = kinds.index(target_kind)
            next if affected[target].key?(target_key)
            affected[target][target_key] = true
            queues[target] << target_key
          end
        end
        break unless advanced
      end
      features.replace(affected[0].keys)
      variables.replace(affected[1].keys)
    end
  end
end
