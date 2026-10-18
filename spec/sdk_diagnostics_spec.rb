# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "shared SDK diagnostics" do
  fixture = JSON.parse(File.read(File.expand_path("../conformance/sdk-diagnostics.json", __dir__), encoding: "UTF-8"), symbolize_names: true)

  it "identifies the shared diagnostics contract" do
    expect(fixture[:kind]).to eq("featurevisor.sdk-diagnostics")
    expect(fixture[:version]).to eq(1)
    expect(fixture[:cases]).not_to be_empty
  end

  fixture[:cases].cycle(2).each_with_index do |test_case, index|
    it "#{test_case[:name]} (run #{index / fixture[:cases].length + 1})" do
      captured = []
      reentering = false
      f = Featurevisor.create_featurevisor(log_level: "error", on_diagnostic: ->(diagnostic) {
        next unless diagnostic[:code] == "conditions_parse_error"
        captured << diagnostic.slice(:code, :level, :details).merge(revision: f.get_revision)
        next if reentering || diagnostic[:details][:entityType] != "feature"
        before = captured.length
        begin
          reentering = true
          f.is_enabled(diagnostic[:details][:entityKey])
        ensure
          reentering = false
        end
        expect(captured.length).to eq(before), "reentry must not report another diagnostic"
      })
      test_case[:operations].each_with_index do |operation, index|
        before = captured.length
        result = case operation[:action]
        when "setDatafile" then f.set_datafile(operation[:datafile], operation[:replace])
        when "isEnabled" then f.is_enabled(operation[:feature])
        else raise "Unknown diagnostics operation: #{operation[:action]}"
        end
        expect(result).to equal(operation[:expectedResult]), "operation #{index}: #{operation[:action]}"
        expect(captured.drop(before)).to match_array(operation[:diagnostics]), "operation #{index}: #{operation[:action]} diagnostics"
      end
    ensure
      f&.close
    end
  end
end
