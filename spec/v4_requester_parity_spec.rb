# frozen_string_literal: true

require "featurevisor"

RSpec.describe "v4 requester and JSON getter parity" do
  def feature(**options)
    { bucketBy: [], traffic: [{ key: "all", conditions: "*", percentage: 100_000 }], **options }
  end

  def datafile
    { schemaVersion: "4", revision: "parity", segments: {}, features: {}, variables: {} }
  end

  def trace(input)
    input.select { |key, _| %i[type feature_key variable_key dependency_of dependency_purpose].include?(key) }
  end

  %w[variable variation].each do |type|
    [false, true].each do |composed|
      it "retains the original #{type} requester through its internal flag, composed #{composed}" do
        source = datafile
        source[:variables][:source] = { type: "boolean", defaultValue: true }
        source[:features][:gate] = feature(conditions: { variable: "source", operator: "equals", value: true })
        source[:features][:subject] = feature(
          conditions: [{ feature: "gate" }, { feature: "gate" }],
          variablesSchema: { value: { type: "string", defaultValue: "value" } },
          variations: [{ value: "treatment" }]
        )
        source[:features][:subject][:traffic][0][:variation] = "treatment"
        reference = type == "variable" ? { feature: "subject", variable: "value" } : { feature: "subject", variation: true }
        source[:variables][:screen] = { type: "object", compose: [{ key: "result", **reference }] }
        seen = []
        f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ before_evaluation: ->(input) { seen << trace(input); input } }])
        requester = { type: type, feature_key: "subject" }
        requester[:variable_key] = "value" if type == "variable"
        expected = [
          requester.merge(composed ? { dependency_of: { type: "variable", variable_key: "screen" }, dependency_purpose: "composition" } : {}),
          { type: "flag", feature_key: "gate", dependency_of: requester, dependency_purpose: "condition" },
          { type: "variable", variable_key: "source", dependency_of: { type: "flag", feature_key: "gate" }, dependency_purpose: "condition" }
        ]
        expected.unshift(type: "variable", variable_key: "screen") if composed
        2.times do
          seen.clear
          result = if composed
            f.get_variable("screen")[:result]
          elsif type == "variable"
            f.get_variable("subject", "value")
          else
            f.get_variation("subject")
          end
          expect(result).to eq(type == "variable" ? "value" : "treatment")
          expect(seen).to eq(expected)
        end
      ensure
        f&.close
      end
    end
  end

  [false, true].each do |feature_owned|
    [false, true].each do |negated|
      it "memoises malformed JSON as an ordinary null getter, feature owned #{feature_owned}, negated #{negated}" do
        source = datafile
        json = { type: "json", defaultValue: "{oops" }
        reference = { variable: "source", operator: "isNull" }
        identity = { type: "variable", variable_key: "source" }
        if feature_owned
          source[:features][:owner] = feature(variablesSchema: { source: json })
          reference[:feature] = "owner"
          identity[:feature_key] = "owner"
        else
          source[:variables][:source] = json
        end
        leaves = [reference, reference.dup]
        source[:features][:subject] = feature(conditions: negated ? { not: leaves } : leaves)
        diagnostics, seen = [], []
        f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { diagnostics << item },
          modules: [{ before_evaluation: ->(input) { seen << trace(input); input } }])
        2.times do |root|
          seen.clear
          result = f.evaluate_flag("subject")
          expect(result[:enabled]).to eq(!negated)
          expect(result[:reason]).to eq(negated ? "conditions_unmet" : "rule")
          expect(seen).to eq([
            { type: "flag", feature_key: "subject" },
            identity.merge(dependency_of: { type: "flag", feature_key: "subject" }, dependency_purpose: "condition")
          ])
          errors = diagnostics.select { |item| item[:message] == "getVariable failed" }
          expect(errors.length).to eq(root + 1)
          expect(errors.last).to include(level: "error", code: "evaluation_error")
          expect(errors.last[:details]).to eq(featureKey: feature_owned ? "owner" : nil, variableKey: "source")
          expect(errors.last[:originalError]).to be_a(JSON::ParserError)
          expect(diagnostics.length).to eq(root + 1)
        end
      ensure
        f&.close
      end
    end
  end

  it "does not invert variable comparison errors through NOT and recovers on the next request" do
    source = datafile
    source[:variables][:source] = { type: "string", defaultValue: "value" }
    source[:features][:subject] = feature(conditions: { not: [{ variable: "source", operator: "matches", value: "[" }] })
    source[:features][:healthy] = feature
    seen = []
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ before_evaluation: ->(input) { seen << trace(input); input } }])
    2.times do
      seen.clear
      expect(f.evaluate_flag("subject")).to include(reason: "error")
      expect(seen).to eq([
        { type: "flag", feature_key: "subject" },
        { type: "variable", variable_key: "source", dependency_of: { type: "flag", feature_key: "subject" }, dependency_purpose: "condition" }
      ])
      expect(f.is_enabled("healthy")).to be(true)
    end
  ensure
    f&.close
  end

  ['"null"', '{"nested":[1]}'].each do |raw|
    it "separates owned condition and borrowed composition memo entries and decodes #{raw} once per purpose" do
      source = datafile
      source[:variables][:source] = { type: "json", defaultValue: raw }
      source[:variables][:screen] = { type: "object", conditions: [{ variable: "source", operator: "notNull" }] * 2,
        compose: [{ key: "first", variable: "source" }, { key: "second", variable: "source" }] }
      seen, diagnostics = [], []
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { diagnostics << item },
        modules: [{ before_evaluation: ->(input) { seen << trace(input); input } }])
      allow(JSON).to receive(:parse).and_call_original
      expect(JSON).to receive(:parse).with(raw, symbolize_names: true).exactly(4).times.and_call_original
      previous = nil
      2.times do
        seen.clear
        result = f.get_variable("screen")
        expect(result[:first]).to eq(raw == '"null"' ? "null" : { nested: [1] })
        expect(result[:second]).to equal(result[:first])
        expect(result).not_to equal(previous) if previous
        previous = result
        expect(seen).to eq([
          { type: "variable", variable_key: "screen" },
          { type: "variable", variable_key: "source", dependency_of: { type: "variable", variable_key: "screen" }, dependency_purpose: "condition" },
          { type: "variable", variable_key: "source", dependency_of: { type: "variable", variable_key: "screen" }, dependency_purpose: "composition" }
        ])
        expect(diagnostics).to be_empty
      end
    ensure
      f&.close
    end
  end
end
