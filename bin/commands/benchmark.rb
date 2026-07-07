require "benchmark"
require "json"
require "time"
require "open3"

module FeaturevisorCLI
  module Commands
    class Benchmark
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
          puts "Error: --environment is required for benchmark command"
          exit 1
        end

        unless @options.feature
          puts "Error: --feature is required for benchmark command"
          exit 1
        end

        puts ""
        puts "Running benchmark for feature \"#{@options.feature}\"..."
        puts ""

        # Parse context if provided
        context = parse_context

        puts "Building datafile containing all features for \"#{@options.environment}\"..."
        datafile_build_start = Time.now

        # Build datafile by executing the featurevisor build command
        datafile = build_datafile(@options.environment)
        datafile_build_duration = Time.now - datafile_build_start
        datafile_build_duration_ms = (datafile_build_duration * 1000).round

        puts "Datafile build duration: #{datafile_build_duration_ms}ms"

        # Calculate datafile size
        datafile_size = datafile.to_json.bytesize
        puts "Datafile size: #{(datafile_size / 1024.0).round(2)} kB"

        # Create SDK instance with the datafile
        instance = create_instance(datafile)
        puts "...SDK initialized"

        puts ""
        puts "Against context: #{context.to_json}"

        # Run the appropriate benchmark
        if @options.variation
          puts "Evaluating variation #{@options.n} times..."
          output = benchmark_feature_variation(instance, @options.feature, context, @options.n)
        elsif @options.variable
          puts "Evaluating variable \"#{@options.variable}\" #{@options.n} times..."
          output = benchmark_feature_variable(instance, @options.feature, @options.variable, context, @options.n)
        else
          puts "Evaluating flag #{@options.n} times..."
          output = benchmark_feature_flag(instance, @options.feature, context, @options.n)
        end

        puts ""

        # Format the value output to match Go behavior
        value_output = format_value(output[:value])
        puts "Evaluated value : #{value_output}"
        puts "Total duration  : #{pretty_duration(output[:duration])}"
        puts "Minimum duration: #{format_duration_ms(output[:min_duration])}"
        puts "Average duration: #{format_duration_ms(output[:average_duration])}"
        puts "Maximum duration: #{format_duration_ms(output[:max_duration])}"
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

        command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--json"]

        # Add inflate if specified
        if @options.inflate && @options.inflate > 0
          command_parts = ["cd", @project_path, "&&", "npx", "featurevisor", "build", "--environment=#{environment}", "--inflate=#{@options.inflate}", "--json"]
        end

        command = command_parts.join(" ")

        # Execute the command and capture output
        datafile_output = execute_command(command)

        # Parse the JSON output
        begin
          JSON.parse(datafile_output, symbolize_names: true)
        rescue JSON::ParserError => e
          puts "Error: Failed to parse datafile JSON: #{e.message}"
          puts "Command output: #{datafile_output}"
          exit 1
        end
      end

      def execute_command(command)
        # Execute the command and capture stdout/stderr
        stdout, stderr, status = Open3.capture3(command)

        unless status.success?
          puts "Error: Command failed with exit code #{status.exitstatus}"
          puts "Command: #{command}"
          puts "Stderr: #{stderr}" unless stderr.empty?
          exit 1
        end

        stdout
      end

      def create_instance(datafile)
        # Create a real Featurevisor instance
        instance = Featurevisor.create_instance(
          log_level: get_logger_level
        )

        # Explicitly set the datafile
        instance.set_datafile(datafile)

        instance
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

      def benchmark_evaluation(n)
        value = nil
        total_duration_ns = 0
        min_duration_ns = nil
        max_duration_ns = 0

        n.times do
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          value = yield
          duration_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start_time

          total_duration_ns += duration_ns
          min_duration_ns = duration_ns if min_duration_ns.nil? || duration_ns < min_duration_ns
          max_duration_ns = duration_ns if duration_ns > max_duration_ns
        end

        duration = total_duration_ns / 1_000_000_000.0

        {
          value: value,
          duration: duration,
          min_duration: (min_duration_ns || 0) / 1_000_000_000.0,
          average_duration: duration / n,
          max_duration: max_duration_ns / 1_000_000_000.0
        }
      end

      def format_duration_ms(duration)
        format("%.6fms", duration * 1000)
      end

      def benchmark_feature_flag(instance, feature_key, context, n)
        benchmark_evaluation(n) do
          instance.is_enabled(feature_key, context)
        end
      end

      def benchmark_feature_variation(instance, feature_key, context, n)
        benchmark_evaluation(n) do
          instance.get_variation(feature_key, context)
        end
      end

      def benchmark_feature_variable(instance, feature_key, variable_key, context, n)
        benchmark_evaluation(n) do
          instance.get_variable(feature_key, variable_key, context)
        end
      end

      def format_value(value)
        if value.nil?
          "null"
        else
          value.to_json
        end
      rescue JSON::GeneratorError
        value.to_s
      end

      def pretty_duration(duration_seconds)
        # Convert to milliseconds for consistency with Go implementation
        ms = (duration_seconds * 1000).round

        if ms == 0
          return "0ms"
        end

        # Format like Go: hours, minutes, seconds, milliseconds
        hours = ms / 3_600_000
        ms = ms % 3_600_000
        minutes = ms / 60_000
        ms = ms % 60_000
        seconds = ms / 1_000
        ms = ms % 1_000

        result = []
        result << "#{hours}h" if hours > 0
        result << "#{minutes}m" if minutes > 0
        result << "#{seconds}s" if seconds > 0
        result << "#{ms}ms" if ms > 0

        result.join(" ")
      end
    end
  end
end
