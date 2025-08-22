require "optparse"
require "json"
require_relative "commands"

module FeaturevisorCLI
  class Options
    attr_accessor :command, :assertion_pattern, :context, :environment, :feature,
                 :key_pattern, :n, :only_failures, :quiet, :variable, :variation,
                 :verbose, :inflate, :show_datafile, :schema_version, :project_directory_path,
                 :populate_uuid

    def initialize
      @n = 1000
      @project_directory_path = Dir.pwd
      @populate_uuid = []
    end
  end

  class Parser
    def self.parse(args)
      options = Options.new

      if args.empty?
        return options
      end

      options.command = args[0]
      remaining_args = args[1..-1]

      OptionParser.new do |opts|
        opts.banner = "Usage: featurevisor [command] [options]"

        opts.on("--assertionPattern=PATTERN", "Assertion pattern") do |v|
          options.assertion_pattern = v
        end

        opts.on("--context=CONTEXT", "Context JSON") do |v|
          options.context = v
        end

        opts.on("--environment=ENV", "Environment (required for benchmark)") do |v|
          options.environment = v
        end

        opts.on("--feature=FEATURE", "Feature key (required for benchmark)") do |v|
          options.feature = v
        end

        opts.on("--keyPattern=PATTERN", "Key pattern") do |v|
          options.key_pattern = v
        end

        opts.on("-n", "--iterations=N", "--n=N", Integer, "Number of iterations (default: 1000)") do |v|
          options.n = v
        end

        opts.on("--onlyFailures", "Only show failures") do
          options.only_failures = true
        end

        opts.on("--quiet", "Quiet mode") do
          options.quiet = true
        end

        opts.on("--variable=VARIABLE", "Variable key") do |v|
          options.variable = v
        end

        opts.on("--variation", "Variation mode") do
          options.variation = true
        end

        opts.on("--verbose", "Verbose mode") do
          options.verbose = true
        end

        opts.on("--inflate=N", Integer, "Inflate mode") do |v|
          options.inflate = v
        end

        opts.on("--showDatafile", "Show datafile content for each test") do
          options.show_datafile = true
        end

        opts.on("--schemaVersion=VERSION", "Schema version") do |v|
          options.schema_version = v
        end

        opts.on("--projectDirectoryPath=PATH", "Project directory path") do |v|
          options.project_directory_path = v
        end

        opts.on("--populateUuid=KEY", "Populate UUID for attribute key") do |v|
          options.populate_uuid << v
        end

        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit
        end
      end.parse!(remaining_args)

      options
    end
  end

  def self.run(args)
    options = Parser.parse(args)

    case options.command
    when "test"
      Commands::Test.run(options)
    when "benchmark"
      Commands::Benchmark.run(options)
    when "assess-distribution"
      Commands::AssessDistribution.run(options)
    else
      show_help
    end
  end

  def self.show_help
    puts "Featurevisor Ruby SDK CLI"
    puts ""
    puts "Usage: featurevisor [command] [options]"
    puts ""
    puts "Commands:"
    puts "  test                    Run tests for features and segments"
    puts "  benchmark               Benchmark feature evaluation performance"
    puts "  assess-distribution     Assess feature distribution across contexts"
    puts ""
    puts "Learn more at https://featurevisor.com/docs/sdks/ruby/"
    puts ""
    puts "Examples:"
    puts "  featurevisor test"
    puts "  featurevisor test --keyPattern=pattern"
    puts "  featurevisor benchmark --feature=myFeature --environment=dev --n=10000"
    puts "  featurevisor assess-distribution --feature=myFeature --n=10000"
    puts ""
    puts "Note: benchmark command requires --environment and --feature options"
  end
end
