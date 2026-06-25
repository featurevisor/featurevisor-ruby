# frozen_string_literal: true

require "securerandom"

module Featurevisor
  # Modules extend evaluation behavior and SDK lifecycle.
  module Modules
    class FeaturevisorModule
      attr_reader :id, :name

      def initialize(options = {})
        @id = SecureRandom.uuid
        @name = options[:name]
        @setup = options[:setup]
        @before = options[:before]
        @bucket_key = options[:bucket_key]
        @bucket_value = options[:bucket_value]
        @after = options[:after]
        @close = options[:close]
      end

      def call_setup(api)
        @setup.call(api) if @setup
      end

      def call_before(options)
        return options unless @before

        @before.call(options)
      end

      def call_bucket_key(options)
        return options[:bucket_key] unless @bucket_key

        @bucket_key.call(options)
      end

      def call_bucket_value(options)
        return options[:bucket_value] unless @bucket_value

        @bucket_value.call(options)
      end

      def call_after(evaluation, options)
        return evaluation unless @after

        @after.call(evaluation, options)
      end

      def call_close
        @close.call if @close
      end
    end

    class ModulesManager
      attr_reader :modules

      def initialize(options = {})
        @modules = []
        @report_diagnostic = options[:report_diagnostic]
        @module_api_factory = options[:module_api_factory]
        @clear_module_diagnostic_subscriptions = options[:clear_module_diagnostic_subscriptions]

        (options[:modules] || []).each do |mod|
          add(mod)
        end
      end

      def add(mod)
        mod = FeaturevisorModule.new(mod) if mod.is_a?(Hash)
        return nil unless mod

        if mod.name && !mod.name.to_s.empty? && @modules.any? { |existing| existing.name == mod.name }
          report(
            {
              level: "error",
              code: "duplicate_module",
              message: "Duplicate module name",
              module_name: mod.name
            },
            mod
          )
          return nil
        end

        mod.call_setup(@module_api_factory.call(mod)) if @module_api_factory
        @modules << mod

        -> { remove(mod) }
      end

      def remove(name_or_module)
        removed = []
        @modules = @modules.reject do |mod|
          matches = name_or_module.equal?(mod) || mod.name == name_or_module
          removed << mod if matches
          matches
        end

        removed.each do |mod|
          mod.call_close
          @clear_module_diagnostic_subscriptions.call(mod) if @clear_module_diagnostic_subscriptions
        end
      end

      def get_all
        @modules
      end

      def run_before_modules(options)
        @modules.reduce(options) do |result, mod|
          mod.call_before(result)
        end
      end

      def run_bucket_key_modules(options)
        bucket_key = options[:bucket_key]
        @modules.each do |mod|
          bucket_key = mod.call_bucket_key(options.merge(bucket_key: bucket_key))
        end
        bucket_key
      end

      def run_bucket_value_modules(options)
        bucket_value = options[:bucket_value]
        @modules.each do |mod|
          bucket_value = mod.call_bucket_value(options.merge(bucket_value: bucket_value))
        end
        bucket_value
      end

      def run_after_modules(evaluation, options)
        @modules.reduce(evaluation) do |result, mod|
          mod.call_after(result, options)
        end
      end

      def close_all
        @modules.each do |mod|
          mod.call_close
          @clear_module_diagnostic_subscriptions.call(mod) if @clear_module_diagnostic_subscriptions
        end
        @modules = []
      end

      private

      def report(diagnostic, mod)
        @report_diagnostic.call(diagnostic, mod) if @report_diagnostic
      end
    end
  end
end
