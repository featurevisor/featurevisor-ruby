# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "Featurevisor v3 conformance" do
  it "uses the shared inclusive allocation contract" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    expect(fixture[:version]).to eq(5)
    reader = Featurevisor.const_get(:InstanceEvaluationDataProvider).new(
      datafile: { schemaVersion: "2", revision: "conformance", segments: {}, features: {} },
      diagnostics: Featurevisor.const_get(:DiagnosticReporter).new(level: "fatal")
    )
    traffic = { allocation: fixture.dig(:bucketing, :allocations) }

    fixture.dig(:bucketing, :allocationExpectations).each do |bucket, expected|
      allocation = reader.get_matched_allocation(traffic, bucket.to_s.to_i)
      expect(allocation[:variation]).to eq(expected)
    end

    fixture[:numericBucketKeys].each do |test_case|
      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: "feature",
        bucket_by: "value",
        context: { value: test_case[:value] },
        diagnostics: Featurevisor.const_get(:DiagnosticReporter).new
      )
      expect(bucket_key).to eq("#{test_case[:expected]}.feature")
    end

    fixture.dig(:regularExpressions, :portableCases).each do |test_case|
      condition = {
        attribute: "value",
        operator: "matches",
        value: test_case[:pattern],
        regexFlags: test_case[:flags]
      }
      expect(
        reader.all_conditions_are_matched(condition, {value: test_case[:value]})
      ).to eq(test_case[:expected]), "pattern #{test_case[:pattern]}, flags #{test_case[:flags]}"
    end

    fixture[:conditionCases].each do |test_case|
      expect(
        reader.all_conditions_are_matched(test_case[:condition], test_case[:context])
      ).to eq(test_case[:expected]), test_case[:name]
    end

    aggregate_case = fixture.dig(:defaults, :aggregateCase)
    featurevisor = Featurevisor.create_featurevisor(datafile: aggregate_case[:datafile], log_level: "fatal")
    evaluated = featurevisor.get_feature_evaluations(
      {},
      [],
      default_variation_value: aggregate_case[:defaultVariationValue]
    )[:experiment]
    expect(evaluated[:enabled]).to eq(aggregate_case.dig(:expected, :enabled))
    expect(evaluated[:variation]).to eq(aggregate_case.dig(:expected, :variation))
  end

  it "evaluates every shared global variable case" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    globals = fixture[:globalVariables]

    globals[:cases].each do |test_case|
      f = Featurevisor.create_featurevisor(
        datafile: globals[:datafile],
        sticky_variables: test_case[:stickyVariables] || {},
        log_level: "fatal"
      )
      options = {}
      options[:default_variable_value] = test_case[:defaultVariableValue] if test_case.key?(:defaultVariableValue)
      evaluation = f.evaluate_variable(test_case[:key], test_case[:context] || {}, options)
      expect(evaluation[:variable_value]).to eq(test_case[:expectedValue]), test_case[:name]
      expect(evaluation[:reason]).to eq(test_case[:expectedReason]), test_case[:name]
      expect(evaluation[:variable_override_index]).to eq(test_case[:expectedOverrideIndex]), test_case[:name]
      expect(evaluation[:variable_override_key]).to eq(test_case[:expectedOverrideKey]), test_case[:name]
      expect(evaluation[:variable_override_path]).to eq(test_case[:expectedOverridePath]), test_case[:name]
    end

    boundary = globals[:overloadCase]
    f = Featurevisor.create_featurevisor(datafile: globals[:datafile], log_level: "fatal")
    expect(f.get_variable(boundary[:sharedKey])).to eq(boundary[:expectedGlobalValue])
    expect(f.get_variable(boundary[:sharedKey], boundary[:featureVariableKey])).to eq(boundary[:expectedFeatureValue])
    expect(f.get_variable_keys.map(&:to_s)).to include(boundary[:sharedKey])
    expect(f.get_variable_evaluations[boundary[:sharedKey].to_sym]).to eq(boundary[:expectedGlobalValue])
  end

  it "supports canonical required features for flags and feature variable overrides" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    required = fixture[:requiredFeatures]
    f = Featurevisor.create_featurevisor(datafile: required[:datafile], log_level: "fatal")

    required[:cases].each do |test_case|
      expect(f.is_enabled(test_case[:feature])).to eq(test_case[:expectedEnabled]), test_case[:name]
    end
    test_case = required[:featureVariableCase]
    evaluation = f.evaluate_variable(test_case[:feature], test_case[:variable])
    expect(evaluation[:variable_value]).to eq(test_case[:expectedValue])
    expect(evaluation[:variable_override_key]).to eq(test_case[:expectedOverrideKey])
  end

  it "reports direct and dependency driven variable updates for merge and replacement" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    globals = fixture[:globalVariables]
    update = globals[:datafileUpdateCase]
    f = Featurevisor.create_featurevisor(datafile: update[:initial], log_level: "fatal")
    events = []
    f.on("datafile_set", ->(event) { events << event })
    f.set_datafile(update[:merge])
    expect(f.get_feature_keys.map(&:to_s).sort).to eq(update.dig(:expectedAfterMerge, :features).sort)
    expect(f.get_variable_keys.map(&:to_s).sort).to eq(update.dig(:expectedAfterMerge, :variables).sort)
    expect(events.last[:features].map(&:to_s)).to match_array(update.dig(:expectedAfterMerge, :changedFeatures))
    expect(events.last[:variables].map(&:to_s)).to match_array(update.dig(:expectedAfterMerge, :changedVariables))

    f.set_datafile(update[:replacement], true)
    expect(f.get_feature_keys.map(&:to_s).sort).to eq(update.dig(:expectedAfterReplacement, :features).sort)
    expect(f.get_variable_keys.map(&:to_s).sort).to eq(update.dig(:expectedAfterReplacement, :variables).sort)

    dependency = globals[:dependencyUpdateCase]
    dependency[:modes].each do |mode|
      sdk = Featurevisor.create_featurevisor(datafile: dependency[:initial], log_level: "fatal")
      captured = []
      sdk.on("datafile_set", ->(event) { captured << event })
      sdk.set_datafile(dependency[:updated], mode[:replace])
      expect(captured.last[:features].map(&:to_s)).to match_array(dependency[:expectedChangedFeatures])
      expect(captured.last[:variables].map(&:to_s)).to match_array(dependency[:expectedChangedVariables])
    end

    sdk = Featurevisor.create_featurevisor(datafile: dependency[:initial], log_level: "fatal")
    captured = []
    sdk.on("datafile_set", ->(event) { captured << event })
    sdk.set_datafile(dependency[:withoutSegment], true)
    expect(captured.last[:features].map(&:to_s)).to match_array(dependency[:expectedRemovedSegmentFeatures])
    expect(captured.last[:variables].map(&:to_s)).to match_array(dependency[:expectedRemovedSegmentVariables])
  end

  it "keeps child sticky variables isolated and runs unified module callbacks" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    datafile = fixture.dig(:globalVariables, :datafile)
    callbacks = []
    f = Featurevisor.create_featurevisor(
      datafile: datafile,
      sticky_variables: { stringValue: "parent" },
      log_level: "fatal",
      modules: [{
        name: "global-callbacks",
        before_evaluation: ->(options) { callbacks << [:before, options[:feature_key]]; options },
        after_evaluation: ->(evaluation, _options) { callbacks << [:after, evaluation[:feature_key]]; evaluation }
      }]
    )
    child = f.spawn({}, sticky_variables: { stringValue: "child" })
    expect(child.get_variable("stringValue")).to eq("child")
    child.set_sticky_variables({ stringValue: "changed" }, true)
    expect(child.get_variable("stringValue")).to eq("changed")
    expect(f.get_variable("stringValue")).to eq("parent")
    expect(callbacks).to include([:before, nil], [:after, nil])
  end
end
