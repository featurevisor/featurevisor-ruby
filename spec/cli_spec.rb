require "featurevisor"

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

    it "shows benchmark environment requirement note" do
      expect { FeaturevisorCLI.show_help }.to output(/Note: benchmark command requires --environment and --feature options/).to_stdout
    end
  end
end

RSpec.describe FeaturevisorCLI::Parser do
  describe ".parse" do
    it "parses basic options" do
      options = FeaturevisorCLI::Parser.parse(["test", "--verbose", "--n=5000"])
      expect(options.command).to eq("test")
      expect(options.verbose).to be true
      expect(options.n).to eq(5000)
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

    it "requires environment parameter" do
      options_without_env = FeaturevisorCLI::Options.new
      options_without_env.feature = "testFeature"
      options_without_env.n = 100

      expect { FeaturevisorCLI::Commands::Benchmark.run(options_without_env) }.to raise_error(SystemExit)
    end

    it "requires feature parameter" do
      options_without_feature = FeaturevisorCLI::Options.new
      options_without_feature.environment = "development"
      options_without_feature.n = 100

      expect { FeaturevisorCLI::Commands::Benchmark.run(options_without_feature) }.to raise_error(SystemExit)
    end

    it "accepts valid parameters" do
      # Mock the build_datafile method to avoid external command execution
      allow_any_instance_of(FeaturevisorCLI::Commands::Benchmark).to receive(:build_datafile).and_return({
        "features" => {
          "testFeature" => {
            "key" => "testFeature",
            "variations" => []
          }
        }
      })

      expect { FeaturevisorCLI::Commands::Benchmark.run(options) }.not_to raise_error
    end
  end
end
