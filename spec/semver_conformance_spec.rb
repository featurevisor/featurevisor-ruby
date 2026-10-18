require "featurevisor"
require "json"
require_relative "../bin/test_checks"

RSpec.describe "Portable version comparisons" do
  fixture = JSON.parse(File.read(File.expand_path("../conformance/semver.json", __dir__), encoding: "UTF-8"))
  it "identifies the complete contract" do
    expect([fixture["kind"], fixture["version"], fixture["cases"].length]).to eq(["featurevisor.semver", 1, 44])
  end
  fixture["cases"].each do |entry|
    [false, true].each do |reverse|
      it "#{entry['name']} #{reverse ? 'reverse' : 'forward'}" do
        left, right = reverse ? [entry["right"], entry["left"]] : [entry["left"], entry["right"]]
        if entry["order"].nil?
          expect { Featurevisor.compare_versions(left, right) }.to raise_error(ArgumentError)
        else
          expect(Featurevisor.compare_versions(left, right)).to eq(reverse ? -entry["order"] : entry["order"])
        end
        order = entry["order"] && (reverse ? -entry["order"] : entry["order"])
        {
          "semverEquals" => order == 0,
          "semverNotEquals" => !order.nil? && order != 0,
          "semverGreaterThan" => !order.nil? && order > 0,
          "semverGreaterThanOrEquals" => !order.nil? && order >= 0,
          "semverLessThan" => !order.nil? && order < 0,
          "semverLessThanOrEquals" => !order.nil? && order <= 0
        }.each do |operator, expected|
          requirement = { variable: "source", operator: operator, value: right }
          feature_requirement = { feature: "sourceFeature", variable: "version", operator: operator, value: right }
          datafile = {
            schemaVersion: "2", revision: "semver", segments: {},
            features: {
              condition: { bucketBy: "userId", traffic: [], force: [{
                conditions: { attribute: "version", operator: operator, value: right }, enabled: true
              }] },
              sourceFeature: { bucketBy: "userId", traffic: [], force: [{ segments: "*", enabled: true }],
                variablesSchema: { version: { type: "string", defaultValue: left } } }
            },
            variables: {
              source: { type: "string", defaultValue: left },
              other: { type: "string", defaultValue: right },
              subject: { type: "boolean", defaultValue: true, disabledValue: false, conditions: [requirement] },
              negated: { type: "boolean", defaultValue: true, disabledValue: false, conditions: [{ not: [requirement] }] },
              featureSubject: { type: "boolean", defaultValue: true, disabledValue: false, conditions: [feature_requirement] },
              featureNegated: { type: "boolean", defaultValue: true, disabledValue: false, conditions: [{ not: [feature_requirement] }] }
            }
          }
          sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
          begin
            expect(sdk.is_enabled("condition", version: left)).to eq(expected), operator
            { "subject" => expected, "negated" => !expected, "featureSubject" => expected, "featureNegated" => !expected }.each do |variable, value|
              evaluation = sdk.evaluate_variable(variable)
              if order.nil?
                expect(evaluation[:reason]).to eq("error"), operator
              else
                expect(evaluation[:variable_value]).to eq(value), operator
              end
            end
            check = { variable: "source", operator: operator, compareTo: { variable: "other" } }
            [[check, expected], [{ not: [check] }, !expected]].each do |node, matched|
              result = FeaturevisorCLI::TestChecks.evaluate_result(
                sdk, datafile, [node], owner_variable: nil, diagnostics: []
              )
              expect(result[:error]).to eq(order.nil?), operator
              expect(result[:passed]).to eq(!order.nil? && matched), operator
            end
          ensure
            sdk.close
          end
        end
      end
    end
  end
end
