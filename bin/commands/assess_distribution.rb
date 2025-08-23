require "json"
require "securerandom"
require "open3"

module FeaturevisorCLI
  module Commands
    class AssessDistribution
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
        unless @options.environment
          puts "Error: --environment is required for assess-distribution command"
          exit 1
        end

        unless @options.feature
          puts "Error: --feature is required for assess-distribution command"
          exit 1
        end

        puts ""
        puts "Assessing distribution for feature: \"#{@options.feature}\"..."
        puts ""

        # Parse context if provided
        context = parse_context

        # Print context information
        if @options.context
          puts "Against context: #{@options.context}"
        else
          puts "Against context: {}"
        end

        puts "Running #{@options.n} times..."
        puts ""

        # Build datafile
        datafile = build_datafile(@options.environment)

        # Create SDK instance
        instance = create_instance(datafile)

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

      private

      def parse_context
        if @options.context
          begin
            context = JSON.parse(@options.context)
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

      def build_datafile(environment)
        puts "Building datafile for environment: #{environment}..."

        # Build the command similar to Go implementation
        command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--json"]

        if @options.schema_version
          command_parts << "--schemaVersion=#{@options.schema_version}"
        end

        if @options.inflate
          command_parts << "--inflate=#{@options.inflate}"
        end

        command = command_parts.join(" ")

        stdout, stderr, exit_status = execute_command(command)

        if exit_status != 0
          puts "Error: Command failed with exit code #{exit_status}"
          puts "Command: #{command}"
          puts "Stderr: #{stderr}"
          exit 1
        end

        begin
          JSON.parse(stdout, symbolize_names: true)
        rescue JSON::ParserError => e
          puts "Error: Failed to parse datafile JSON: #{e.message}"
          exit 1
        end
      end

      def execute_command(command)
        stdout, stderr, exit_status = Open3.capture3(command)
        [stdout, stderr, exit_status.exitstatus]
      end

      def create_instance(datafile)
        # Create SDK instance
        Featurevisor.create_instance(
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
