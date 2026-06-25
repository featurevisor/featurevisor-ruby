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
    it "prefers target datafile over base datafile" do
      command = described_class.new(options)

      datafiles_by_key = {
        "production" => { schemaVersion: "2" },
        "production-target-checkout" => { schemaVersion: "2", target: "checkout" }
      }

      assertion = {
        environment: "production",
        target: "checkout"
      }

      datafile = command.send(:resolve_datafile_for_assertion, assertion, datafiles_by_key)
      expect(datafile[:target]).to eq("checkout")
    end
  end

  describe "build command generation" do
    it "includes target and environment flags when building target datafiles" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(include("featurevisor build", "--environment=production", "--target=checkout", "--json"))
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: "production",
        inflate: nil,
        target: "checkout"
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
              target: "checkout"
            }
          ]
        }
      ]

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output
      begin
        expect do
          command.send(:run_tests, tests, {}, {}, "warn", {})
        end.to raise_error(SystemExit)
      ensure
        $stdout = original_stdout
      end

      expect(output.string).to include("no datafile found for assertion target/environment combination")
      expect(output.string).to include("Test specs: 0 passed, 1 failed")
      expect(output.string).to include("Assertions: 0 passed, 1 failed")
    end
  end

  describe "comparison helpers" do
    it "compares empty hashes and arrays as equal" do
      command = described_class.new(options)

      expect(command.send(:compare_values, {}, {})).to be true
      expect(command.send(:compare_values, [], [])).to be true
    end

    it "treats hash key order as irrelevant" do
      command = described_class.new(options)

      expect(command.send(:compare_values, { a: 1, b: 2 }, { b: 2, a: 1 })).to be true
    end

    it "handles nested hash and array equality correctly" do
      command = described_class.new(options)

      expect(
        command.send(
          :compare_values,
          { a: { b: [1, { c: 2 }] }, d: 3 },
          { a: { b: [1, { c: 2 }] }, d: 3 }
        )
      ).to be true

      expect(
        command.send(
          :compare_values,
          { a: { b: [1, { c: 2 }] }, d: 3 },
          { a: { b: [1, { c: 4 }] }, d: 3 }
        )
      ).to be false
    end

    it "returns false for arrays with same elements in different order" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [1, 2, 3], [3, 2, 1])).to be false
    end

    it "distinguishes nil hash values from missing keys" do
      command = described_class.new(options)

      expect(command.send(:compare_values, { a: nil }, {})).to be false
    end

    it "handles nil positions in arrays" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [nil, 2], [nil, 2])).to be true
      expect(command.send(:compare_values, [2, nil], [nil, 2])).to be false
    end

    it "returns false for different array lengths including extra nil at end" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [1, 2], [1, 2, nil])).to be false
    end
  end
end
