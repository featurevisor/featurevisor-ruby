require "optparse"
require "json"
require_relative "commands"

module FeaturevisorCLI
  class Options
    attr_accessor :command, :assertion_pattern, :context, :environment, :feature,
                 :key_pattern, :n, :only_failures, :quiet, :variable, :variation,
                 :verbose, :inflate, :show_datafile, :schema_version, :project_directory_path,
                 :populate_uuid, :with_scopes, :with_tags, :targets, :entity_type, :set,
                 :json, :pretty, :case_id, :coverage, :uncovered,
                 :project_directory_path_explicit

    def initialize
      @n = 1000
      @project_directory_path = Dir.pwd
      @populate_uuid = []
      @targets = []
    end
  end

  class Parser
    def self.parse(args)
      options = Options.new

      if args.empty?
        return options
      end

      options.command = args[0]
      unless %w[test benchmark assess-distribution].include?(options.command)
        raise ArgumentError, "Unknown command: #{options.command}"
      end
      remaining_args = args[1..-1]

      OptionParser.new do |opts|
        opts.banner = "Usage: featurevisor #{options.command} [options]"

        opts.on("--assertion-pattern=PATTERN", "--assertionPattern=PATTERN", "Assertion pattern") do |v|
          options.assertion_pattern = v
        end

        opts.on("--context=CONTEXT", "Context JSON") do |v|
          options.context = v
        end

        opts.on("--environment=ENV", "Configured environment (omit for flat projects)") do |v|
          options.environment = v
        end

        opts.on("--feature=FEATURE", "Feature key") do |v|
          options.feature = nonempty_value("--feature", v)
        end

        opts.on("--key-pattern=PATTERN", "--keyPattern=PATTERN", "Key pattern") do |v|
          options.key_pattern = v
        end

        opts.on("--entity-type=TYPE", "--entityType=TYPE", %w[feature segment variable scenario], "Filter tests by entity type") do |v|
          options.entity_type = v
        end

        opts.on("--iterations=N", "--n=N", "Number of iterations (default: 1000)") do |v|
          options.n = positive_iterations(v)
        end

        opts.on("-n N", "Number of iterations (default: 1000)") do |v|
          options.n = positive_iterations(v.delete_prefix("="))
        end

        opts.on("--only-failures", "--onlyFailures", "Only show failures") do
          options.only_failures = true
        end

        opts.on("--quiet", "Quiet mode") do
          options.quiet = true
        end

        opts.on("--variable=VARIABLE", "Variable key") do |v|
          options.variable = nonempty_value("--variable", v)
        end

        opts.on("--variation", "Variation mode") do
          options.variation = true
        end

        opts.on("--verbose", "Verbose mode") do
          options.verbose = true
        end

        opts.on("--inflate=N", Integer, "Inflate mode") do |v|
          raise OptionParser::InvalidArgument, "--inflate must be a positive integer" unless v.positive?
          options.inflate = v
        end

        opts.on("--show-datafile", "--showDatafile", "Show datafile content for each test") do
          options.show_datafile = true
        end

        opts.on("--schemaVersion=VERSION", "--schema-version=VERSION", "Legacy schema version option accepted and ignored") do |v|
          options.schema_version = v
        end

        opts.on("--with-scopes", "--withScopes", "Legacy scope option accepted and ignored") do
          options.with_scopes = true
        end

        opts.on("--with-tags", "--withTags", "Legacy tag option accepted and ignored") do
          options.with_tags = true
        end

        opts.on("--project-directory-path=PATH", "--projectDirectoryPath=PATH", "--root-directory-path=PATH", "--rootDirectoryPath=PATH", "Project directory path") do |v|
          options.project_directory_path = nonempty_value("--project-directory-path", v)
          options.project_directory_path_explicit = true
        end

        opts.on("--populate-uuid=KEY", "--populateUuid=KEY", "Populate UUID for attribute key") do |v|
          options.populate_uuid << nonempty_value("--populate-uuid", v)
        end

        opts.on("--target=TARGET", "Target datafile; repeat for multiple targets") do |v|
          v = nonempty_value("--target", v)
          options.targets << v unless options.targets.include?(v)
        end

        opts.on("--set=SET", "Project set") do |v|
          options.set = v
        end

        opts.on("--json", "Print a versioned JSON test report") do
          options.json = true
        end

        opts.on("--pretty", "Pretty print JSON output") do
          options.pretty = true
        end

        opts.on("--case=ID", "Run one exact expanded test case") do |v|
          options.case_id = v
        end

        opts.on("--coverage", "Report observed rule and override selections") do
          options.coverage = true
        end

        opts.on("--uncovered", "List features and variables without associated tests") do
          options.uncovered = true
        end

        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit
        end
      end.parse!(remaining_args)

      unless remaining_args.empty?
        raise OptionParser::InvalidArgument, "Unexpected arguments: #{remaining_args.join(' ')}"
      end
      unless options.context.nil?
        context = JSON.parse(options.context)
        raise ArgumentError, "--context must be a JSON object" unless context.is_a?(Hash)
      end
      options
    end

    def self.positive_iterations(value)
      parsed = Integer(value, 10)
      raise ArgumentError unless parsed.positive?
      parsed
    rescue ArgumentError
      raise OptionParser::InvalidArgument, "--n must be a positive integer"
    end

    def self.nonempty_value(name, value)
      if value.empty? || value.start_with?("--")
        raise OptionParser::InvalidArgument, "#{name} requires a nonempty value"
      end
      value
    end
  end

  def self.run(args)
    return show_help if args.empty? || args == ["--help"] || args == ["-h"]

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
  rescue ArgumentError, OptionParser::ParseError, JSON::ParserError, SystemCallError => e
    warn "Error: #{e.message}"
    exit 1
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
    puts "  featurevisor test --key-pattern=pattern"
    puts "  featurevisor benchmark --feature=myFeature --environment=dev --n=10000"
    puts "  featurevisor assess-distribution --feature=myFeature --n=10000"
    puts ""
    puts "Note: benchmark requires --feature or --variable; --environment is required only when configured"
  end
end
