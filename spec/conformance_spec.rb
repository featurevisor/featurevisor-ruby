# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "Featurevisor v3 conformance" do
  it "uses the shared inclusive allocation contract" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-v3.json", __dir__)), symbolize_names: true)
    reader = Featurevisor.const_get(:DatafileReader).new(
      datafile: { schemaVersion: "2", revision: "conformance", segments: {}, features: {} },
      logger: Featurevisor.const_get(:Logger).new(level: "fatal")
    )
    traffic = { allocation: fixture.dig(:bucketing, :allocations) }

    fixture.dig(:bucketing, :allocationExpectations).each do |bucket, expected|
      allocation = reader.get_matched_allocation(traffic, bucket.to_s.to_i)
      expect(allocation[:variation]).to eq(expected)
    end
  end
end
