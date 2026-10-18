require "featurevisor"
require "open3"
require "rbconfig"
require "tmpdir"

# Test the CLI functionality by loading it directly
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "bin"))
require "cli"

RSpec.describe FeaturevisorCLI do
  describe ".run" do
    it "shows help when no command is provided" do
      expect { FeaturevisorCLI.run([]) }.to output(/Featurevisor Ruby SDK CLI/).to_stdout
    end

    it "routes to test command" do
      expect(FeaturevisorCLI::Commands::Test).to receive(:run)
      FeaturevisorCLI.run(["test"])
    end

    it "routes to benchmark command" do
      expect(FeaturevisorCLI::Commands::Benchmark).to receive(:run)
      FeaturevisorCLI.run(["benchmark"])
    end

    it "routes to assess-distribution command" do
      expect(FeaturevisorCLI::Commands::AssessDistribution).to receive(:run)
      FeaturevisorCLI.run(["assess-distribution"])
    end
  end

  describe ".show_help" do
    it "displays help information" do
      expect { FeaturevisorCLI.show_help }.to output(/Commands:/).to_stdout
    end

    it "shows the conditional environment requirement" do
      expect { FeaturevisorCLI.show_help }.to output(/--environment is required only when configured/).to_stdout
    end
  end
end

RSpec.describe FeaturevisorCLI::Parser do
  it "preserves explicit sets for Node validation in flat projects" do
    Dir.mktmpdir("featurevisor-sets-") do |directory|
      shim = File.join(directory, "npx")
      File.write(shim, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        args = ARGV.drop(1)
        File.open(File.join(__dir__, "calls"), "a") { |file| file.puts(JSON.generate(args)) }
        if args[0] == "config"
          puts JSON.generate({environments: false, sets: false})
        elsif args.any? { |arg| arg.start_with?("--set=") }
          warn "This project does not configure sets. Omit --set."
          exit 17
        elsif args[0] == "list"
          puts JSON.generate(args.include?("--tests") ? {kind: "featurevisor.test-execution", schemaVersion: 1, tests: []} : [])
        else
          puts JSON.generate({schemaVersion: "2", revision: "test", segments: {}, variables: {}, features: {ready: {bucketBy: "userId", traffic: [{key: "everyone", segments: "*", percentage: 100000}]}}})
        end
      RUBY
      File.chmod(0o755, shim)
      %w[test benchmark assess-distribution].each do |command|
        [[], ["--set=blue"], ["--set="], ["--set=0"]].each do |args|
          File.write(File.join(directory, "calls"), "")
          stdout, stderr, status = Open3.capture3(
            {"PATH" => "#{directory}:#{ENV['PATH']}"}, RbConfig.ruby,
            File.expand_path("../bin/featurevisor", __dir__), command,
            "--projectDirectoryPath=#{directory}", "--feature=ready", "--n=2", *args
          )
          expect(status.success?).to eq(args.empty?), stdout + stderr
          calls = File.readlines(File.join(directory, "calls"), encoding: "UTF-8").map { |line| JSON.parse(line) }.reject { |call| call[0] == "config" }
          expect(calls).not_to be_empty
          calls.each { |call| expect(call.grep(/^--set=/)).to eq(args) }
          expect(stdout + stderr).to include("Omit --set") unless args.empty?
        end
      end
    end
  end

  it "rejects invalid inflation in CLI processes before Node delegation" do
    Dir.mktmpdir("featurevisor-inflate-") do |directory|
      marker = File.join(directory, "delegated")
      shim = File.join(directory, "npx")
      File.write(shim, "#!/bin/sh\ntouch '#{marker}'\nexit 19\n")
      File.chmod(0o755, shim)
      %w[test benchmark assess-distribution].each do |command|
        ["--inflate=0", "--inflate=-5", "--inflate=1.5", "--inflate=invalid", "--inflate=", "--inflate=1foo", "--inflate"].each do |option|
          stdout, stderr, status = Open3.capture3(
            {"PATH" => "#{directory}:#{ENV['PATH']}"}, RbConfig.ruby,
            File.expand_path("../bin/featurevisor", __dir__), command, "--feature=ready", option
          )
          expect(status.success?).to be(false), stdout + stderr
          expect(stdout + stderr).to include("inflate")
          expect(File.exist?(marker)).to be(false)
        end
      end
    end
  end

  it "accepts omitted inflation and positive integers for every command" do
    %w[test benchmark assess-distribution].each do |command|
      expect(described_class.parse([command]).inflate).to be_nil
      expect(described_class.parse([command, "--inflate=1"]).inflate).to eq(1)
    end
  end

  it "rejects invalid explicit inflation before running any command" do
    %w[test benchmark assess-distribution].each do |command|
      ["0", "-5", "1.5", "invalid", "", "1foo"].each do |value|
        expect { described_class.parse([command, "--inflate=#{value}"]) }.to raise_error(OptionParser::InvalidArgument)
      end
    end
  end

  it "parses and deduplicates repeated targets" do
    options = described_class.parse(["test", "--target=web", "--target=mobile", "--target=web"])
    expect(options.targets).to eq(["web", "mobile"])
  end

  describe ".parse" do
    it "parses basic options" do
      options = FeaturevisorCLI::Parser.parse(["test", "--verbose", "--n=5000", "--with-scopes", "--with-tags"])
      expect(options.command).to eq("test")
      expect(options.verbose).to be true
      expect(options.n).to eq(5000)
      expect(options.with_scopes).to be true
      expect(options.with_tags).to be true
    end

    it "parses legacy compatibility flags" do
      options = FeaturevisorCLI::Parser.parse(["test", "--withScopes", "--withTags"])
      expect(options.with_scopes).to be true
      expect(options.with_tags).to be true
    end

    it "accepts legacy schema version aliases" do
      kebab_options = FeaturevisorCLI::Parser.parse(["test", "--schema-version=2"])
      camel_options = FeaturevisorCLI::Parser.parse(["test", "--schemaVersion=2"])

      expect(kebab_options.schema_version).to eq("2")
      expect(camel_options.schema_version).to eq("2")
    end

    it "sets default values" do
      options = FeaturevisorCLI::Parser.parse(["test"])
      expect(options.n).to eq(1000)
      expect(options.project_directory_path).to eq(Dir.pwd)
    end

    it "parses environment option" do
      options = FeaturevisorCLI::Parser.parse(["benchmark", "--environment=production"])
      expect(options.environment).to eq("production")
    end

    it "parses feature option" do
      options = FeaturevisorCLI::Parser.parse(["benchmark", "--feature=myFeature"])
      expect(options.feature).to eq("myFeature")
    end
  end
end

RSpec.describe FeaturevisorCLI::Commands::Benchmark do
  describe ".run" do
    let(:options) do
      opts = FeaturevisorCLI::Options.new
      opts.feature = "testFeature"
      opts.environment = "development"
      opts.n = 100
      opts
    end

    it "requires environment when the project configures environments" do
      allow_any_instance_of(described_class).to receive(:project_json).with("config", "--json", include_set: false).and_return({"environments" => ["development"]})
      options_without_env = FeaturevisorCLI::Options.new
      options_without_env.feature = "testFeature"
      options_without_env.n = 100

      expect { FeaturevisorCLI::Commands::Benchmark.run(options_without_env) }.to raise_error(ArgumentError, /--environment/)
    end

    it "requires feature parameter" do
      options_without_feature = FeaturevisorCLI::Options.new
      options_without_feature.environment = "development"
      options_without_feature.n = 100

      expect { FeaturevisorCLI::Commands::Benchmark.run(options_without_feature) }.to raise_error(SystemExit)
    end

    it "accepts valid parameters" do
      allow_any_instance_of(described_class).to receive(:project_json).with("config", "--json", include_set: false).and_return({"environments" => ["development"]})
      # Mock the build_datafile method to avoid external command execution
      allow_any_instance_of(FeaturevisorCLI::Commands::Benchmark).to receive(:build_datafile).and_return({
        "schemaVersion" => "2",
        "revision" => "test",
        "segments" => {},
        "features" => {
          "testFeature" => {
            "key" => "testFeature",
            "bucketBy" => "userId",
            "variations" => [],
            "traffic" => [
              {
                "key" => "everyone",
                "segments" => "*",
                "percentage" => 100_000
              }
            ]
          }
        }
      })

      expect { FeaturevisorCLI::Commands::Benchmark.run(options) }.not_to raise_error
    end
  end
end
