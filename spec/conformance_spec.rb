# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "Featurevisor v3 conformance" do
  it "uses the shared inclusive allocation contract" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    expect(fixture[:version]).to eq(2)
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
    evaluated = featurevisor.get_all_evaluations(
      {},
      [],
      default_variation_value: aggregate_case[:defaultVariationValue]
    )[:experiment]
    expect(evaluated[:enabled]).to eq(aggregate_case.dig(:expected, :enabled))
    expect(evaluated[:variation]).to eq(aggregate_case.dig(:expected, :variation))
  end
end
