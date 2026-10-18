# frozen_string_literal: true

require "featurevisor"

RSpec.describe "module phase snapshots" do
  phases = %i[before_evaluation bucket_key bucket_value after_evaluation]
  [false, true].product(phases, %i[add remove_add remove unsubscribe]).each do |global_root, changed_phase, action|
    it "snapshots global #{global_root}, #{changed_phase}, #{action}" do
      trace = []
      closed = []
      changed = false
      sdk = nil
      unsubscribe = nil
      make_module = nil
      make_module = ->(name) {
        hooks = phases.to_h do |phase|
          [phase, ->(*args) {
            options = args.last
            active = %i[bucket_key bucket_value].include?(phase) ||
              (global_root ? options[:variable_key] == "subject" : options[:feature_key] == "gate")
            if active
              trace << "#{phase}:#{name}"
              if name == "first" && phase == changed_phase && !changed
                changed = true
                if action == :unsubscribe
                  unsubscribe.call
                elsif action != :add
                  sdk.remove_module("other")
                end
                sdk.add_module(make_module.call("late")) if %i[add remove_add].include?(action)
              end
            end
            %i[bucket_key bucket_value].include?(phase) ? options[phase] : args.first
          }]
        end
        hooks.merge(name: name, close: -> { closed << name })
      }
      sdk = Featurevisor.create_featurevisor(log_level: "fatal", datafile: {
        schemaVersion: "4", revision: "phases", segments: {}, features: {
          gate: { bucketBy: "userId", traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
        }, variables: { subject: { type: "string", defaultValue: "matched", conditions: { feature: "gate" } } }
      })
      sdk.add_module(make_module.call("first"))
      unsubscribe = sdk.add_module(make_module.call("other"))
      evaluate = -> {
        result = global_root ? sdk.evaluate_variable("subject") : sdk.evaluate_flag("gate")
        expect(global_root ? result[:variable_value] : result[:enabled]).to eq(global_root ? "matched" : true)
      }
      evaluate.call
      after = ["first"] + (action == :add ? ["other"] : []) + (%i[add remove_add].include?(action) ? ["late"] : [])
      expected = phases.each_with_index.flat_map do |phase, index|
        (index <= phases.index(changed_phase) ? %w[first other] : after).map { |name| "#{phase}:#{name}" }
      end
      expect(trace).to eq(expected)
      expect(closed).to eq(action == :add ? [] : ["other"])
      trace.clear
      evaluate.call
      expect(trace).to eq(phases.flat_map { |phase| after.map { |name| "#{phase}:#{name}" } })
    ensure
      sdk&.close
    end
  end
end
