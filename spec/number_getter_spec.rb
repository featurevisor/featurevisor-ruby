# frozen_string_literal: true

require "featurevisor"

RSpec.describe "number getters" do
  let(:sdk) do
    Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "4", revision: "1", segments: {}, features: {},
        variables: {
          rate: { type: "number", defaultValue: 2.5 },
          ratio: { type: "double", defaultValue: 1.5 }
        }
      },
      log_level: "fatal"
    )
  end

  after { sdk.close }

  it "reads number variables and earlier double variables the same way" do
    expect(sdk.get_variable_number("rate")).to eq(2.5)
    expect(sdk.get_variable_number("ratio")).to eq(1.5)
    expect(sdk.spawn({}).get_variable_number("rate")).to eq(2.5)
  end

  it "no longer has the double getters removed in v4" do
    expect(sdk).not_to respond_to(:get_variable_double)
    expect(sdk.spawn({})).not_to respond_to(:get_variable_double)
  end
end
