# frozen_string_literal: true

require "featurevisor"

RSpec.describe "Featurevisor v4 runtime" do
  def feature(**values)
    { bucketBy: "userId", traffic: [], **values }
  end

  it "uses empty and notEmpty in required variable groups and conditions" do
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "empty-operators",
        segments: {},
        features: {
          emptyContext: feature(
            force: [{ conditions: [{ attribute: "profile.items", operator: "empty" }], enabled: true }]
          ),
          nonemptyContext: feature(
            force: [{ conditions: [{ attribute: "profile.items", operator: "notEmpty" }], enabled: true }]
          )
        },
        variables: {
          emptyArray: { type: "array", defaultValue: [] },
          nonemptyObject: { type: "object", defaultValue: { value: nil } },
          nilValue: { type: "json", defaultValue: nil },
          emptyGate: {
            type: "boolean", defaultValue: true, disabledValue: false,
            conditions: [{ variable: "emptyArray", operator: "empty" }]
          },
          nonemptyGate: {
            type: "boolean", defaultValue: true, disabledValue: false,
            conditions: [{ variable: "nonemptyObject", operator: "notEmpty" }]
          },
          nilGate: {
            type: "boolean", defaultValue: true, disabledValue: false,
            conditions: [{ variable: "nilValue", operator: "notEmpty" }]
          }
        }
      },
      log_level: "fatal"
    )

    expect(sdk.is_enabled("emptyContext", profile: { items: [] })).to be true
    expect(sdk.is_enabled("nonemptyContext", profile: { items: [nil] })).to be true
    expect(sdk.get_variable("emptyGate")).to be true
    expect(sdk.get_variable("nonemptyGate")).to be true
    expect(sdk.get_variable("nilGate")).to be false
  ensure
    sdk&.close
  end

  it "treats an empty override program as authoritative and rejects malformed jumps" do
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "programs", segments: {}, features: {},
        variables: {
          subject: {
            type: "object", defaultValue: { default: true }, overrideProgram: [],
            overrides: [{ key: "must-not-run", segments: "*", value: { legacy: true } }]
          },
          broken: {
            type: "object", defaultValue: {},
            overrideProgram: [{ key: "bad", segments: "*", operations: [], onMatch: 0, onMiss: 1 }]
          }
        }
      },
      log_level: "fatal"
    )

    expect(sdk.get_variable("subject")).to eq(default: true)
    expect(sdk.evaluate_variable("subject")[:reason]).to eq("variable_default")
    expect(sdk.get_variable("broken")).to be_nil
    expect(sdk.evaluate_variable("broken")[:reason]).to eq("error")
  end

  it "publishes one final accumulated value and its complete metadata to modules" do
    observed = []
    datafile = {
      schemaVersion: "2", revision: "callbacks", segments: {}, features: {},
      variables: {
        subject: {
          type: "object", defaultValue: { trace: [] },
          overrideProgram: [
            { key: "parent", keyPath: ["parent"], segments: "*", operations: [{ op: "append", path: ["trace"], value: "parent" }], onMatch: 1, onMiss: 2 },
            { key: "child", keyPath: ["parent", "child"], segments: "*", operations: [{ op: "append", path: ["trace"], value: "child" }], onMatch: 2, onMiss: 2 }
          ]
        }
      }
    }
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile,
      log_level: "fatal",
      modules: [{
        name: "observer",
        after_evaluation: ->(evaluation, _options) {
          observed << [evaluation[:variable_value], evaluation[:variable_override_paths]]
          evaluation
        }
      }]
    )

    expect(sdk.get_variable("subject")).to eq(trace: %w[parent child])
    expect(observed).to eq([[{ trace: %w[parent child] }, [["parent"], %w[parent child]]]])
    expect(datafile.dig(:variables, :subject, :defaultValue)).to eq(trace: [])
  end

  it "uses ordinary getter fallback for source errors but keeps current comparator errors" do
    datafile = {
      schemaVersion: "2", revision: "requirement-errors", segments: {}, features: {},
      variables: {
        source: { type: "object", defaultValue: { items: [nil] } },
        sourceString: { type: "string", defaultValue: "value" },
        subject: {
          type: "string", defaultValue: "matched",
          conditions: [{ variable: "source", operator: "isNull" }]
        },
        badComparator: {
          type: "string", defaultValue: "bad",
          conditions: [{ variable: "sourceString", operator: "matches", value: "[" }]
        }
      }
    }
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile,
      log_level: "fatal",
      modules: [{
        name: "throw-source-only",
        before_evaluation: ->(options) { raise "source failed" if options[:variable_key] == "source"; options }
      }]
    )

    evaluation = sdk.evaluate_variable("subject")
    expect(evaluation[:variable_value]).to eq("matched")
    expect(evaluation[:reason]).to eq("variable_default")

    plain = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    expect(plain.evaluate_variable("badComparator")[:reason]).to eq("error")
  end

  it "treats a required feature module error as disabled for enabled false and NOT" do
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "required-feature-error", segments: {},
        features: {
          source: feature(traffic: [{ key: "all", segments: "*", percentage: 100_000 }]),
          disabledSource: feature(
            requiredFeatures: [{ feature: "source", enabled: false }],
            traffic: [{ key: "all", segments: "*", percentage: 100_000 }]
          ),
          notSource: feature(
            requiredFeatures: [{ not: ["source"] }],
            traffic: [{ key: "all", segments: "*", percentage: 100_000 }]
          )
        }
      },
      log_level: "fatal",
      modules: [{
        name: "throw-source-feature",
        before_evaluation: ->(options) { raise "source failed" if options[:feature_key] == "source"; options }
      }]
    )

    expect(sdk.evaluate_flag("source")[:reason]).to eq("error")
    expect(sdk.is_enabled("disabledSource")).to be true
    expect(sdk.is_enabled("notSource")).to be true
  end

  it "recovers after cycles and isolates simultaneous requirement stacks per thread" do
    cycle_sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "cycle", segments: {}, features: {},
        variables: {
          a: { type: "string", defaultValue: "a", conditions: [{ variable: "b", operator: "equals", value: "b" }] },
          b: { type: "string", defaultValue: "b", conditions: [{ variable: "a", operator: "equals", value: "a" }] },
          healthy: { type: "string", defaultValue: "ok" }
        }
      },
      log_level: "fatal"
    )
    expect(cycle_sdk.evaluate_variable("a")[:reason]).to eq("error")
    expect(cycle_sdk.get_variable("healthy")).to eq("ok")

    mutex = Mutex.new
    condition = ConditionVariable.new
    arrived = 0
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "threads", segments: {}, features: {},
        variables: {
          source: { type: "string", defaultValue: "none", overrides: [
            { key: "a", conditions: [{ attribute: "worker", operator: "equals", value: "a" }], value: "a" },
            { key: "b", conditions: [{ attribute: "worker", operator: "equals", value: "b" }], value: "b" }
          ] },
          subjectA: { type: "boolean", defaultValue: true, conditions: [{ variable: "source", operator: "equals", value: "a" }] },
          subjectB: { type: "boolean", defaultValue: true, conditions: [{ variable: "source", operator: "equals", value: "b" }] }
        }
      },
      log_level: "fatal",
      modules: [{
        name: "rendezvous",
        before_evaluation: ->(options) {
          if options[:variable_key] == "source"
            mutex.synchronize do
              arrived += 1
              condition.broadcast if arrived == 2
              condition.wait(mutex, 1) while arrived < 2
            end
          end
          options
        }
      }]
    )
    threads = [["subjectA", "a"], ["subjectB", "b"]].map do |key, worker|
      Thread.new { sdk.get_variable(key, { worker: worker }) }
    end
    expect(threads.map(&:value)).to eq([true, true])
  end

  it "uses JavaScript own array property semantics for compiled requirement paths" do
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "requirement-paths", segments: {}, features: {},
        variables: {
          array: { type: "array", defaultValue: ["first"] },
          object: { type: "object", defaultValue: { "0": "object-first" } },
          stringIndex: { type: "boolean", defaultValue: true, conditions: [{ variable: "array", path: ["0"], operator: "equals", value: "first" }] },
          numericIndex: { type: "boolean", defaultValue: true, conditions: [{ variable: "array", path: [0], operator: "equals", value: "first" }] },
          length: { type: "boolean", defaultValue: true, conditions: [{ variable: "array", path: ["length"], operator: "equals", value: 1.0 }] },
          numericObject: { type: "boolean", defaultValue: true, conditions: [{ variable: "object", path: [0], operator: "notExists" }] }
        }
      },
      log_level: "fatal"
    )

    %w[stringIndex numericIndex length numericObject].each do |key|
      expect(sdk.get_variable(key)).to be true
    end
  end

  it "accepts safe integral numeric path components and rejects invalid ones" do
    mutations = Featurevisor.const_get(:Mutations, false)
    expect(mutations.apply(
      %w[zero one],
      [{ op: "set", path: [1.0], value: "changed" }]
    )).to eq(%w[zero changed])
    expect(mutations.apply(
      ["zero"],
      [{ op: "set", path: [9_007_199_254_740_991.0], value: "ignored" }]
    )).to eq(["zero"])

    [-1, 1.5, 9_007_199_254_740_992, 9_007_199_254_740_992.0, true, Float::NAN, Float::INFINITY].each do |part|
      expect do
        mutations.apply(%w[zero one], [{ op: "set", path: [part], value: "invalid" }])
      end.to raise_error(ArgumentError)
    end

    datafile = {
      schemaVersion: "2", revision: "numeric-paths", segments: {}, features: {},
      variables: {
        source: { type: "array", defaultValue: %w[zero one] },
        mutated: {
          type: "array", defaultValue: %w[zero one],
          overrideProgram: [{
            key: "raw", segments: "*",
            operations: [{ op: "set", path: [1.0], value: "changed" }],
            onMatch: 1, onMiss: 1
          }]
        },
        gate: {
          type: "string", defaultValue: "matched", disabledValue: "miss",
          conditions: [{ variable: "source", path: [1.0], operator: "equals", value: "one" }]
        }
      }
    }
    raw = JSON.generate(datafile)
    expect(raw).to include('"path":[1.0]')
    sdk = Featurevisor.create_featurevisor(datafile: raw, log_level: "fatal")
    expect(sdk.get_variable("mutated")).to eq(%w[zero changed])
    expect(sdk.get_variable("gate")).to eq("matched")

    [-1, 1.5, 9_007_199_254_740_992, 9_007_199_254_740_992.0, true].each do |part|
      invalid = Marshal.load(Marshal.dump(datafile))
      invalid[:variables][:gate][:conditions][0][:path] = [part]
      invalid_sdk = Featurevisor.create_featurevisor(datafile: invalid, log_level: "fatal")
      expect(invalid_sdk.evaluate_variable("gate")[:reason]).to eq("error")
      invalid_sdk.close
    end
    sdk.close
  end

  it "isolates child sticky state while resolving variable requirements" do
    datafile = {
      schemaVersion: "2", revision: "children", segments: {},
      features: {
        source: feature(variablesSchema: { plan: { type: "string", defaultValue: "free" } }),
        subject: feature(
          conditions: [{ feature: "source", variable: "plan", operator: "equals", value: "pro" }],
          traffic: [{ key: "all", segments: "*", percentage: 100_000 }]
        )
      },
      variables: {
        globalSource: { type: "string", defaultValue: "free" },
        globalSubject: {
          type: "string", defaultValue: "allowed",
          conditions: [{ variable: "globalSource", operator: "equals", value: "pro" }]
        }
      }
    }
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile,
      sticky_features: { source: { enabled: true, variables: { plan: "pro" } } },
      sticky_variables: { globalSource: "pro" },
      log_level: "fatal"
    )
    default_child = sdk.spawn
    child = sdk.spawn({}, sticky_features: {})

    expect(sdk.is_enabled("subject")).to be true
    expect(sdk.get_variable("globalSubject")).to eq("allowed")
    expect(default_child.is_enabled("subject")).to be false
    expect(default_child.evaluate_variable("globalSubject")[:reason]).to eq("conditions_unmet")
    expect(child.is_enabled("subject")).to be false
    child.set_sticky_features({ source: { enabled: true, variables: { plan: "pro" } } })
    expect(child.is_enabled("subject")).to be true
  end

  it "propagates mixed feature and variable dependency updates to a fixed point" do
    initial = {
      schemaVersion: "2", revision: "one", segments: {},
      features: {
        checkout: feature(conditions: [{ variable: "currency", operator: "equals", value: "EUR" }], hash: "checkout"),
        receipt: feature(requiredFeatures: ["checkout"], hash: "receipt")
      },
      variables: {
        currency: { type: "string", defaultValue: "EUR", hash: "one" },
        summary: { type: "string", defaultValue: "", conditions: [{ feature: "receipt", variable: "title", operator: "equals", value: "Receipt" }], hash: "summary" },
        final: { type: "string", defaultValue: "", conditions: [{ variable: "summary", operator: "equals", value: "" }], hash: "final" }
      }
    }
    updated = {
      schemaVersion: "2", revision: "two", segments: {}, features: {},
      variables: { currency: { type: "string", defaultValue: "USD", hash: "two" } }
    }
    events = []
    sdk = Featurevisor.create_featurevisor(datafile: initial, log_level: "fatal")
    sdk.on("datafile_set", ->(event) { events << event })
    sdk.set_datafile(updated)

    expect(events.last[:features]).to eq(%i[checkout receipt])
    expect(events.last[:variables]).to eq(%i[currency summary final])
  end

  it "keeps precomputed and runtime first-match trees equivalent through child and datafile state" do
    fixture = JSON.parse(
      File.read(File.expand_path("../conformance/sdk-v4-cases.json", __dir__), encoding: "UTF-8"),
      symbolize_names: true
    )
    names = [
      "first match precomputed parsed: child",
      "first match runtime parsed: child"
    ]
    cases = names.map { |name| fixture[:cases].find { |item| item[:name] == name } }
    expect(cases).not_to include(nil)

    child_value = {
      stage: "parent",
      rows: [{ id: 0, tags: [] }, { id: 1, tags: %w[parent child] }],
      flags: ["a"]
    }
    fallback_value = { stage: "fallback", rows: [], flags: ["a"] }
    sticky_value = { stage: "sticky", rows: [], flags: [nil] }
    replacement_value = { stage: "replacement", rows: [], flags: [] }

    cases.each do |test_case|
      datafile = JSON.parse(JSON.generate(test_case[:datafile]), symbolize_names: true)
      original_variables = JSON.generate(datafile[:variables])
      sdk = Featurevisor.create_featurevisor(
        datafile: datafile,
        context: test_case[:context],
        log_level: "fatal"
      )
      child = sdk.spawn(country: "be", city: "rotterdam")
      sticky_child = sdk.spawn({}, sticky_variables: { subject: sticky_value })

      2.times do
        expect(sdk.get_variable("subject")).to eq(child_value)
        expect(sdk.evaluate_variable("subject")[:variable_value]).to eq(child_value)
        expect(child.get_variable("subject")).to eq(fallback_value)
        expect(sticky_child.get_variable("subject")).to eq(sticky_value)
      end

      sticky_child.set_sticky_variables({}, true)
      expect(sticky_child.get_variable("subject")).to eq(child_value)

      replacement = {
        schemaVersion: "2", revision: "replacement", segments: {}, features: {},
        variables: { subject: { type: "object", defaultValue: replacement_value } }
      }
      sdk.set_datafile(replacement, true)
      expect(sdk.get_variable("subject")).to eq(replacement_value)
      expect(child.get_variable("subject")).to eq(replacement_value)

      sdk.set_datafile(datafile)
      expect(sdk.get_variable("subject")).to eq(child_value)
      expect(child.get_variable("subject")).to eq(fallback_value)
      expect(JSON.generate(datafile[:variables])).to eq(original_variables)
    ensure
      sticky_child&.close
      child&.close
      sdk&.close
    end
  end

  it "ignores the removed legacy required field" do
    sdk = Featurevisor.create_featurevisor(
      datafile: {
        schemaVersion: "2", revision: "legacy", segments: {},
        features: {
          disabled: feature(force: [{ segments: "*", enabled: false }]),
          subject: feature(required: ["disabled"], traffic: [{ key: "all", segments: "*", percentage: 100_000 }])
        }
      },
      log_level: "fatal"
    )

    expect(sdk.is_enabled("subject")).to be true
  end
end
