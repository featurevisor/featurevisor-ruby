# frozen_string_literal: true

require "featurevisor"
require "json"

RSpec.describe "native v4 normalization, sessions and ownership" do
  def datafile(version = "4")
    { schemaVersion: version, revision: "accepted", segments: {},
      features: { healthy: feature }, variables: { healthy: { type: "string", defaultValue: "healthy" } } }
  end

  def feature
    { bucketBy: [], traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
  end

  def frozen_tree(value)
    case value
    when Hash then value.each { |key, child| key.freeze; frozen_tree(child) }
    when Array then value.each { |child| frozen_tree(child) }
    end
    value.freeze
  end

  %w[2 4].each do |version|
    it "stores and caches before schema #{version} diagnostics and retains unrelated entity caches" do
      errors = []
      f = Featurevisor.create_featurevisor(log_level: "error", on_diagnostic: ->(diagnostic) {
        next unless diagnostic[:code] == "conditions_parse_error"
        errors << diagnostic
        expect(f.get_revision).to eq("accepted")
        expect(f.evaluate_variable("broken")[:reason]).to eq("conditions_unmet")
        f.set_context(callback: true)
      })
      source = datafile(version)
      source[:variables][:broken] = { type: "string", defaultValue: "wrong", disabledValue: "disabled", conditions: " \n {oops" }
      frozen_tree(source)
      expect(f.set_datafile(source, true)).to be(true)
      expect(errors.length).to eq(version == "2" ? 1 : 0)
      2.times { expect(f.get_variable("broken")).to eq("disabled") }
      expect(errors.length).to eq(1)
      expect(errors.first[:level]).to eq("error")
      expect(errors.first[:details]).to eq(conditions: " \n {oops", entityType: "variable", entityKey: "broken")
      f.set_datafile(datafile)
      f.get_variable("broken")
      expect(errors.length).to eq(1)
      f.set_datafile(source)
      f.get_variable("broken")
      expect(errors.length).to eq(2)
      f.set_datafile(source, true)
      f.get_variable("broken")
      expect(errors.length).to eq(3)
    ensure
      f&.close
    end

    %i[feature segment force traffic rule_override variation_override variable override program legacy_segments].each do |site|
      ["{oops", '[{"feature":', '"unterminated', " \n {bad} "].each do |malformed|
        it "fails only #{site} for schema #{version} selector #{malformed.inspect}" do
          source = datafile(version)
          subject = feature.merge(variablesSchema: { copy: { type: "string", defaultValue: "fallback" } })
          case site
          when :feature then subject[:conditions] = malformed
          when :segment
            source[:segments][:broken] = { conditions: malformed }
            subject[:conditions] = { not: ["broken"] }
          when :force then subject[:force] = [{ conditions: malformed, enabled: true, variables: { copy: "wrong" } }]
          when :traffic, :legacy_segments
            selector = site == :traffic ? :conditions : :segments
            subject[:traffic].unshift(key: "broken", selector => malformed, percentage: 100_000, variables: { copy: "wrong" })
          when :rule_override
            subject[:traffic][0][:variableOverrides] = { copy: [{ conditions: malformed, value: "wrong" }] }
          when :variation_override
            subject[:variations] = [{ value: "on", variables: { copy: "fallback" }, variableOverrides: { copy: [{ conditions: malformed, value: "wrong" }] } }]
            subject[:traffic][0][:allocation] = [{ variation: "on", range: [0, 100_000] }]
          else
            variable = { type: "string", defaultValue: "fallback", disabledValue: "fallback" }
            if site == :variable
              variable[:conditions] = malformed
            elsif site == :override
              variable[:overrides] = [{ conditions: malformed, value: "wrong" }]
            else
              variable[:overrideProgram] = [{ key: "broken", conditions: malformed, operations: [{ op: "set", path: [], value: "wrong" }], onMatch: 1, onMiss: 1 }]
            end
            source[:variables][:subject] = variable
          end
          source[:features][:subject] = subject
          frozen_tree(source)
          errors = []
          f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { errors << item if item[:code] == "conditions_parse_error" })
          expect(errors.length).to eq(version == "2" ? 1 : 0)
          2.times do
            if %i[feature segment].include?(site)
              evaluation = f.evaluate_flag("subject")
              expect(evaluation).to include(reason: "conditions_unmet", enabled: false)
              expect(JSON.parse(JSON.generate(evaluation))["conditions"]).to eq("or" => []) if site == :feature
            elsif source[:variables].key?(:subject)
              expect(f.get_variable("subject")).to eq("fallback")
            else
              expect(f.get_variable("subject", "copy")).to eq("fallback")
            end
          end
          expect(errors.length).to eq(1)
          expect(f.is_enabled("healthy")).to be(true)
          expect(f.get_variable("healthy")).to eq("healthy")
        ensure
          f&.close
        end
      end
    end
  end

  %w[2 3 4].each do |version|
    [false, true].each do |empty|
      it "keeps exact flattened mixed selector metadata for schema #{version}, empty #{empty}" do
        conditions = empty ? [] : [{ attribute: "country", operator: "equals", value: "nl" }]
        source = datafile(version)
        source[:features][:subject] = feature.merge(conditions: conditions, requiredFeatures: ["missing"])
        f = Featurevisor.create_featurevisor(datafile: frozen_tree(source), log_level: "fatal")
        expression = empty ? [{ and: [] }, { feature: "missing" }] : [*conditions, { feature: "missing" }]
        expect(f.evaluate_flag("subject", country: "nl")).to include(reason: "conditions_unmet", conditions: expression, enabled: false)
      ensure
        f&.close
      end
    end
  end

  it "preserves unread legacy and modern semantics in either mixed merge order" do
    [true, false].each do |legacy_first|
      legacy, modern = datafile("2"), datafile
      legacy[:segments][:legacy] = { conditions: [] }
      legacy[:features][:legacy] = feature.merge(conditions: "legacy")
      modern[:segments][:modern] = { conditions: [] }
      modern[:features][:modern] = feature.merge(conditions: "modern")
      first, second = legacy_first ? [legacy, modern] : [modern, legacy]
      f = Featurevisor.create_featurevisor(datafile: frozen_tree(first), log_level: "fatal")
      expect(f.set_datafile(frozen_tree(second))).to be(true)
      expect(f.is_enabled("legacy")).to be(true)
      expect(f.is_enabled("modern")).to be(false)
      f.close
    end
  end

  [nil, true, false, 42, [true], [], { and: [] }, { or: [] }, { not: [] }].each do |conditions|
    it "defensively fails unsupported or empty root #{conditions.inspect}" do
      source = datafile
      source[:features][:subject] = feature.merge(conditions: conditions)
      source[:variables][:subject] = { type: "string", defaultValue: "wrong", conditions: conditions }
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      expect(f.evaluate_flag("subject")).to include(reason: "conditions_unmet", enabled: false)
      expect(f.evaluate_variable("subject")[:reason]).to eq("conditions_unmet")
    ensure
      f&.close
    end
  end

  [0, 1, 128, 256, 257].each do |getters|
    [0, 1, 128, 255, 256, 257].each do |segments|
      next if getters.zero? && segments.zero?
      it "shares the exact depth bound across #{getters} getter and #{segments} segment handoffs" do
        source = datafile
        (0..getters).each do |index|
          source[:variables]["g#{index}".to_sym] = if index < getters
            { type: "boolean", compose: "g#{index + 1}" }
          else
            { type: "boolean", defaultValue: true }.tap { |value| value[:conditions] = "s0" if segments.positive? }
          end
        end
        segments.times { |index| source[:segments]["s#{index}".to_sym] = { conditions: index + 1 < segments ? "s#{index + 1}" : "*" } }
        f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
        expect(f.evaluate_variable("g0")[:reason] == "error").to eq(getters + segments > 256)
        expect(f.is_enabled("healthy")).to be(true)
        expect(f.get_variable("healthy")).to eq("healthy")
      ensure
        f&.close
      end
    end
  end

  [127, 128, 129, 140].each do |depth|
    it "bounds #{depth} alternating segment and feature handoffs" do
      source = datafile
      source[:features][:subject] = feature.merge(conditions: "s0")
      depth.times do |index|
        source[:segments]["s#{index}".to_sym] = { conditions: { feature: "f#{index}" } }
        source[:features]["f#{index}".to_sym] = feature.merge(conditions: index + 1 < depth ? "s#{index + 1}" : "*")
      end
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      expect(f.evaluate_flag("subject")[:reason] == "error").to eq(depth > 128)
      expect(f.is_enabled("healthy")).to be(true)
    ensure
      f&.close
    end
  end

  %i[segment feature variable mixed].each do |kind|
    it "fails #{kind} cycles through NOT without retaining failed request state" do
      source = datafile
      source[:features][:subject] = feature.merge(conditions: "s0")
      case kind
      when :segment then source[:segments][:s0] = { conditions: { not: ["s0"] } }
      when :feature then source[:segments][:s0] = { conditions: { not: [{ feature: "subject" }] } }
      when :variable
        source[:variables][:loop] = { type: "boolean", defaultValue: true, conditions: { not: [{ variable: "loop", operator: "isNull" }] } }
        source[:segments][:s0] = { conditions: { variable: "loop", operator: "isNull" } }
      when :mixed
        source[:segments][:s0] = { conditions: { variable: "loop", operator: "notNull" } }
        source[:variables][:loop] = { type: "object", compose: [{ key: "flag", feature: "subject" }] }
      end
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      2.times { expect(f.evaluate_flag("subject")[:reason]).to eq("error") }
      expect(f.is_enabled("healthy")).to be(true)
    ensure
      f&.close
    end
  end

  it "keeps composition values borrowed, JSON decoded once and condition snapshots owned" do
    source = datafile
    source[:variables][:policy] = { type: "object", defaultValue: { limit: 50 } }
    source[:variables][:raw] = { type: "json", defaultValue: '{"items":[1]}' }
    source[:features][:gate] = feature.merge(conditions: [
      { variable: "policy", path: ["limit"], operator: "equals", value: 50 },
      { variable: "raw", operator: "notNull" },
      { variable: "policy", path: ["limit"], operator: "equals", value: 50 }
    ])
    source[:variables][:screen] = { type: "object", compose: [
      { key: "first", variable: "policy" }, { key: "flag", feature: "gate" },
      { key: "last", variable: "policy" }, { key: "json1", variable: "raw" }, { key: "json2", variable: "raw" }
    ] }
    purposes, retained = [], []
    policy = nil
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ before_evaluation: ->(options) {
      retained << options
      purposes << options[:dependency_purpose] if options[:variable_key] == "policy" && options[:dependency_of]
      policy[:limit] = 80 if policy && options[:variable_key] == "raw" && options[:dependency_purpose] == "condition"
      options
    } }])
    policy = f.get_variable("policy")
    result = f.get_variable("screen")
    expect(result).to include(first: { limit: 80 }, last: { limit: 80 }, flag: true)
    expect(result[:first]).to equal(policy)
    expect(result[:last]).to equal(policy)
    expect(result[:json1]).to equal(result[:json2])
    expect(purposes).to eq(%w[composition condition])
    expect(retained.flat_map(&:keys).grep(/__featurevisor_/)).to be_empty
    expect(retained.select { |options| options[:dependency_of] }.map { |options| options[:dependency_purpose] }.uniq.sort).to eq(%w[composition condition])
  ensure
    f&.close
  end

  it "runs sources eagerly before overrides without mutating siblings or sticky sources" do
    sticky = { methods: ["card"] }
    source = datafile
    source[:variables][:policy] = { type: "object", defaultValue: { methods: ["default"] } }
    source[:variables][:screen] = { type: "object", compose: [{ key: "changed", variable: "policy" }, { key: "original", variable: "policy" }], overrideProgram: [
      { key: "modify", conditions: "*", operations: [{ op: "append", path: ["changed", "methods"], value: "ideal" }], onMatch: 1, onMiss: 1 }
    ] }
    reads = []
    f = Featurevisor.create_featurevisor(datafile: source, sticky_variables: { policy: frozen_tree(sticky) }, log_level: "fatal", modules: [{ before_evaluation: ->(options) { reads << options[:variable_key]; options } }])
    result = f.evaluate_variable("screen")
    expect(reads).to eq(%w[screen policy])
    expect(result).to include(reason: "variable_override_rule", variable_value: { changed: { methods: %w[card ideal] }, original: { methods: ["card"] } })
    expect(result[:variable_value][:original]).to equal(sticky)
    expect(sticky).to eq(methods: ["card"])
    expect(f.get_variable("screen")).not_to equal(result[:variable_value])
  ensure
    f&.close
  end

  [false, 0, "", "null", "123", nil, [], { nested: true }].each do |value|
    it "preserves decoded alias value #{value.inspect} exactly once" do
      source = datafile
      source[:variables][:json] = { type: "json", defaultValue: JSON.generate(value) }
      source[:variables][:alias] = { type: "json", compose: "json" }
      source[:variables][:chain] = { type: "json", compose: "alias" }
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      2.times { expect(f.get_variable("chain")).to eq(value) }
    ensure
      f&.close
    end
  end

  it "uses effective module context and isolated child sticky state for all sources" do
    source = datafile
    source[:variables][:policy] = { type: "string", defaultValue: "default", overrides: [{ conditions: { attribute: "country", operator: "equals", value: "nl" }, value: "dutch" }] }
    source[:variables][:screen] = { type: "object", compose: [{ key: "flag", feature: "healthy" }, { key: "policy", variable: "policy" }] }
    f = Featurevisor.create_featurevisor(datafile: source, context: { country: "de" }, sticky_variables: { policy: "parent" }, log_level: "fatal")
    child = f.spawn({ country: "nl" }, sticky_features: { healthy: { enabled: false } }, sticky_variables: {})
    expect(child.get_variable("screen")).to eq(flag: false, policy: "dutch")
    expect(f.get_variable("screen")).to eq(flag: true, policy: "parent")
    child.set_sticky_variables({ screen: nil }, true)
    expect(child.get_variable("screen")).to be_nil
    child.set_sticky_variables({}, true)
    f.add_module(before_evaluation: ->(options) { options[:variable_key] == "screen" ? options.merge(context: { country: "nl" }) : options })
    expect(child.get_variable("screen", country: "de")).to eq(flag: false, policy: "dutch")
  ensure
    child&.close
    f&.close
  end

  it "skips all sources for a missed gate and returns deliberate null rather than a caller default" do
    source = datafile
    source[:variables][:screen] = { type: "json", compose: "healthy", conditions: [], overrideProgram: [{ key: "wrong", conditions: "*", operations: [{ op: "set", path: [], value: "wrong" }], onMatch: 1, onMiss: 1 }] }
    reads = []
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ before_evaluation: ->(options) { reads << options[:variable_key]; options } }])
    expect(f.get_variable("screen", {}, default_variable_value: "caller")).to be_nil
    expect(reads).to eq(["screen"])
    expect(f.evaluate_variable("screen")).to include(reason: "conditions_unmet", variable_value: nil)
  ensure
    f&.close
  end

  it "indexes raw conditions and compose across all entity kinds without warming caches or diagnostics" do
    source = datafile
    source[:features][:healthy][:hash] = "old"
    source[:segments][:bridge] = { conditions: '{"feature":"healthy"}' }
    source[:features][:dependent] = feature.merge(hash: "dependent", conditions: "bridge")
    source[:variables][:policy] = { hash: "policy", type: "boolean", defaultValue: true, conditions: "bridge" }
    source[:variables][:alias] = { hash: "alias", type: "boolean", compose: "policy" }
    source[:segments][:last] = { conditions: { variable: "alias", operator: "notNull" } }
    source[:features][:last] = feature.merge(hash: "last", conditions: "last")
    source[:variables][:broken] = { hash: "broken", conditions: "{oops", defaultValue: true }
    diagnostics = []
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { diagnostics << item })
    events = []
    f.on("datafile_set", ->(event) { events << event })
    patch = datafile
    patch[:features][:healthy][:hash] = "new"
    f.set_datafile(patch)
    expect(events.last[:features]).to match_array(%i[healthy dependent last])
    expect(events.last[:variables]).to match_array(%i[healthy policy alias])
    expect(f.instance_variable_get(:@datafile).normalized.values).to all(be_empty)
    expect(diagnostics).to be_empty
    f.set_datafile(datafile, true)
    expect(events.last[:features]).to match_array(%i[healthy dependent last])
    expect(events.last[:variables]).to match_array(%i[healthy policy alias broken])
  ensure
    f&.close
  end

  %w[2 4].each do |version|
    [[], { and: [] }].each do |empty|
      it "limits historical empty truth to old schema #{version} selector locations, #{empty.inspect}" do
        source = datafile(version)
        source[:segments][:empty] = { conditions: empty }
        source[:features][:segment] = feature.merge(conditions: "empty")
        source[:features][:forced] = feature.merge(traffic: [], force: [{ conditions: empty, enabled: true }])
        source[:features][:rule] = feature.merge(traffic: [{ key: "empty", conditions: empty, percentage: 100_000 }])
        source[:features][:root] = feature.merge(conditions: empty)
        source[:features][:override] = feature.merge(variablesSchema: { title: { type: "string", defaultValue: "default" } })
        source[:features][:override][:traffic][0][:variableOverrides] = { title: [{ conditions: empty, value: "override" }] }
        source[:variables][:ordinary] = { type: "string", defaultValue: "default", overrides: [{ conditions: empty, value: "override" }] }
        source[:variables][:root] = { type: "string", defaultValue: "default", disabledValue: "disabled", conditions: empty }
        source[:variables][:program] = { type: "string", defaultValue: "default", overrideProgram: [
          { conditions: empty, operations: [{ op: "set", path: [], value: "override" }], onMatch: 1, onMiss: 1 }
        ] }
        f = Featurevisor.create_featurevisor(datafile: frozen_tree(source), log_level: "fatal")
        expect(f.is_enabled("segment")).to eq(version == "2")
        expect(f.is_enabled("forced")).to eq(version == "2")
        expect(f.is_enabled("rule")).to be(false)
        expect(f.is_enabled("root")).to be(false)
        expect(f.get_variable("override", "title")).to eq(version == "2" ? "override" : "default")
        expect(f.get_variable("ordinary")).to eq(version == "2" ? "override" : "default")
        expect(f.get_variable("root")).to eq("disabled")
        expect(f.get_variable("program")).to eq("default")
      ensure
        f&.close
      end
    end
  end

  it "propagates invalid markers before depth checks and never inverts them through NOT" do
    source = datafile
    source[:segments][:broken] = { conditions: "{oops" }
    source[:variables][:g256] = { type: "boolean", conditions: { not: ["broken"] }, defaultValue: true, disabledValue: false }
    256.times { |index| source[:variables]["g#{index}".to_sym] = { type: "boolean", compose: "g#{index + 1}" } }
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
    expect(f.get_variable("g0")).to be(false)
    expect(f.evaluate_variable("g0")[:reason]).to eq("variable_composed")
  ensure
    f&.close
  end

  it "does not traverse or copy borrowed host values to memoise repeated composition reads" do
    source = datafile
    source[:variables][:policy] = { type: "object", defaultValue: {} }
    source[:variables][:screen] = { type: "object", compose: [{ key: "first", variable: "policy" }, { key: "second", variable: "policy" }] }
    host = { callback: -> { true } }
    host[:self] = host
    reads = 0
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ after_evaluation: ->(evaluation, _options) {
      if evaluation[:variable_key] == "policy"
        reads += 1
        evaluation[:variable_value] = host
      end
      evaluation
    } }])
    result = f.get_variable("screen")
    expect(result[:first]).to equal(host)
    expect(result[:second]).to equal(host)
    expect(reads).to eq(1)
    fresh = f.get_variable("screen")
    expect(fresh).not_to equal(result)
    expect(fresh[:first]).to equal(host)
    expect(reads).to eq(2)
  ensure
    f&.close
  end

  it "invalidates composition memo entries after an SDK setter during source evaluation" do
    source = datafile
    source[:variables][:policy] = { type: "integer", defaultValue: 1 }
    source[:variables][:mutator] = { type: "integer", defaultValue: 0 }
    source[:variables][:screen] = { type: "object", compose: [
      { key: "first", variable: "policy" }, { key: "mutator", variable: "mutator" }, { key: "second", variable: "policy" }
    ] }
    f = nil
    reads = 0
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal", modules: [{ after_evaluation: ->(evaluation, _options) {
      reads += 1 if evaluation[:variable_key] == "policy"
      f.set_sticky_variables({ policy: 2 }, true) if evaluation[:variable_key] == "mutator"
      evaluation
    } }])
    expect(f.get_variable("screen")).to eq(first: 1, mutator: 0, second: 2)
    expect(reads).to eq(2)
  ensure
    f&.close
  end

  it "treats an explicit null feature enabled selector as the default true" do
    source = datafile
    source[:features][:subject] = feature.merge(conditions: { feature: "healthy", enabled: nil })
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
    expect(f.is_enabled("subject")).to be(true)
  ensure
    f&.close
  end
end
