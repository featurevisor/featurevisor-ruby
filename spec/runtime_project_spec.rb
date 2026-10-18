require "featurevisor"
require_relative "../bin/cli"

RSpec.describe FeaturevisorCLI::Commands::RuntimeProject do
  [FeaturevisorCLI::Commands::Benchmark, FeaturevisorCLI::Commands::AssessDistribution].each do |klass|
    describe klass.name do
      let(:options) do
        FeaturevisorCLI::Options.new.tap do |value|
          value.feature = "ready"
          value.n = 2
          value.project_directory_path = "/tmp/project with spaces"
        end
      end
      let(:command) { klass.new(options) }

      it "delegates flat datafile builds without an environment argument" do
        expect(command).to receive(:project_json).with("config", "--json", include_set: false).and_return({"environments" => false})
        expect(command).to receive(:project_json).with("build", "--json").and_return({"features" => {}})
        command.send(:each_project) { expect(command.send(:build_datafile, nil)).to eq({features: {}}) }
      end

      it "delegates explicit positive inflation" do
        options.inflate = 1
        expect(command).to receive(:project_json).with("build", "--json", "--inflate=1").and_return({"features" => {}})
        command.send(:build_datafile, nil)
      end

      it "validates missing, unknown and flat environment selections" do
        allow(command).to receive(:project_json).and_return({"environments" => ["production"]})
        expect { command.send(:each_project) {} }.to raise_error(ArgumentError, /--environment/)
        options.environment = "unknown"
        expect { command.send(:each_project) {} }.to raise_error(ArgumentError, /Unknown environment/)
        allow(command).to receive(:project_json).and_return({"environments" => false})
        expect { command.send(:each_project) {} }.to raise_error(ArgumentError, /Omit --environment/)
      end

      it "delegates the set and target as separate subprocess arguments" do
        options.set = "blue"
        options.environment = "production"
        status = double(success?: true)
        expect(Open3).to receive(:capture3).with("npx", "featurevisor", "config", "--json", chdir: options.project_directory_path).and_return(['{"environments":["production"]}', "", status])
        expect(Open3).to receive(:capture3).with("npx", "featurevisor", "build", "--json", "--environment=production", "--target=web", "--set=blue", chdir: options.project_directory_path).and_return(['{"features":{}}', "", status])
        command.send(:each_project) { command.send(:build_datafile, options.environment, "web") }
      end

      it "forwards the set while resolving targets and propagates Node failures" do
        options.set = "blue"
        options.targets = ["web"]
        expect(Open3).to receive(:capture3).with("npx", "featurevisor", "list", "--targets", "--json", "--set=blue", chdir: options.project_directory_path).and_return(['["web"]', "", double(success?: true)])
        expect(command.send(:resolve_targets)).to eq(["web"])
        allow(Open3).to receive(:capture3).and_return(["", "café build failed", double(success?: false)])
        expect { command.send(:build_datafile, nil) }.to raise_error(ArgumentError, /café build failed/)
      end
    end
  end

  it "returns a failing process status for invalid runtime options" do
    expect { FeaturevisorCLI.run(["benchmark", "--feature=ready", "--n=0"]) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end
end
