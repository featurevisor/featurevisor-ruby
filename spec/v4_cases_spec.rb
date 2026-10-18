# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "Featurevisor v4 portable conformance" do
  fixture_path = File.expand_path("../conformance/sdk-v4-cases.json", __dir__)
  fixture = JSON.parse(File.read(fixture_path, encoding: "UTF-8"), symbolize_names: true)

  def json_value(value)
    JSON.parse(JSON.generate(value))
  end

  def instance_options(options)
    keys = {
      context: :context,
      logLevel: :log_level,
      stickyFeatures: :sticky_features,
      stickyVariables: :sticky_variables
    }
    options.to_h { |key, value| [keys.fetch(key), value] }
  end

  it "runs all 255 cases twice through the getter and detailed evaluation" do
    expect(fixture[:version]).to eq(1)
    expect(fixture[:cases].length).to eq(255)

    fixture[:cases].each do |test_case|
      input = JSON.parse(JSON.generate(test_case[:datafile]), symbolize_names: true)
      original_variables = JSON.generate(input[:variables])
      options = instance_options(test_case[:options] || {})
      sdk = Featurevisor.create_featurevisor({ log_level: "fatal", **options, datafile: input })
      context = test_case[:context] || {}
      expected = test_case[:expected]

      2.times do |run|
        aggregate_failures "#{test_case[:name]} run #{run + 1}" do
          expect(json_value(sdk.get_variable("subject", context))).to eq(json_value(expected[:value]))

          evaluation = sdk.evaluate_variable("subject", context)
          fields = {
            reason: :reason,
            variableOverridePaths: :variable_override_paths,
            variableOverrideKey: :variable_override_key,
            variableOverrideIndex: :variable_override_index,
            variableOverridePath: :variable_override_path
          }
          expected.each do |key, value|
            next if key == :value

            expect(json_value(evaluation[fields.fetch(key)])).to eq(json_value(value)), key.to_s
          end
        end
      end
      expect(JSON.generate(input[:variables])).to eq(original_variables)
      sdk.close
    end
  end
end
