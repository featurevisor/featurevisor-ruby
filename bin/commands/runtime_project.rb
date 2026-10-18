require "json"
require "open3"

module FeaturevisorCLI
  module Commands
    module RuntimeProject
      def each_project
        raise ArgumentError, "--n must be a positive integer" unless @options.n.positive?
        if @options.variation && @options.variable
          raise ArgumentError, "--variation and --variable cannot be combined"
        end
        config = project_json("config", "--json", include_set: false)
        environments = config["environments"]
        if environments.is_a?(Array)
          raise ArgumentError, "Pass --environment=<environment> when selecting one datafile." unless @options.environment
          unless environments.include?(@options.environment)
            raise ArgumentError, "Unknown environment #{@options.environment.inspect}. Available environments: #{environments.join(', ')}."
          end
        elsif @options.environment
          raise ArgumentError, "This project does not configure environments. Omit --environment."
        end
        sets = [@options.set]
        if config["sets"] && !@options.set
          directory = File.expand_path(config["setsDirectoryPath"] || "sets", @project_path)
          sets = Dir.children(directory).select { |entry| File.directory?(File.join(directory, entry)) }.sort
          raise ArgumentError, "No sets found in #{directory}." if sets.empty?
        end
        sets.each do |set|
          @active_set = set
          puts "Set #{set.inspect}" if set
          yield
        end
      end

      def project_json(*args, include_set: true)
        args << "--set=#{@active_set || @options.set}" if include_set && (@active_set || @options.set)
        stdout, stderr, status = Open3.capture3(*FeaturevisorCLI::NodeCli.command(@project_path), *args, chdir: @project_path)
        stdout.force_encoding(Encoding::UTF_8)
        stderr.force_encoding(Encoding::UTF_8)
        raise ArgumentError, stderr.empty? ? "Node CLI failed with exit code #{status.exitstatus}" : stderr unless status.success?
        warn stderr unless stderr.empty?
        JSON.parse(stdout)
      end

      def resolve_targets
        return [] if @options.targets.empty?
        available = project_json("list", "--targets", "--json").map { |target| target.is_a?(Hash) ? (target["key"] || target["name"]) : target }
        unknown = @options.targets.find { |target| !available.include?(target) }
        raise ArgumentError, "Unknown target #{unknown.inspect}. Available targets: #{available.join(', ')}." if unknown
        @options.targets
      end

      def build_datafile(environment, target = nil)
        args = ["build", "--json"]
        args << "--environment=#{environment}" if environment
        args << "--target=#{target}" if target
        args << "--inflate=#{@options.inflate}" if @options.inflate && @options.inflate.positive?
        # Symbol keys are the native SDK datafile representation.
        JSON.parse(JSON.generate(project_json(*args)), symbolize_names: true)
      end
    end
  end
end
