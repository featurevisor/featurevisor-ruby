require "featurevisor"
require "weakref"

RSpec.describe "Warm evaluation and lifecycle contracts" do
  it "skips empty module dispatch and still filters a module installed during evaluation" do
    f = instance
    manager = f.instance_variable_get(:@modules_manager)
    expect(manager).not_to receive(:run_before_evaluation_modules)
    expect(manager).not_to receive(:run_after_evaluation_modules)
    expect(f.is_enabled("flag", country: "nl")).to be(true)
    expect(f.get_variable("greeting", country: "nl")).to eq("nl")
    f.close

    received = []
    holder = {}
    handler = ->(diagnostic) {
      next unless diagnostic[:message] == "using sticky enabled" && received.empty?

      holder[:sdk].add_module(after_evaluation: ->(evaluation, options) {
        received << options
        evaluation
      })
    }
    f = instance(log_level: "debug", sticky_features: { "flag" => { enabled: true } }, on_diagnostic: handler)
    holder[:sdk] = f
    expect(f.is_enabled("flag")).to be(true)
    expect(received.size).to eq(1)
    expect(received.first).to include(type: "flag", feature_key: "flag")
    expect(received.first.keys.grep(/__featurevisor_/)).to be_empty
    f.close
  end

  def datafile(country = "nl")
    condition = JSON.generate(attribute: "country", operator: "equals", value: country)
    {
      schemaVersion: "2", revision: country,
      segments: { audience: { conditions: condition } },
      features: {
        flag: { bucketBy: "userId", traffic: [
          { key: "audience", segments: '["audience"]', percentage: 100_000 }
        ] }
      },
      variables: {
        greeting: { type: "string", defaultValue: "default", overrides: [
          { key: "local", conditions: condition, value: country }
        ] }
      }
    }
  end

  def instance(**options)
    Featurevisor.create_featurevisor({ datafile: datafile, log_level: "fatal" }.merge(options))
  end

  def capturing_handler(value)
    ->(_) { value }
  end

  def closed_instance_with_handler
    captured = Object.new
    weak = WeakRef.new(captured)
    f = instance(on_diagnostic: capturing_handler(captured))
    f.close
    [f, weak]
  end

  def replace_warmed_provider(f)
    f.get_variable("greeting", country: "nl")
    weak = WeakRef.new(f.instance_variable_get(:@datafile))
    f.set_datafile(datafile, true)
    weak
  end

  it "skips metadata formatting when no diagnostic consumer is interested" do
    f = instance
    expect(f).not_to receive(:camelize_diagnostic_value)
    expect(f.is_enabled("flag", country: "nl")).to eq(true)
    expect(f.get_variable("greeting", country: "nl")).to eq("nl")
  end

  it "preserves complete diagnostics when a module enables them during evaluation" do
    received = []
    f = instance(on_diagnostic: ->(diagnostic) { received << diagnostic })
    f.add_module(before_evaluation: ->(options) { f.set_log_level("debug"); options })
    expect(f.is_enabled("flag", country: "nl")).to eq(true)
    diagnostic = received.find { |item| item.dig(:details, :evaluation, :enabled) == true }
    expect(diagnostic[:details]).to include(featureKey: "flag")
    expect(diagnostic[:details][:evaluation]).to include(type: "flag", featureKey: "flag", enabled: true)
    f.close
  end

  it "observes new debug subscriptions even with the instance level set to fatal" do
    received = []
    api = nil
    subscribed = false
    f = instance(modules: [{
      name: "observer", setup: ->(value) { api = value },
      before_evaluation: ->(options) {
        unless subscribed
          subscribed = true
          api[:on_diagnostic].call(->(d) { received << d }, log_level: "debug")
        end
        options
      }
    }])
    expect(f.get_variable("greeting", country: "nl")).to eq("nl")
    expect(received.last).to include(level: "debug", code: "variable_override_rule")
    expect(received.last[:details]).to include(variableKey: "greeting", variableValue: "nl")
    f.close
  end

  it "keeps module source exclusion and subscription levels intact" do
    received = []
    api = nil
    f = instance(modules: [{ name: "source", setup: ->(value) {
      api = value
      api[:on_diagnostic].call(->(d) { received << d }, log_level: "debug")
    } }])
    received.clear
    api[:report_diagnostic].call(level: "debug", code: "own", message: "ignored by source")
    expect(received).to be_empty
    f.is_enabled("flag", country: "nl")
    expect(received).not_to be_empty
    f.close
  end

  it "still prints eligible warnings without an explicit handler" do
    f = instance(log_level: "info", on_diagnostic: ->(_) {})
    f.instance_variable_set(:@on_diagnostic, nil)
    expect { f.is_enabled("missing") }.to output(/feature not found/).to_stderr
  end

  it "preserves default console filtering for symbol and unrecognized levels" do
    [:fatal, "unrecognized"].each do |level|
      f = instance(log_level: level)
      expect { f.send(:report_diagnostic, level: "fatal", message: "fatal message") }
        .to output(/fatal message/).to_stderr
      expect { f.is_enabled("missing") }.not_to output.to_stderr
    end
  end

  it "parses encoded v4 selectors once per entity but never caches their matches" do
    f = instance(datafile: datafile.merge(schemaVersion: "4"))
    source = datafile[:variables][:greeting][:overrides][0][:conditions]
    expect(JSON).to receive(:parse).with(source, symbolize_names: true).twice.and_call_original
    expect(JSON).to receive(:parse).with('["audience"]', symbolize_names: true).once.and_call_original
    3.times do
      expect(f.get_variable("greeting", country: "nl")).to eq("nl")
      expect(f.get_variable("greeting", country: "de")).to eq("default")
      expect(f.is_enabled("flag", country: "nl")).to eq(true)
      expect(f.is_enabled("flag", country: "de")).to eq(false)
    end
  end

  it "caches parsed null and false without confusing them with a cache miss" do
    provider = instance.instance_variable_get(:@datafile)
    ["null", "false"].each do |source|
      expect(JSON).to receive(:parse).with(source).once.and_call_original
      3.times { provider.parse_conditions_if_stringified(source) }
    end
  end

  it "reports invalid v4 selectors once per incoming entity and caches before reentrant reads" do
    errors = []
    f = instance(on_diagnostic: ->(diagnostic) {
      next unless diagnostic[:code] == "conditions_parse_error"
      errors << diagnostic
      expect(f.get_variable("greeting", country: "nl")).to eq("default")
    }, log_level: "error")
    malformed = datafile.merge(schemaVersion: "4")
    malformed[:variables][:greeting][:overrides][0][:conditions] = "{bad JSON"
    3.times do
      f.set_datafile(malformed, true)
      2.times { expect(f.get_variable("greeting", country: "nl")).to eq("default") }
    end
    expect(errors.size).to eq(3)
    expect(errors.first[:details]).to eq(conditions: "{bad JSON", entityType: "variable", entityKey: "greeting")
    f.set_datafile(datafile, true)
    expect(f.get_variable("greeting", country: "nl")).to eq("nl")
  ensure
    f&.close
  end

  it "keeps invalid encoded segments raising rather than caching a silent miss" do
    provider = instance.instance_variable_get(:@datafile)
    2.times do
      expect { provider.parse_segments_if_stringified("[") }.to raise_error(JSON::ParserError)
    end
  end

  it "replaces caches with datafile generations and preserves them on invalid updates" do
    f = instance
    [false, true].each do |replace|
      old = f.instance_variable_get(:@datafile)
      expect(f.get_variable("greeting", country: "nl")).to eq("nl")
      f.set_datafile("bad JSON", replace)
      expect(f.instance_variable_get(:@datafile)).to equal(old)
      f.set_datafile(datafile("de"), replace)
      expect(f.instance_variable_get(:@datafile)).not_to equal(old)
      expect(f.get_variable("greeting", country: "nl")).to eq("default")
      expect(f.get_variable("greeting", country: "de")).to eq("de")
      f.set_datafile(datafile, true)
    end
  end

  it "evaluates concurrent contexts independently after warming expressions" do
    f = instance
    f.is_enabled("flag", country: "nl")
    threads = 8.times.map do |index|
      Thread.new do
        country = index.even? ? "nl" : "de"
        100.times do
          raise "wrong flag" unless f.is_enabled("flag", country: country) == index.even?
          raise "wrong variable" unless f.get_variable("greeting", country: country) == (index.even? ? "nl" : "default")
        end
      end
    end
    threads.each(&:value)
  end

  it "preserves string and symbol attributes, null, false, empty and nested paths" do
    matcher = Featurevisor::Conditions
    context = { flag: false, "flag" => true, value: nil, "text" => "", nested: { "city" => "amsterdam" } }
    expect(matcher.get_value_from_context(context, "flag")).to eq(false)
    expect(matcher.get_value_from_context(context, "value")).to be_nil
    expect(matcher.get_value_from_context(context, "text")).to eq("")
    expect(matcher.get_value_from_context(context, "nested.city")).to eq("amsterdam")
    expect(matcher.get_value_from_context(context, "missing")).to be_nil
    expect(matcher.get_value_from_context(context, "")).to equal(context)
  end

  it "releases diagnostics and caches after module shutdown errors are reported" do
    received = []
    api = nil
    f = instance(on_diagnostic: ->(d) { received << d }, log_level: "error", modules: [{
      name: "shutdown", setup: ->(value) { api = value }, close: -> { raise "shutdown failure" }
    }])
    f.get_variable("greeting", country: "nl")
    provider = f.instance_variable_get(:@datafile)
    provider.get_regex("abc")
    expect(provider.normalized[:variable]).not_to be_empty
    f.close
    f.close
    expect(received.count { |d| d[:code] == "module_close_error" }).to eq(1)
    expect(f.instance_variable_get(:@on_diagnostic)).to be_nil
    expect(provider.normalized.values).to all(be_empty)
    %i[@conditions_cache @segments_cache @regex_cache].each do |name|
      expect(provider.instance_variable_get(name)).to be_empty
    end
    api[:on_diagnostic].call(->(_) { raise "closed" })
    expect(f.instance_variable_get(:@module_diagnostic_subscriptions)).to be_empty
  end

  it "clears old emitter arrays retained by unsubscribe functions" do
    emitter = Featurevisor::Emitter.new
    calls = []
    unsubscribe = emitter.on("error", ->(_) { calls << true })
    original = emitter.listeners["error"]
    emitter.clear_all
    expect(original).to be_empty
    unsubscribe.call
    unsubscribe.call
    emitter.trigger("error")
    expect(calls).to be_empty
  end

  it "allows captured handlers and obsolete datafile generations to be collected" do
    closed, handler = closed_instance_with_handler
    f = instance
    old_providers = 20.times.map { replace_warmed_provider(f) }
    GC.start(full_mark: true, immediate_sweep: true)
    expect(handler.weakref_alive?).to be_falsey
    expect(old_providers.any?(&:weakref_alive?)).to eq(false)
    expect(closed.get_revision).to eq("nl")
    expect(f.get_variable("greeting", country: "nl")).to eq("nl")
  end

  it "does not retain child bookkeeping after unsubscribe or accept listeners after close" do
    f = instance
    child = f.spawn
    1_000.times do
      unsubscribe = child.on("datafile_set", ->(_) {})
      unsubscribe.call
    end
    expect(child.instance_variable_get(:@parent_unsubscribers)).to be_empty
    child.close
    child.close
    %w[datafile_set context_set].each { |event| child.on(event, ->(_) { raise "closed" }) }
    expect(child.instance_variable_get(:@parent_unsubscribers)).to be_empty
    expect(child.instance_variable_get(:@emitter).listeners).to be_empty
  end
end
