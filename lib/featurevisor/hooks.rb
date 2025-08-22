# frozen_string_literal: true

module Featurevisor
  # Hooks module for extending evaluation behavior
  module Hooks
    # Hook interface for extending evaluation behavior
    class Hook
      attr_reader :name

      # Initialize a new hook
      # @param options [Hash] Hook options
      # @option options [String] :name Hook name
      # @option options [Proc, nil] :before Before evaluation hook
      # @option options [Proc, nil] :bucket_key Bucket key configuration hook
      # @option options [Proc, nil] :bucket_value Bucket value configuration hook
      # @option options [Proc, nil] :after After evaluation hook
      def initialize(options)
        @name = options[:name]
        @before = options[:before]
        @bucket_key = options[:bucket_key]
        @bucket_value = options[:bucket_value]
        @after = options[:after]
      end

      # Call the before hook if defined
      # @param options [Hash] Evaluation options
      # @return [Hash] Modified evaluation options
      def call_before(options)
        return options unless @before

        @before.call(options)
      end

      # Call the bucket key hook if defined
      # @param options [Hash] Bucket key options
      # @return [String] Modified bucket key
      def call_bucket_key(options)
        return options[:bucket_key] unless @bucket_key

        @bucket_key.call(options)
      end

      # Call the bucket value hook if defined
      # @param options [Hash] Bucket value options
      # @return [Integer] Modified bucket value
      def call_bucket_value(options)
        return options[:bucket_value] unless @bucket_value

        @bucket_value.call(options)
      end

      # Call the after hook if defined
      # @param evaluation [Hash] Evaluation result
      # @param options [Hash] Evaluation options
      # @return [Hash] Modified evaluation result
      def call_after(evaluation, options)
        return evaluation unless @after

        @after.call(evaluation, options)
      end
    end

    # HooksManager class for managing hooks
    class HooksManager
      attr_reader :hooks, :logger

      # Initialize a new HooksManager
      # @param options [Hash] Options hash containing hooks and logger
      # @option options [Array<Hook>] :hooks Array of hooks
      # @option options [Logger] :logger Logger instance
      def initialize(options)
        @logger = options[:logger]
        @hooks = []

        if options[:hooks]
          options[:hooks].each do |hook|
            add(hook)
          end
        end
      end

      # Add a hook to the manager
      # @param hook [Hook] Hook to add
      # @return [Proc, nil] Remove function or nil if hook already exists
      def add(hook)
        if @hooks.any? { |existing_hook| existing_hook.name == hook.name }
          @logger.error("Hook with name \"#{hook.name}\" already exists.", {
            name: hook.name,
            hook: hook
          })

          return nil
        end

        @hooks << hook

        # Return a remove function
        -> { remove(hook.name) }
      end

      # Remove a hook by name
      # @param name [String] Hook name to remove
      def remove(name)
        @hooks = @hooks.reject { |hook| hook.name == name }
      end

      # Get all hooks
      # @return [Array<Hook>] Array of all hooks
      def get_all
        @hooks
      end

      # Run before hooks
      # @param options [Hash] Evaluation options
      # @return [Hash] Modified evaluation options
      def run_before_hooks(options)
        result = options
        @hooks.each do |hook|
          result = hook.call_before(result)
        end
        result
      end

      # Run bucket key hooks
      # @param options [Hash] Bucket key options
      # @return [String] Modified bucket key
      def run_bucket_key_hooks(options)
        bucket_key = options[:bucket_key]
        @hooks.each do |hook|
          bucket_key = hook.call_bucket_key(options.merge(bucket_key: bucket_key))
        end
        bucket_key
      end

      # Run bucket value hooks
      # @param options [Hash] Bucket value options
      # @return [Integer] Modified bucket value
      def run_bucket_value_hooks(options)
        bucket_value = options[:bucket_value]
        @hooks.each do |hook|
          bucket_value = hook.call_bucket_value(options.merge(bucket_value: bucket_value))
        end
        bucket_value
      end

      # Run after hooks
      # @param evaluation [Hash] Evaluation result
      # @param options [Hash] Evaluation options
      # @return [Hash] Modified evaluation result
      def run_after_hooks(evaluation, options)
        result = evaluation
        @hooks.each do |hook|
          result = hook.call_after(result, options)
        end
        result
      end
    end
  end
end
