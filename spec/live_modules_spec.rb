# frozen_string_literal: true

require "featurevisor"

RSpec.describe "module membership between callback phases" do
  def feature(**values)
    { bucketBy: "userId", traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }.merge(values)
  end

  [false, true].each do |global_root|
    [false, true].product([false, true]).each do |removal, disable_gate|
      it "refreshes membership for global root #{global_root}, removal #{removal}, disabled gate #{disable_gate}" do
        trace = []
        key = ->(options) { options[:feature_key] || options[:variable_key] }
        mod = { name: "late",
                before_evaluation: ->(options) { trace << "before:#{key.call(options)}"; options },
                after_evaluation: ->(result, options) {
                  trace << "after:#{key.call(options)}"
                  disable_gate && key.call(options) == "gate" ? result.merge(enabled: false) : result
                } }
        condition = { or: [{ feature: "broken" }, { feature: "gate" }] }
        sdk = Featurevisor.create_featurevisor(log_level: "error", modules: removal ? [mod] : [], on_diagnostic: ->(diagnostic) {
          if diagnostic[:code] == "conditions_parse_error"
            removal ? sdk.remove_module("late") : sdk.add_module(mod)
          end
        }, datafile: {
          schemaVersion: "4", revision: "live", segments: {}, features: {
            broken: feature(conditions: "[broken"), gate: feature, subject: feature(conditions: condition)
          }, variables: { subject: { type: "string", defaultValue: "matched", conditions: condition } }
        })
        evaluation = global_root ? sdk.evaluate_variable("subject") : sdk.evaluate_flag("subject")
        if disable_gate && !removal
          expect(evaluation[:reason]).to eq("conditions_unmet")
          expect(global_root ? evaluation[:variable_value] : evaluation[:enabled]).to eq(global_root ? nil : false)
        else
          expect(global_root ? evaluation[:variable_value] : evaluation[:enabled]).to eq(global_root ? "matched" : true)
        end
        expect(trace).to eq(removal ? %w[before:subject before:broken] : %w[after:broken before:gate after:gate after:subject])
      ensure
        sdk&.close
      end
    end
  end

  it "keeps after phase membership stable once that phase starts" do
    trace = []
    added = { name: "added", after_evaluation: ->(result, _) { trace << "added"; result } }
    sdk = Featurevisor.create_featurevisor(log_level: "fatal", modules: [
      { name: "first", after_evaluation: ->(result, _) {
        trace << "first"
        sdk.add_module(added)
        sdk.remove_module("second")
        result
      } }, { name: "second", after_evaluation: ->(result, _) { trace << "second"; result } }
    ])
    sdk.evaluate_flag("missing")
    expect(trace).to eq(%w[first second])
  ensure
    sdk&.close
  end
end
