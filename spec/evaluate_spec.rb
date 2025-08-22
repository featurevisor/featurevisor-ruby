require "featurevisor"

RSpec.describe Featurevisor::Evaluate do
  describe "EvaluationReason" do
    it "should have feature specific reasons" do
      expect(Featurevisor::EvaluationReason::FEATURE_NOT_FOUND).to eq("feature_not_found")
      expect(Featurevisor::EvaluationReason::DISABLED).to eq("disabled")
      expect(Featurevisor::EvaluationReason::REQUIRED).to eq("required")
      expect(Featurevisor::EvaluationReason::OUT_OF_RANGE).to eq("out_of_range")
    end

    it "should have variation specific reasons" do
      expect(Featurevisor::EvaluationReason::NO_VARIATIONS).to eq("no_variations")
      expect(Featurevisor::EvaluationReason::VARIATION_DISABLED).to eq("variation_disabled")
    end

    it "should have variable specific reasons" do
      expect(Featurevisor::EvaluationReason::VARIABLE_NOT_FOUND).to eq("variable_not_found")
      expect(Featurevisor::EvaluationReason::VARIABLE_DEFAULT).to eq("variable_default")
      expect(Featurevisor::EvaluationReason::VARIABLE_DISABLED).to eq("variable_disabled")
      expect(Featurevisor::EvaluationReason::VARIABLE_OVERRIDE).to eq("variable_override")
    end

    it "should have common reasons" do
      expect(Featurevisor::EvaluationReason::NO_MATCH).to eq("no_match")
      expect(Featurevisor::EvaluationReason::FORCED).to eq("forced")
      expect(Featurevisor::EvaluationReason::RULE).to eq("rule")
      expect(Featurevisor::EvaluationReason::ALLOCATED).to eq("allocated")
      expect(Featurevisor::EvaluationReason::ERROR).to eq("error")
    end
  end

  describe "EVALUATION_TYPES" do
    it "should have correct evaluation types" do
      expect(Featurevisor::EVALUATION_TYPES).to eq(%w[flag variation variable])
    end
  end

  describe "evaluate_with_hooks" do
    let(:logger) { Featurevisor.create_logger(level: "warn") }
    let(:datafile_reader) do
      Featurevisor::DatafileReader.new(
        datafile: {
          schemaVersion: "2.0",
          revision: "1",
          segments: {},
          features: {}
        },
        logger: logger
      )
    end
    let(:hooks_manager) { Featurevisor::Hooks::HooksManager.new(logger: logger) }

    it "should be a method" do
      expect(Featurevisor::Evaluate).to respond_to(:evaluate_with_hooks)
    end

    it "should handle errors gracefully" do
      options = {
        type: "flag",
        feature_key: "test-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader
      }

      # Mock datafile_reader to raise an error
      allow(datafile_reader).to receive(:get_feature).and_raise(StandardError.new("Test error"))

      result = Featurevisor::Evaluate.evaluate_with_hooks(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::ERROR)
      expect(result[:error]).to be_a(StandardError)
      expect(result[:error].message).to eq("Test error")
    end

    it "should apply default variation value when specified" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        after: ->(eval, opts) { eval.merge(hook_applied: true) }
      )
      hooks_manager.add(hook)

      options = {
        type: "variation",
        feature_key: "test-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader,
        default_variation_value: "default"
      }

      # Mock datafile_reader to return no feature
      allow(datafile_reader).to receive(:get_feature).and_return(nil)

      result = Featurevisor::Evaluate.evaluate_with_hooks(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::FEATURE_NOT_FOUND)
      expect(result[:hook_applied]).to be true
    end

    it "should apply default variable value when specified" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        after: ->(eval, opts) { eval.merge(hook_applied: true) }
      )
      hooks_manager.add(hook)

      options = {
        type: "variable",
        feature_key: "test-feature",
        variable_key: "test-var",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader,
        default_variable_value: "default"
      }

      # Mock datafile_reader to return no feature
      allow(datafile_reader).to receive(:get_feature).and_return(nil)

      result = Featurevisor::Evaluate.evaluate_with_hooks(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::FEATURE_NOT_FOUND)
      expect(result[:hook_applied]).to be true
    end
  end

  describe "evaluate" do
    let(:logger) { Featurevisor.create_logger(level: "warn") }
    let(:datafile_reader) do
      Featurevisor::DatafileReader.new(
        datafile: {
          schemaVersion: "2.0",
          revision: "1",
          segments: {},
          features: {}
        },
        logger: logger
      )
    end
    let(:hooks_manager) { Featurevisor::Hooks::HooksManager.new(logger: logger) }

    it "should be a method" do
      expect(Featurevisor::Evaluate).to respond_to(:evaluate)
    end

    it "should return feature not found when feature doesn't exist" do
      options = {
        type: "flag",
        feature_key: "non-existent-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader
      }

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::FEATURE_NOT_FOUND)
      expect(result[:feature_key]).to eq("non-existent-feature")
    end

    it "should handle sticky features" do
      sticky = {
        "test-feature" => {
          enabled: true
        }
      }

      options = {
        type: "flag",
        feature_key: "test-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader,
        sticky: sticky
      }

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::STICKY)
      expect(result[:enabled]).to be true
      expect(result[:sticky]).to eq(sticky["test-feature"])
    end

    it "should handle sticky variations" do
      sticky = {
        "test-feature" => {
          variation: "test-variation"
        }
      }

      options = {
        type: "variation",
        feature_key: "test-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader,
        sticky: sticky
      }

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::STICKY)
      expect(result[:variation_value]).to eq("test-variation")
    end

    it "should handle sticky variables" do
      sticky = {
        "test-feature" => {
          variables: {
            "test-var" => "test-value"
          }
        }
      }

      options = {
        type: "variable",
        feature_key: "test-feature",
        variable_key: "test-var",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader,
        sticky: sticky
      }

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::STICKY)
      expect(result[:variable_value]).to eq("test-value")
    end

    it "should handle forced features" do
      feature = {
        key: "test-feature",
        force: [
          {
            conditions: [{ attribute: "userId", operator: "equals", value: "123" }],
            enabled: true
          }
        ]
      }

      # Mock the get_matched_force method
      allow(datafile_reader).to receive(:get_matched_force).and_return({
        force: feature[:force][0],
        forceIndex: 0
      })

      options = {
        type: "flag",
        feature_key: feature,
        context: { userId: "123" },
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader
      }

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::FORCED)
      expect(result[:enabled]).to be true
      expect(result[:force]).to eq(feature[:force][0])
    end

    it "should handle required features" do
      feature = {
        key: "test-feature",
        required: ["required-feature"]
      }

      # Mock the get_feature method to return our feature
      allow(datafile_reader).to receive(:get_feature).and_return(feature)

      # Mock the get_matched_force method to return no force
      allow(datafile_reader).to receive(:get_matched_force).and_return({
        force: nil,
        forceIndex: nil
      })

      # Mock the get_matched_traffic method to return no traffic
      allow(datafile_reader).to receive(:get_matched_traffic).and_return(nil)

      # Mock the bucketer to avoid complex logic
      allow(Featurevisor::Bucketer).to receive(:get_bucket_key).and_return("test.123")
      allow(Featurevisor::Bucketer).to receive(:get_bucketed_number).and_return(50)

      options = {
        type: "flag",
        feature_key: feature,
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader
      }

      # We need to stub the recursive call to evaluate
      allow(Featurevisor::Evaluate).to receive(:evaluate).and_call_original
      allow(Featurevisor::Evaluate).to receive(:evaluate).with(
        hash_including(type: "flag", feature_key: "required-feature")
      ).and_return({
        type: "flag",
        feature_key: "required-feature",
        enabled: false
      })

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::REQUIRED)
      expect(result[:enabled]).to be false
      expect(result[:required]).to eq(["required-feature"])
    end

    it "should handle errors gracefully" do
      options = {
        type: "flag",
        feature_key: "test-feature",
        context: {},
        logger: logger,
        hooks_manager: hooks_manager,
        datafile_reader: datafile_reader
      }

      # Mock datafile_reader to raise an error
      allow(datafile_reader).to receive(:get_feature).and_raise(StandardError.new("Test error"))

      result = Featurevisor::Evaluate.evaluate(options)

      expect(result[:reason]).to eq(Featurevisor::EvaluationReason::ERROR)
      expect(result[:error]).to be_a(StandardError)
      expect(result[:error].message).to eq("Test error")
    end
  end
end
