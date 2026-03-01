require "featurevisor"
require "stringio"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "bin"))
require "cli"

RSpec.describe FeaturevisorCLI::Commands::Test do
  let(:options) do
    opts = FeaturevisorCLI::Options.new
    opts.project_directory_path = "/tmp/featurevisor-project"
    opts
  end

  describe "datafile routing helpers" do
    it "prefers scoped datafile over tagged and base datafile" do
      command = described_class.new(options)

      datafiles_by_key = {
        "production" => { schemaVersion: "2" },
        "production-tag-web" => { schemaVersion: "2", tagged: true },
        "production-scope-browsers" => { schemaVersion: "2", scoped: true }
      }

      assertion = {
        environment: "production",
        scope: "browsers",
        tag: "web"
      }

      datafile = command.send(:resolve_datafile_for_assertion, assertion, datafiles_by_key)
      expect(datafile[:scoped]).to be true
    end

    it "returns parsed scope context by name" do
      command = described_class.new(options)
      config = {
        scopes: [
          { name: "browsers", context: { "platform" => "web" } }
        ]
      }

      scope_context = command.send(:get_scope_context, config, "browsers")
      expect(scope_context).to eq({ platform: "web" })
    end
  end

  describe "build command generation" do
    it "includes scope and environment flags when building scoped datafiles" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(include("featurevisor build", "--environment=production", "--scope=browsers", "--json"))
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: "production",
        schema_version: "2",
        inflate: nil,
        scope: "browsers"
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end

    it "does not include environment flag when environment is false" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.include?("featurevisor build") && !cmd.include?("--environment=") })
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: false,
        schema_version: nil,
        inflate: nil
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end
  end

  describe "test execution behavior" do
    it "evaluates expectedEvaluations in child assertions" do
      command = described_class.new(options)
      instance = double("child-instance")

      allow(instance).to receive(:is_enabled).and_return(true)
      allow(instance).to receive(:get_variation).and_return("control")
      allow(instance).to receive(:get_variable).and_return("v")
      allow(instance).to receive(:evaluate_flag).and_return({ type: "flag", enabled: false })
      allow(instance).to receive(:evaluate_variation).and_return({ type: "variation", variation_value: "control" })
      allow(instance).to receive(:evaluate_variable).and_return({ type: "variable", variable_key: "k", variable_value: "v" })

      assertion = {
        expectedEvaluations: {
          flag: {
            enabled: true
          }
        }
      }

      result = command.send(:run_test_feature_child, assertion, "myFeature", instance, "warn")
      expect(result[:has_error]).to be true
      expect(result[:errors]).to include("expectedEvaluations.flag.enabled")
    end

    it "counts missing-datafile assertion as failed" do
      command = described_class.new(options)

      allow(command).to receive(:exit).and_raise(SystemExit.new(1))

      tests = [
        {
          key: "features/missing.spec",
          feature: "foo",
          assertions: [
            {
              description: "missing datafile assertion",
              environment: "production",
              scope: "browsers"
            }
          ]
        }
      ]

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output
      begin
        expect do
          command.send(:run_tests, tests, {}, {}, "warn", { scopes: [] })
        end.to raise_error(SystemExit)
      ensure
        $stdout = original_stdout
      end

      expect(output.string).to include("no datafile found for assertion scope/tag/environment combination")
      expect(output.string).to include("Test specs: 0 passed, 1 failed")
      expect(output.string).to include("Assertions: 0 passed, 1 failed")
    end
  end
end
