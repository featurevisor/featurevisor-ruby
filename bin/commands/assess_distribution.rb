require "json"
require "securerandom"
require "open3"
require_relative "runtime_project"

module FeaturevisorCLI
  module Commands
    class AssessDistribution
      include RuntimeProject
      # UUID_LENGTHS matches the TypeScript implementation
      UUID_LENGTHS = [4, 2, 2, 2, 6]

      def self.run(options)
        new(options).run
      end

      def initialize(options)
        @options = options
        @project_path = options.project_directory_path
      end

      def run
        # Validate required options
        unless @options.feature
          puts "Error: --feature is required for assess-distribution command"
          exit 1
        end

        context = parse_context

        each_project do
          targets = resolve_targets
          (targets.empty? ? [nil] : targets).each { |target| run_for_target(context, target) }
        end
      end

      private

      def run_for_target(context, target)
        puts "\nAssess Featurevisor distribution"
        puts "  Feature: #{@options.feature}"
        puts "  Environment: #{@options.environment}" if @options.environment
        puts "  Target: #{target}" if target
        puts "  Iterations: #{@options.n}"

        # Print context information
        if @options.context
          puts "Against context: #{@options.context}"
        else
          puts "Against context: {}"
        end

        puts "Running #{@options.n} times..."
        puts ""

        # Build datafile
        datafile = build_datafile(@options.environment, target)

        # Create SDK instance
        instance = create_featurevisor(datafile)

        # Check if feature has variations
        feature = instance.get_feature(@options.feature)
        has_variations = feature && feature[:variations] && feature[:variations].length > 0

        # Initialize evaluation counters
        flag_evaluations = {
          enabled: 0,
          disabled: 0
        }
        variation_evaluations = {}

        # Run evaluations
        @options.n.times do |i|
          # Create a copy of context for this iteration
          context_copy = context.dup

          # Populate UUIDs if requested
          if @options.populate_uuid.any?
            @options.populate_uuid.each do |key|
              context_copy[key.to_sym] = generate_uuid
            end
          end

          # Evaluate flag
          flag_evaluation = instance.is_enabled(@options.feature, context_copy)
          if flag_evaluation
            flag_evaluations[:enabled] += 1
          else
            flag_evaluations[:disabled] += 1
          end

          # Evaluate variation if feature has variations
          if has_variations
            variation_evaluation = instance.get_variation(@options.feature, context_copy)
            if variation_evaluation
              variation_value = variation_evaluation
              variation_evaluations[variation_value] ||= 0
              variation_evaluations[variation_value] += 1
            end
          end
        end

        # Print results
        puts "\nFlag evaluations:"
        print_counts(flag_evaluations, @options.n, true)

        if has_variations
          puts "\nVariation evaluations:"
          print_counts(variation_evaluations, @options.n, true)
        end
      end


      def parse_context
        if @options.context
          begin
            context = JSON.parse(@options.context)
            raise ArgumentError, "--context must be a JSON object" unless context.is_a?(Hash)
            # Convert string keys to symbols for the SDK
            context.transform_keys(&:to_sym)
          rescue JSON::ParserError => e
            puts "Error: Invalid JSON context: #{e.message}"
            exit 1
          end
        else
          {}
        end
      end


      def execute_command(command)
        stdout, stderr, exit_status = Open3.capture3(command)
        stdout.force_encoding(Encoding::UTF_8)
        stderr.force_encoding(Encoding::UTF_8)
        [stdout, stderr, exit_status.exitstatus]
      end

      def create_featurevisor(datafile)
        # Create SDK instance
        Featurevisor.create_featurevisor(
          datafile: datafile,
          log_level: get_logger_level
        )
      end

      def get_logger_level
        if @options.verbose
          "debug"
        elsif @options.quiet
          "error"
        else
          "warn"
        end
      end

      # Generate UUID string matching the TypeScript format
      def generate_uuid
        parts = UUID_LENGTHS.map do |length|
          SecureRandom.hex(length)
        end
        parts.join("-")
      end

      # Pretty number formatting (simple implementation)
      def pretty_number(n)
        n.to_s
      end

      # Pretty percentage formatting with 2 decimal places
      def pretty_percentage(count, total)
        if total == 0
          "0.00%"
        else
          percentage = (count.to_f / total * 100).round(2)
          "#{percentage}%"
        end
      end

      # Print evaluation counts in the same format as TypeScript
      def print_counts(evaluations, n, sort_results = true)
        # Convert to entries for sorting
        entries = evaluations.map { |value, count| { value: value, count: count } }

        # Sort by count descending if requested
        if sort_results
          entries.sort_by! { |entry| -entry[:count] }
        end

        # Print each entry
        entries.each do |entry|
          value_str = entry[:value].to_s
          count = entry[:count]
          puts "  - #{value_str}: #{pretty_number(count)} #{pretty_percentage(count, n)}"
        end
      end
    end
  end
end
