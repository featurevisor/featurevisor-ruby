# frozen_string_literal: true

require "featurevisor"

RSpec.describe "request evaluation sessions" do
  it "does not enumerate unrelated sticky entries during repeated feature and variable reads" do
    [0, 100, 1000, 5000].each do |size|
      unrelated = size.times.to_h { |index| ["unrelated#{index}", Object.new] }
      reads = { flag: 0, variable: 0 }
      sdk = Featurevisor.create_featurevisor(
        datafile: datafile(features: { leafFlag: feature }, variables: {
          source: variable,
          root: { type: "integer", defaultValue: 1,
                  requiredFeatures: ["leafFlag", "leafFlag"],
                  conditions: [requires("source"), requires("source")] }
        }), log_level: "fatal", sticky_features: unrelated, sticky_variables: unrelated,
        modules: [{ before_evaluation: ->(options) {
          reads[:flag] += 1 if options[:feature_key] == "leafFlag"
          reads[:variable] += 1 if options[:variable_key] == "source"
          options
        } }]
      )
      child = sdk.spawn({}, sticky_features: unrelated, sticky_variables: unrelated)
      begin
        [sdk, child].each do |owner|
          reads = { flag: 0, variable: 0 }
          expect(owner.get_variable("root", { userId: "u" })).to eq(1)
          expect(reads).to eq({ flag: 1, variable: 1 }), "size #{size}"
        end
        child.set_sticky_variables({ "source" => 2 })
        expect(child.evaluate_variable("root", { userId: "u" })[:reason]).to eq("conditions_unmet")
        expect(sdk.get_variable("root", { userId: "u" })).to eq(1)
      ensure
        child.close
        sdk.close
      end
    end
  end

  it "carries module sticky replacements into nested feature and variable reads" do
    reads = { flag: 0, variable: 0 }
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(features: {
        leafFlag: feature(traffic: []),
        rootFlag: feature(requiredFeatures: ["leafFlag", "leafFlag"],
                          conditions: [{ variable: "source", operator: "equals", value: 2 }] * 2)
      }, variables: { source: variable }), log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        if options[:feature_key] == "rootFlag"
          options = options.merge(sticky: { "leafFlag" => { enabled: true } }, sticky_variables: { "source" => 2 })
        end
        reads[:flag] += 1 if options[:feature_key] == "leafFlag"
        reads[:variable] += 1 if options[:variable_key] == "source"
        options
      } }]
    )
    child = sdk.spawn
    [sdk, child].each do |owner|
      reads = { flag: 0, variable: 0 }
      expect(owner.is_enabled("rootFlag", { userId: "u" })).to be(true)
      expect(reads).to eq({ flag: 1, variable: 1 })
    end
  ensure
    child&.close
    sdk&.close
  end

  def datafile(features: {}, variables: {})
    { schemaVersion: "2", revision: "session", segments: {}, features: features, variables: variables }
  end

  def feature(**values)
    { bucketBy: "userId", traffic: [{ key: "all", segments: "*", percentage: 100_000 }], **values }
  end

  def variable(required = nil)
    { type: "integer", defaultValue: 1, disabledValue: 0 }.tap { |value| value[:conditions] = required unless required.nil? }
  end

  def requires(key)
    { variable: key, operator: "equals", value: 1 }
  end

  it "memoises completed variable and feature diamonds per public read" do
    variables = { leaf: variable }
    features = { leaf: feature }
    previous = "leaf"
    12.times do |index|
      variables["level#{index}".to_sym] = variable([requires(previous), requires(previous)])
      features["level#{index}".to_sym] = feature(requiredFeatures: [previous, previous])
      previous = "level#{index}"
    end
    seen = []
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(features: features, variables: variables), log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        seen << [options[:type], options[:feature_key], options[:variable_key], options[:dependency_of]]
        options.dup
      } }]
    )

    expect(sdk.get_variable(previous)).to eq(1)
    expect(seen.length).to eq(13)
    expect(seen[0][3]).to be_nil
    expect(seen[1][3]).to eq(type: "variable", variable_key: previous)
    seen.clear
    expect(sdk.is_enabled(previous)).to be(true)
    expect(seen.length).to eq(13)
    expect(seen[1][3]).to eq(type: "flag", feature_key: previous)
    seen.clear
    expect(sdk.get_variable(previous)).to eq(1)
    expect(seen.length).to eq(13)
  ensure
    sdk&.close
  end

  it "reports root and nested cycles as errors while preserving ordinary getter fallback" do
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        root: variable([requires("root")]),
        outer: variable([requires("root")]),
        ordinary: variable([requires("missing")])
      }), log_level: "fatal"
    )
    expect(sdk.evaluate_variable("root")[:error].message).to include("Circular")
    expect(sdk.evaluate_variable("outer")[:error].message).to include("Circular")
    expect(sdk.evaluate_variable("ordinary")[:reason]).to eq("conditions_unmet")
  ensure
    sdk&.close
  end

  it "keeps immediate requester dependent hook values separate in the memo" do
    observed = []
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        leaf: variable,
        left: variable([requires("leaf"), requires("leaf")]),
        right: variable([{ variable: "leaf", operator: "equals", value: 2 }]),
        root: variable([requires("left"), requires("right")])
      }), log_level: "fatal",
      modules: [{ after_evaluation: ->(evaluation, options) {
        if options[:variable_key] == "leaf"
          parent = options.dig(:dependency_of, :variable_key)
          observed << parent
          evaluation[:variable_value] = parent == "right" ? 2 : 1
        end
        evaluation
      } }]
    )

    expect(sdk.get_variable("root")).to eq(1)
    expect(observed).to eq(%w[left right])
  ensure
    sdk&.close
  end

  it "invalidates completed reads after sticky state changes inside a hook" do
    reads = 0
    sdk = nil
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        leaf: variable,
        mutator: variable,
        root: variable([requires("leaf"), requires("mutator"),
                        { variable: "leaf", operator: "equals", value: 2 }])
      }), log_level: "fatal",
      modules: [{ after_evaluation: ->(evaluation, _options) {
        reads += 1 if evaluation[:variable_key] == "leaf"
        sdk.set_sticky_variables({ "leaf" => 2 }) if evaluation[:variable_key] == "mutator"
        evaluation
      } }]
    )

    expect(sdk.get_variable("root")).to eq(1)
    expect(reads).to eq(2)
  ensure
    sdk&.close
  end

  it "invalidates completed reads after a datafile replacement inside a hook" do
    reads = 0
    sdk = nil
    root = variable([requires("leaf"), requires("mutator"),
                     { variable: "leaf", operator: "equals", value: 2 }])
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: { leaf: variable, mutator: variable, root: root }),
      log_level: "fatal",
      modules: [{ after_evaluation: ->(evaluation, _options) {
        reads += 1 if evaluation[:variable_key] == "leaf"
        if evaluation[:variable_key] == "mutator"
          sdk.set_datafile(datafile(variables: {
            leaf: variable.merge(defaultValue: 2), mutator: variable, root: root
          }), true)
        end
        evaluation
      } }]
    )

    expect(sdk.get_variable("root")).to eq(1)
    expect(reads).to eq(2)
  ensure
    sdk&.close
  end

  it "reuses ordinary nil operands from failing prerequisite modules" do
    reads = 0
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        broken: variable,
        root: variable([{ variable: "broken", operator: "isNull" },
                        { variable: "broken", operator: "isNull" }])
      }), log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        if options[:variable_key] == "broken"
          reads += 1
          raise "ordinary module failure"
        end
        options
      } }]
    )
    expect(sdk.get_variable("root")).to eq(1)
    expect(reads).to eq(1)
  ensure
    sdk&.close
  end

  it "tracks transformed identities when detecting cycles" do
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: { actual: variable([requires("alias")]), alias: variable }),
      log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        case options[:variable_key]
        when "root" then options.merge(variable_key: "actual")
        when "alias" then options.merge(variable_key: "actual")
        else options
        end
      } }]
    )
    expect(sdk.evaluate_variable("root")[:error].message).to include("Circular")
  ensure
    sdk&.close
  end

  it "allows a redirected prerequisite to finish before any recursive entry" do
    features = { a: feature(requiredFeatures: ["b"]), b: feature }
    build = ->(sticky) {
      Featurevisor.create_featurevisor(
        datafile: datafile(features: features), log_level: "fatal",
        modules: [{ before_evaluation: ->(options) {
          if options[:feature_key] == "b"
            redirected = options.merge(feature_key: "a")
            sticky ? redirected.merge(sticky: { "a" => { enabled: true } }) : redirected
          else
            options
          end
        } }]
      )
    }
    safe = build.call(true)
    recursive = build.call(false)

    expect(safe.evaluate_flag("a")[:enabled]).to be(true)
    expect(recursive.evaluate_flag("a")[:error].message).to include("Circular")
  ensure
    safe&.close
    recursive&.close
  end

  it "clears root memo and pending errors even when a session object is retained" do
    session = Featurevisor::EvaluationSession.new
    root = { type: "variable", variable_key: "root", context: {} }
    leaf = { type: "variable", variable_key: "leaf", context: {} }
    reads = 0

    2.times do
      session.run(root) do
        2.times do
          session.run(leaf, prerequisite: true) do
            reads += 1
            { type: "variable", variable_key: "leaf", variable_value: 1 }
          end
        end
      end
      expect(session.instance_variable_get(:@memo)).to be_empty
      expect(session.instance_variable_get(:@pending_error)).to be_nil
    end
    expect(reads).to eq(2)

    expect { session.run(root) { raise "failed root" } }.to raise_error("failed root")
    expect(session.instance_variable_get(:@memo)).to be_empty
    expect(session.instance_variable_get(:@pending_error)).to be_nil
  end

  it "keeps private session plumbing out of retained module options" do
    retained = []
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(features: { a: feature(requiredFeatures: ["b"]), b: feature }),
      log_level: "fatal",
      modules: [{ before_evaluation: ->(options) { retained << options; options.dup },
                  after_evaluation: ->(evaluation, options) { retained << options; evaluation } }]
    )
    expect(sdk.is_enabled("a")).to be(true)
    expect(retained.length).to eq(4)
    retained.each do |options|
      expect(options.keys.map(&:to_s).grep(/^__featurevisor_/)).to be_empty
      expect(options).not_to have_key(:required_variables_are_matched)
    end
    expect(retained.any? { |options| options[:dependency_of] }).to be(true)
  ensure
    sdk&.close
  end

  it "refreshes inherited feature sticky state after a before hook setter" do
    sdk = Featurevisor.create_featurevisor(datafile: datafile(features: { a: feature }), log_level: "fatal")
    sdk.add_module(before_evaluation: ->(options) {
      sdk.set_sticky_features({ "a" => { enabled: false } }, true)
      options
    })
    expect(sdk.evaluate_flag("a")[:enabled]).to be(false)
    sdk.close

    sdk = Featurevisor.create_featurevisor(datafile: datafile(features: { a: feature }), log_level: "fatal")
    sdk.add_module(before_evaluation: ->(options) {
      sdk.set_sticky_features({ "a" => { enabled: false } }, true)
      options.merge(sticky: { "a" => { enabled: true } })
    })
    expect(sdk.evaluate_flag("a")[:enabled]).to be(true)
  ensure
    sdk&.close
  end

  it "starts a fresh session for public reads made inside callbacks" do
    sdk = nil
    entered = false
    reads = 0
    markers = []
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        leaf: variable, root: variable([requires("leaf"), requires("leaf")])
      }), log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        markers << options[:dependency_of] if options[:variable_key] == "root"
        if options[:variable_key] == "leaf"
          reads += 1
          unless entered
            entered = true
            expect(sdk.get_variable("root")).to eq(1)
          end
        end
        options
      } }]
    )
    expect(sdk.get_variable("root")).to eq(1)
    expect(reads).to eq(2)
    expect(markers).to eq([nil, nil])
  ensure
    sdk&.close
  end

  it "distinguishes object and array contexts and refuses cyclic or host results" do
    session = Featurevisor::EvaluationSession.new
    root = { type: "variable", variable_key: "root", context: {} }
    reads = 0
    session.run(root) do
      [{ "nested" => {} }, { "nested" => [] },
       { "nested" => { "array" => [] } }, { "nested" => ["object", []] },
       { "nested" => { "x" => 1 } }, { "nested" => { x: 1 } }].each do |context|
        options = { type: "variable", variable_key: "leaf", context: context,
                    __featurevisor_prerequisite: true }
        2.times do
          session.run(options, prerequisite: true) do
            reads += 1
            { type: "variable", variable_key: "leaf", reason: "variable_default", variable_value: 1 }
          end
        end
      end
      cyclic = []
      cyclic << cyclic
      2.times do
        session.run({ type: "variable", variable_key: "leaf", context: cyclic }, prerequisite: true) do
          reads += 1
          { type: "variable", reason: "variable_default", variable_value: 1 }
        end
      end
      2.times do
        session.run({ type: "variable", variable_key: "leaf", context: { host: "result" } }, prerequisite: true) do
          reads += 1
          { type: "variable", reason: "variable_default", variable_value: Object.new }
        end
      end
    end
    expect(reads).to eq(10)
  end

  it "propagates nested requirement path and comparison errors" do
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        source: { type: "string", defaultValue: "abc" },
        broken: variable([{ variable: "source", path: "not compiled", operator: "isNull" }]),
        outer: variable([{ variable: "broken", operator: "isNull" }])
      }), log_level: "fatal"
    )
    expect(sdk.evaluate_variable("outer")[:reason]).to eq("error")
    expect(sdk.evaluate_variable("outer")[:error].message).to include("path")
  ensure
    sdk&.close
  end

  it "does not remember a failing read whose hook changed state" do
    sdk = nil
    reads = 0
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        leaf: variable,
        root: variable([{ variable: "leaf", operator: "isNull" },
                        { variable: "leaf", operator: "isNull" }])
      }), log_level: "fatal",
      modules: [{ before_evaluation: ->(options) {
        if options[:variable_key] == "leaf"
          reads += 1
          sdk.set_sticky_variables({ "unrelated" => reads })
          raise "ordinary failure"
        end
        options
      } }]
    )
    expect(sdk.get_variable("root")).to eq(1)
    expect(reads).to eq(2)
  ensure
    sdk&.close
  end

  it "does not merge nested string and symbol context keys observed by modules" do
    reads = 0
    sdk = Featurevisor.create_featurevisor(
      datafile: datafile(variables: {
        leaf: variable,
        mutator: variable,
        root: variable([requires("leaf"), requires("mutator"),
                        { variable: "leaf", operator: "equals", value: 2 }])
      }), log_level: "fatal",
      modules: [{ after_evaluation: ->(evaluation, options) {
        nested = options[:context]["nested"]
        if evaluation[:variable_key] == "leaf"
          reads += 1
          evaluation[:variable_value] = nested.key?(:x) ? 2 : 1
        elsif evaluation[:variable_key] == "mutator"
          nested.clear
          nested[:x] = 1
        end
        evaluation
      } }]
    )

    expect(sdk.get_variable("root", { "nested" => { "x" => 1 } })).to eq(1)
    expect(reads).to eq(2)
  ensure
    sdk&.close
  end
end
