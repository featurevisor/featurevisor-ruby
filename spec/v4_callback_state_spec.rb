# frozen_string_literal: true

require "featurevisor"

RSpec.describe "v4 callback state changes" do
  def flag(conditions = "*")
    { bucketBy: [], conditions: conditions,
      traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
  end

  def datafile(segment)
    { schemaVersion: "4", revision: segment, segments: { gate: { conditions: segment } },
      features: { subject: flag([{ variable: "mutator", operator: "notNull" }, "alias"]),
                  healthy: flag },
      variables: { mutator: { type: "boolean", defaultValue: true },
                   subject: { type: "object", conditions: [{ variable: "mutator", operator: "notNull" }, "alias"],
                              compose: [{ key: "value", variable: "source" }] },
                   source: { type: "string", defaultValue: "source" } } }.tap do |value|
      value[:segments][:alias] = { conditions: "gate" }
    end
  end

  [false, true].each do |attribute_terminal|
    [[0, 256], [0, 257], [0, 258], [1, 255], [1, 256], [1, 257],
     [128, 128], [128, 129], [128, 130]].each do |getters, segments|
      it "matches the JS depth bound for #{getters} getters and #{segments} segments, attribute terminal #{attribute_terminal}" do
        source = datafile("*")
        terminal = attribute_terminal ? { attribute: "country", operator: "equals", value: "nl" } : "*"
        segments.times do |index|
          source[:segments]["s#{index}".to_sym] = { conditions: index == segments - 1 ? terminal : "s#{index + 1}" }
        end
        (0..getters).each do |index|
          source[:variables]["g#{index}".to_sym] = index == getters ?
            { type: "boolean", conditions: "s0", defaultValue: true } :
            { type: "boolean", compose: "g#{index + 1}" }
        end
        source[:features][:depth] = flag("s0")
        f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
        failed = getters + segments - (attribute_terminal ? 1 : 0) > 256
        2.times do
          evaluation = f.evaluate_variable("g0", country: "nl")
          expect(evaluation[:reason]).to eq(failed ? "error" : getters.zero? ? "variable_default" : "variable_composed")
          expect(f.get_variable("g0", country: "nl")).to eq(failed ? nil : true)
          if getters.zero?
            expect(f.evaluate_flag("depth", country: "nl")[:reason]).to eq(failed ? "error" : "rule")
            expect(f.is_enabled("depth", country: "nl")).to eq(!failed)
          end
          expect(f.is_enabled("healthy")).to be(true)
        end
      ensure
        f&.close
      end
    end
  end

  [nil, "[", {}, false, 1, [], [nil]].each do |operand|
    it "rejects nonarray NOT #{operand.inspect} without rejecting the valid null child" do
      source = datafile("*")
      expression = { not: operand }
      source[:segments][:operand] = { conditions: expression }
      source[:features][:direct] = flag(expression)
      source[:features][:segment] = flag("operand")
      source[:features][:encoded] = flag(JSON.generate(expression))
      errors = []
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { errors << item })
      %w[direct segment encoded].each do |key|
        2.times { expect(f.is_enabled(key)).to eq(operand == [nil]) }
      end
      expect(errors.none? { |item| item[:code] == "conditions_parse_error" }).to be(true)
    ensure
      f&.close
    end
  end

  it "distinguishes explicit null conditions from an absent root gate" do
    source = datafile("*")
    source[:variables][:absent] = { type: "string", defaultValue: "ordinary" }
    source[:variables][:null] = { type: "string", defaultValue: "ordinary", conditions: nil, disabledValue: "disabled" }
    source[:features][:absent] = flag.tap { |value| value.delete(:conditions) }
    source[:features][:null] = flag(nil)
    f = Featurevisor.create_featurevisor(datafile: JSON.generate(source), log_level: "fatal")
    expect(f.get_variable("absent")).to eq("ordinary")
    expect(f.evaluate_variable("null")).to include(reason: "conditions_unmet", conditions: nil, variable_value: "disabled")
    expect(f.is_enabled("absent")).to be(true)
    expect(f.evaluate_flag("null")).to include(reason: "conditions_unmet", conditions: nil, enabled: false)
  ensure
    f&.close
  end

  ["source", [{ key: "value", variable: "source" }]].each do |compose|
    [:absent, nil, false, "[1]"].each do |disabled|
      it "keeps gated #{compose.is_a?(String) ? 'alias' : 'map'} fallback #{disabled.inspect} ahead of caller and module defaults" do
        source = datafile("*")
        variable = { type: "json", compose: compose, conditions: nil, overrideProgram: [
          { key: "wrong", conditions: "*", operations: [{ op: "set", path: [], value: "override" }], onMatch: 1, onMiss: 1 }
        ] }
        variable[:disabledValue] = disabled unless disabled == :absent
        source[:variables][:view] = variable
        source[:variables][:source] = { type: "json", defaultValue: "{" }
        reads, errors = [], []
        f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { errors << item },
          modules: [{ before_evaluation: ->(options) {
            reads << options[:variable_key]
            options.merge(default_variable_value: "module")
          } }])
        expected = disabled == :absent ? nil : disabled
        expect(f.evaluate_variable("view", {}, default_variable_value: "caller")).to include(
          reason: "conditions_unmet", conditions: nil, variable_value: expected)
        expect(f.get_variable("view", {}, default_variable_value: "caller")).to eq(expected)
        expect(reads).to eq(["view", "view"])
        expect(errors).to be_empty
      ensure
        f&.close
      end
    end
  end

  it "notifies transitive dependants on missing source addition and removal before reentrant event reads" do
    source = datafile("*")
    source[:variables].delete(:source)
    source[:variables].delete(:subject)
    source[:variables][:alias] = { type: "object", compose: "source" }
    source[:variables][:view] = { type: "object", compose: [
      { key: "enabled", feature: "subject" }, { key: "value", variable: "alias" }
    ] }
    source[:segments][:bridge] = { conditions: '{"variable":"alias","operator":"notNull"}' }
    source[:features][:subject] = flag("bridge")
    source[:features][:broken] = flag("[")
    errors, events, values = [], [], []
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { errors << item })
    f.on("datafile_set", ->(event) { events << event; values << f.get_variable("view") })
    expect(f.get_variable("view")).to eq(enabled: false, value: nil)
    expect(f.set_datafile({ schemaVersion: "4", revision: "added", segments: {}, features: {},
                           variables: { source: { hash: "source", type: "boolean", defaultValue: false } } })).to be(true)
    expect(f.set_datafile(source, true)).to be(true)
    expect(values).to eq([{ enabled: true, value: false }, { enabled: false, value: nil }])
    events.each do |event|
      expect(event[:features]).to include(:subject)
      expect(event[:variables]).to include(:source, :alias, :view)
    end
    expect(errors).to be_empty
  ensure
    f&.close
  end

  %i[context sticky datafile module module_remove module_unsubscribe].each do |change|
    it "invalidates borrowed source memos after #{change} changes without leaking outer defaults or decoding JSON twice" do
      source = datafile("*")
      source[:features][:disabled] = flag({ or: [] }).merge(
        variablesSchema: { value: { type: "json", defaultValue: '"wrong"', disabledValue: false } })
      source[:variables][:source] = { type: "json", defaultValue: '"null"' }
      source[:variables][:view] = { type: "object", compose: [
        { key: "first", variable: "source" }, { key: "mutator", variable: "mutator" },
        { key: "second", variable: "source" }, { key: "third", variable: "source" },
        { key: "missing", variable: "missing" }, { key: "flag", feature: "missing" },
        { key: "disabled", feature: "disabled", variable: "value" }
      ] }
      context = { payload: { encoded: '"null"' } }
      reads = []
      f = nil
      unsubscribe = nil
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{
        before_evaluation: ->(options) {
          reads << options.slice(:dependency_of, :dependency_purpose) if options[:variable_key] == "source"
          options
        },
        after_evaluation: ->(result, options) {
          if options[:variable_key] == "source" && change == :context
            result = result.merge(variable_value: options[:context][:payload][:encoded])
          elsif options[:variable_key] == "mutator"
            case change
            when :context then options[:context][:payload][:encoded] = '"[1]"'
            when :sticky then f.set_sticky_variables({ "source" => '"[1]"' }, true)
            when :datafile
              expect(f.set_datafile({ schemaVersion: "4", revision: "updated", segments: {}, features: {},
                                     variables: { source: { type: "json", defaultValue: '"[1]"' } } })).to be(true)
            when :module
              f.add_module(after_evaluation: ->(value, input) {
                input[:variable_key] == "source" ? value.merge(variable_value: '"[1]"') : value
              })
            when :module_remove then f.remove_module("source")
            when :module_unsubscribe then unsubscribe.call
            end
          end
          result
        }
      }])
      removing = %i[module_remove module_unsubscribe].include?(change)
      if removing
        unsubscribe = f.add_module(name: "source", after_evaluation: ->(result, options) {
          options[:variable_key] == "source" ? result.merge(variable_value: '"[1]"') : result
        })
      end
      expect(f.get_variable("view", context, default_variable_value: "outer")).to eq(
        first: removing ? "[1]" : "null", mutator: true, second: removing ? "null" : "[1]",
        third: removing ? "null" : "[1]", missing: nil, flag: false, disabled: false)
      expect(reads).to eq([{ dependency_of: { type: "variable", variable_key: "view" }, dependency_purpose: "composition" }] * 2)
      expect(f.is_enabled("healthy")).to be(true)
    ensure
      f&.close
    end
  end

  %w[feature variable].each do |kind|
    [false, true].each do |malformed|
      it "uses current segments after a module replaces data during a #{kind} root, malformed #{malformed}" do
        errors, reads = [], []
        f = nil
        updated = false
        replacement = datafile(malformed ? "[" : { or: [] })
        replacement[:revision] = "replacement"
        f = Featurevisor.create_featurevisor(datafile: datafile("*"), log_level: "error",
          on_diagnostic: ->(item) { errors << item }, modules: [{
            before_evaluation: ->(options) { reads << options.slice(:type, :variable_key, :feature_key, :dependency_of, :dependency_purpose); options },
            after_evaluation: ->(result, options) {
              if options[:variable_key] == "mutator" && !updated
                updated = true
                expect(f.set_datafile(replacement, true)).to be(true)
                expect(f.is_enabled("healthy")).to be(true)
              end
              result
            }
          }])
        evaluation = kind == "feature" ? f.evaluate_flag("subject") : f.evaluate_variable("subject")
        expect(evaluation[:reason]).to eq("conditions_unmet")
        expect(evaluation[:enabled]).to be(false) if kind == "feature"
        expect(evaluation[:variable_value]).to be_nil if kind == "variable"
        expect(reads.none? { |item| item[:variable_key] == "source" }).to be(true)
        expect(reads.find { |item| item[:variable_key] == "mutator" }).to include(
          dependency_of: kind == "feature" ? { type: "flag", feature_key: "subject" } : { type: "variable", variable_key: "subject" },
          dependency_purpose: "condition")
        expect(errors.count { |item| item[:code] == "conditions_parse_error" }).to eq(malformed ? 1 : 0)
        expect(f.is_enabled("healthy")).to be(true)
      ensure
        f&.close
      end
    end
  end
end
