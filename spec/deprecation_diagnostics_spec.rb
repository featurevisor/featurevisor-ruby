# frozen_string_literal: true

require "featurevisor"

RSpec.describe "deprecation diagnostics" do
  let(:captured) { [] }
  let(:sdk) do
    Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "4", revision: "1", segments: {},
        features: {
          legacy: {
            deprecated: true,
            bucketBy: "userId",
            variablesSchema: { old: { type: "string", defaultValue: "x", deprecated: true } },
            traffic: [{ key: "all", conditions: "*", percentage: 100_000, allocation: [] }]
          }
        },
        variables: { oldGlobal: { type: "string", defaultValue: "y", deprecated: true } }
      },
      log_level: "warn",
      on_diagnostic: ->(diagnostic) { captured << diagnostic[:code].to_s if diagnostic[:code].to_s.include?("deprecated") }
    )
  end

  after { sdk.close }

  it "reports deprecated features and variables with one code per kind" do
    sdk.is_enabled("legacy")
    expect(captured.uniq).to eq(["deprecated_feature"])

    captured.clear
    sdk.get_variable("legacy", "old")
    expect(captured.uniq.sort).to eq(%w[deprecated_feature deprecated_variable])

    captured.clear
    sdk.get_variable("oldGlobal")
    expect(captured).to eq(["deprecated_variable"])
  end
end
