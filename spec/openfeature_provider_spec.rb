require "featurevisor/openfeature_provider"
require "json"

RSpec.describe Featurevisor::OpenFeatureProvider do
  it "rejects invalid initial registration and emits recovery independently of logging" do
    ["{", "null", {}, false, { schemaVersion: "2", revision: "x", features: [], segments: {} }].each do |input|
      instance = described_class.new(datafile: input, log_level: "fatal")
      expect { OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(instance) } }
        .to raise_error(OpenFeature::SDK::ProviderInitializationError) { |error| expect(error.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::PARSE_ERROR) }
      instance.featurevisor.set_datafile(datafile, true)
      expect(OpenFeature::SDK.build_client.fetch_boolean_value(flag_key: "checkout", default_value: false)).to be(true)
      instance.shutdown
    end
  end

  it "preserves empty targeting keys through the OpenFeature client" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/openfeature-provider.json", __dir__), encoding: "UTF-8"))
    instance = described_class.new(datafile: fixture.fetch("datafile"), log_level: "fatal")
    OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(instance) }
    client = OpenFeature::SDK.build_client
    fields = { userId: "forced" }
    absent = OpenFeature::SDK::EvaluationContext.new(**fields)
    empty = OpenFeature::SDK::EvaluationContext.new(targeting_key: "", **fields)
    other = OpenFeature::SDK::EvaluationContext.new(targeting_key: "other", **fields)
    expect(client.fetch_boolean_value(flag_key: "targetOnly", default_value: false, evaluation_context: absent)).to be(true)
    expect(client.fetch_boolean_value(flag_key: "targetOnly", default_value: false, evaluation_context: empty)).to be(false)
    expect(client.fetch_boolean_value(flag_key: "targetOnly", default_value: false, evaluation_context: other)).to be(false)
    expect(fields).to eq({ userId: "forced" })
    custom = described_class.new(datafile: fixture.fetch("datafile"), log_level: "fatal", targeting_key_field: "accountId")
    OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(custom) }
    account = { accountId: "old" }
    context = OpenFeature::SDK::EvaluationContext.new(targeting_key: "", **account)
    expect(OpenFeature::SDK.build_client.fetch_boolean_value(flag_key: "accountTargeted", default_value: false, evaluation_context: context)).to be(true)
    expect(account).to eq({ accountId: "old" })
  ensure
    instance&.shutdown
    custom&.shutdown
  end

  it "runs the shared provider conformance corpus" do
    fixture = JSON.parse(File.read(File.expand_path("../conformance/openfeature-provider.json", __dir__), encoding: "UTF-8"))
    expect(fixture.fetch("kind")).to eq("featurevisor.openfeature-provider")
    expect(fixture.fetch("schemaVersion")).to eq(1)
    expect(fixture.fetch("cases").length).to eq(16)
    instance = described_class.new(datafile: fixture.fetch("datafile"), log_level: "fatal")
    OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(instance) }
    client = OpenFeature::SDK.build_client
    resolvers = {
      "boolean" => :fetch_boolean_value,
      "string" => :fetch_string_value,
      "object" => :fetch_object_value
    }
    fixture.fetch("cases").each do |test_case|
      source = Marshal.load(Marshal.dump(test_case.fetch("context")))
      attributes = source.reject { |key, _| key == "targetingKey" }.transform_keys(&:to_sym)
      context = OpenFeature::SDK::EvaluationContext.new(targeting_key: source["targetingKey"], **attributes)
      result = instance.public_send(resolvers.fetch(test_case.fetch("type")), flag_key: test_case.fetch("flagKey"), default_value: test_case.fetch("default"), evaluation_context: context)
      expected = test_case.fetch("expected")
      expect(result.value).to eq(expected.fetch("value")), test_case.fetch("name")
      expect(result.reason).to eq(expected.fetch("reason")), test_case.fetch("name") if expected.key?("reason")
      expect(result.variant).to eq(expected["variant"]), test_case.fetch("name")
      expect(result.error_code).to eq(expected["errorCode"]), test_case.fetch("name")
      method = resolvers.fetch(test_case.fetch("type")).to_s.sub(/_value\z/, "_details")
      client_result = client.public_send(method, flag_key: test_case.fetch("flagKey"), default_value: test_case.fetch("default"), evaluation_context: context)
      expect(client_result.value).to eq(expected.fetch("value")), test_case.fetch("name")
      expect(client_result.reason).to eq(result.reason), test_case.fetch("name")
      expect(client_result.variant).to eq(result.variant), test_case.fetch("name")
      expect(client_result.error_code).to eq(result.error_code), test_case.fetch("name")
      expect(source).to eq(test_case.fetch("context")), test_case.fetch("name")
    end
    fixture.fetch("targetingCases").each do |test_case|
      source = Marshal.load(Marshal.dump(test_case.fetch("context")))
      attributes = source.reject { |key, _| key == "targetingKey" }.transform_keys(&:to_sym)
      context = OpenFeature::SDK::EvaluationContext.new(targeting_key: source["targetingKey"], **attributes)
      result = instance.fetch_boolean_value(flag_key: "targetOnly", default_value: false, evaluation_context: context)
      expect(result.value).to eq(test_case.fetch("expectedValue")), test_case.fetch("name")
      expect(source).to eq(test_case.fetch("context")), test_case.fetch("name")
    end
    custom = described_class.new(datafile: fixture.fetch("datafile"), log_level: "fatal", targeting_key_field: "accountId")
    test_case = fixture.fetch("customTargetingCase")
    attributes = test_case.fetch("context").reject { |key, _| key == "targetingKey" }.transform_keys(&:to_sym)
    context = OpenFeature::SDK::EvaluationContext.new(targeting_key: test_case.fetch("context").fetch("targetingKey"), **attributes)
    expect(custom.fetch_boolean_value(flag_key: test_case.fetch("flagKey"), default_value: false, evaluation_context: context).value).to eq(test_case.fetch("expectedValue"))
  ensure
    instance&.shutdown
    custom&.shutdown
  end
  let(:datafile) do
    {
      schemaVersion: "2", revision: "openfeature-test", featurevisorVersion: "3.0.1", segments: {},
      features: {
        "checkout" => {
          bucketBy: "userId",
          variations: [{ value: "on", variables: { title: "Hello", count: 3, ratio: 1.5, visible: true, items: ["a"], config: { color: "blue" }, json: '{"nested":true}', invalidJson: "not-json" } }],
          variablesSchema: {
            title: { type: "string", defaultValue: "Default" }, count: { type: "integer", defaultValue: 0 },
            ratio: { type: "double", defaultValue: 0 }, visible: { type: "boolean", defaultValue: false },
            items: { type: "array", defaultValue: [] }, config: { type: "object", defaultValue: {} }, json: { type: "json", defaultValue: "{}" },
            invalidJson: { type: "json", defaultValue: "{}" }
          },
          force: [{ conditions: { attribute: "userId", operator: "equals", value: "forced-user" }, enabled: true, variation: "on" }],
          traffic: [{ key: "all", segments: "*", percentage: 100_000, variation: "on" }]
        }
      },
      variables: {
        welcomeMessage: { type: "string", defaultValue: "Welcome" },
        globalEnabled: { type: "boolean", defaultValue: true }
      }
    }
  end

  def provider(**options)
    described_class.new({ datafile: datafile, log_level: "fatal" }, **options)
  end

  it "decodes global JSON variables just like feature JSON variables" do
    datafile[:variables][:config] = { type: "json", defaultValue: '{"nested":[null,true]}' }
    instance = provider
    result = instance.fetch_object_value(flag_key: "variable:config", default_value: {})
    expect(result.value).to eq({ "nested" => [nil, true] })
    expect(result.error_code).to be_nil
  ensure
    instance&.shutdown
  end

  it "accepts Featurevisor options as documented keyword arguments" do
    instance = described_class.new(datafile: datafile, log_level: "fatal")
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).value).to be(true)
  ensure
    instance&.shutdown
  end

  it "resolves every OpenFeature type and maps targeting key" do
    context = OpenFeature::SDK::EvaluationContext.new(targeting_key: "forced-user")
    expect(provider.fetch_boolean_value(flag_key: "checkout", default_value: false, evaluation_context: context).value).to be(true)
    expect(provider.fetch_string_value(flag_key: "checkout:variation", default_value: "fallback", evaluation_context: context).value).to eq("on")
    expect(provider.fetch_string_value(flag_key: "checkout:title", default_value: "fallback", evaluation_context: context).value).to eq("Hello")
    expect(provider.fetch_integer_value(flag_key: "checkout:count", default_value: 0, evaluation_context: context).value).to eq(3)
    expect(provider.fetch_float_value(flag_key: "checkout:ratio", default_value: 0.0, evaluation_context: context).value).to eq(1.5)
    expect(provider.fetch_boolean_value(flag_key: "checkout:visible", default_value: false, evaluation_context: context).value).to be(true)
    expect(provider.fetch_object_value(flag_key: "checkout:items", default_value: [], evaluation_context: context).value).to eq(["a"])
    expect(provider.fetch_object_value(flag_key: "checkout:config", default_value: {}, evaluation_context: context).value).to eq({ "color" => "blue" })
    expect(provider.fetch_object_value(flag_key: "checkout:json", default_value: {}, evaluation_context: context).value).to eq({ "nested" => true })
    expect(provider.fetch_string_value(flag_key: "variable:welcomeMessage", default_value: "fallback", evaluation_context: context).value).to eq("Welcome")
    expect(provider.fetch_boolean_value(flag_key: "variable:globalEnabled", default_value: false, evaluation_context: context).value).to be(true)
  end

  it "supports a custom global variable prefix" do
    instance = provider(key_separator: "/", global_variable_prefix: "$global")
    expect(instance.fetch_string_value(flag_key: "$global/welcomeMessage", default_value: "fallback").value).to eq("Welcome")
    expect(instance.fetch_string_value(flag_key: "variable/welcomeMessage", default_value: "fallback").error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::FLAG_NOT_FOUND)
  ensure
    instance&.shutdown
  end

  it "rejects a global variable prefix containing the separator" do
    expect { provider(global_variable_prefix: "global:value") }.to raise_error(ArgumentError)
  end

  it "supports errors, custom grammar, tracking, and shutdown" do
    tracked = []
    instance = provider(key_separator: "/", variation_key: "$variation", on_track: ->(*args) { tracked << args })
    expect(instance.fetch_string_value(flag_key: "checkout/$variation", default_value: "fallback").value).to eq("on")
    expect(instance.fetch_string_value(flag_key: "missing", default_value: "fallback").error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
    missing = instance.fetch_boolean_value(flag_key: "missing", default_value: true)
    expect(missing.value).to be(true)
    expect(missing.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::FLAG_NOT_FOUND)
    instance.track(tracking_event_name: "purchase")
    expect(tracked.first.first).to eq("purchase")
    instance.shutdown
  end

  it "works through the OpenFeature SDK" do
    OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(provider) }
    client = OpenFeature::SDK.build_client
    value = client.fetch_boolean_value(
      flag_key: "checkout",
      default_value: false,
      evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: "forced-user")
    )
    expect(value).to be(true)
  end

  [false, true].each do |borrowed|
    it "resolves, tracks, updates and shuts down through the client with borrowed=#{borrowed}" do
      tracked, closed, events = [], [], []
      options = { datafile: datafile, log_level: "fatal", modules: [{ close: -> { closed << true } }] }
      featurevisor = Featurevisor.create_featurevisor(options) if borrowed
      instance = described_class.new(options, featurevisor: featurevisor, on_track: ->(*args) { tracked << args })
      OpenFeature::SDK.configure { |configuration| configuration.set_provider_and_wait(instance) }
      client = OpenFeature::SDK.build_client
      client.add_handler(OpenFeature::SDK::ProviderEvent::PROVIDER_ERROR) { |_| events << :error }
      client.add_handler(OpenFeature::SDK::ProviderEvent::PROVIDER_READY) { |_| events << :ready }
      context = OpenFeature::SDK::EvaluationContext.new(targeting_key: "user")
      expect(client.fetch_integer_value(flag_key: "checkout:count", default_value: 0)).to eq(3)
      expect(client.fetch_float_value(flag_key: "checkout:ratio", default_value: 0.0)).to eq(1.5)
      expect(client.fetch_object_value(flag_key: "checkout:json", default_value: {})).to eq("nested" => true)
      missing = client.fetch_boolean_details(flag_key: "missing", default_value: true)
      expect(missing.value).to be(true)
      expect(missing.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::FLAG_NOT_FOUND)
      mismatch = client.fetch_integer_details(flag_key: "checkout:ratio", default_value: 9)
      expect(mismatch.value).to eq(9)
      expect(mismatch.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
      details = { value: 3, currency: "EUR" }
      client.track("purchase", evaluation_context: context, tracking_event_details: details)
      expect(tracked.first.first).to eq("purchase")
      expect(tracked.first[1].targeting_key).to eq("user")
      expect(tracked.first[2]).to equal(details)
      updated = datafile
      updated[:features]["checkout"][:variations][0][:variables][:title] = "Updated"
      expect(instance.featurevisor.set_datafile(updated, true)).to be(true)
      expect(client.fetch_string_value(flag_key: "checkout:title", default_value: "")).to eq("Updated")
      expect(instance.featurevisor.set_datafile("{")).to be(false)
      expect(client.fetch_boolean_details(flag_key: "checkout", default_value: false).reason).to eq(OpenFeature::SDK::Provider::Reason::ERROR)
      expect(instance.featurevisor.set_datafile(updated, true)).to be(true)
      expect(client.fetch_string_value(flag_key: "checkout:title", default_value: "")).to eq("Updated")
      expect(events.last(2)).to eq([:error, :ready])
      OpenFeature::SDK.shutdown
      instance.shutdown
      expect(closed).to eq(borrowed ? [] : [true])
      if borrowed
        expect(featurevisor.set_datafile("{")).to be(false)
        expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).error_code).to be_nil
        featurevisor.close
      end
      expect(closed).to eq([true])
    ensure
      OpenFeature::SDK.shutdown
      instance&.shutdown
      featurevisor&.close
    end
  end

  it "returns a parse error for malformed datafiles" do
    instance = described_class.new(datafile: "{", log_level: "fatal")
    result = instance.fetch_boolean_value(flag_key: "checkout", default_value: false)
    expect(result.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::PARSE_ERROR)
    expect(result.error_message).to eq("Could not parse datafile")
    expect(instance.featurevisor.set_datafile(datafile, true)).to be(true)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).value).to be(true)
  end

  it "preserves provider recovery and ownership with boolean setter results" do
    featurevisor = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    instance = described_class.new(featurevisor: featurevisor)
    expect(featurevisor.set_datafile("{")).to be(false)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).error_code)
      .to eq(OpenFeature::SDK::Provider::ErrorCode::PARSE_ERROR)
    expect(featurevisor.set_datafile(datafile, true)).to be(true)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).error_code).to be_nil
    instance.shutdown
    expect(featurevisor.set_datafile("{")).to be(false)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).error_code).to be_nil
    featurevisor.close
    expect(featurevisor.set_datafile(datafile)).to be(false)
  ensure
    instance&.shutdown
    featurevisor&.close
  end

  it "uses the exact OpenFeature number resolver types" do
    instance = provider

    expect(instance.fetch_number_value(flag_key: "checkout:count", default_value: 0).value).to eq(3)
    expect(instance.fetch_integer_value(flag_key: "checkout:count", default_value: 0).value).to eq(3)
    expect(instance.fetch_float_value(flag_key: "checkout:ratio", default_value: 0.0).value).to eq(1.5)
    expect(instance.fetch_integer_value(flag_key: "checkout:ratio", default_value: 0).error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
    expect(instance.fetch_float_value(flag_key: "checkout:count", default_value: 0.0).error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
  ensure
    instance&.shutdown
  end

  it "rejects wrong types and malformed JSON variables" do
    instance = provider

    expect(instance.fetch_string_value(flag_key: "checkout", default_value: "fallback").error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
    expect(instance.fetch_boolean_value(flag_key: "checkout:title", default_value: false).error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
    expect(instance.fetch_object_value(flag_key: "checkout:invalidJson", default_value: {}).error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::TYPE_MISMATCH)
  ensure
    instance&.shutdown
  end

  it "normalizes custom fields, dates, arrays, and nested context without mutation" do
    captured = []
    original_time = Time.utc(2026, 1, 2, 3, 4, 5)
    fields = { createdAt: original_time, nested: { dates: [original_time] } }
    instance = described_class.new(
      datafile: datafile,
      log_level: "fatal",
      targeting_key_field: "accountId",
      modules: [{ name: "capture", before_evaluation: ->(options) { captured << options[:context]; options } }]
    )
    context = OpenFeature::SDK::EvaluationContext.new(targeting_key: "subject", **fields)

    instance.fetch_boolean_value(flag_key: "checkout", default_value: false, evaluation_context: context)
    expect(captured.first).to include("accountId" => "subject", "createdAt" => "2026-01-02T03:04:05Z")
    expect(captured.first.dig("nested", "dates")).to eq(["2026-01-02T03:04:05Z"])
    expect(fields[:createdAt]).to equal(original_time)
  ensure
    instance&.shutdown
  end

  it "returns stable Featurevisor metadata and the selected variant" do
    instance = provider
    result = instance.fetch_string_value(flag_key: "checkout:variation", default_value: "fallback")

    expect(result.variant).to eq("on")
    expect(result.flag_metadata).to include(
      "featureKey" => "checkout",
      "featurevisorReason" => "rule",
      "revision" => "openfeature-test",
      "schemaVersion" => "2"
    )
    expect(result.flag_metadata).to include("bucketKey", "bucketValue")
  ensure
    instance&.shutdown
  end

  it "maps a real unmet feature prerequisite to disabled" do
    blocked = datafile
    blocked[:features]["blocked"] = {
      bucketBy: "userId", requiredFeatures: ["missing"],
      traffic: [{ key: "all", segments: "*", percentage: 100_000 }]
    }
    instance = described_class.new(datafile: blocked, log_level: "fatal")
    result = instance.fetch_boolean_value(flag_key: "blocked", default_value: true)
    expect(result.value).to be(false)
    expect(result.reason).to eq(OpenFeature::SDK::Provider::Reason::DISABLED)
    expect(result.flag_metadata["featurevisorReason"]).to eq("conditions_unmet")
  ensure
    instance&.shutdown
  end

  {
    "forced" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "sticky" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "rule" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "variable_override_variation" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "variable_override_rule" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "allocated" => OpenFeature::SDK::Provider::Reason::SPLIT,
    "disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "variation_disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "variable_disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "conditions_unmet" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "variable_composed" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "no_match" => OpenFeature::SDK::Provider::Reason::DEFAULT,
    "variable_default" => OpenFeature::SDK::Provider::Reason::DEFAULT
  }.each do |featurevisor_reason, openfeature_reason|
    it "maps #{featurevisor_reason} to the expected OpenFeature reason" do
      featurevisor = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      allow(featurevisor).to receive(:evaluate_flag).and_return(
        type: "flag", feature_key: "checkout", reason: featurevisor_reason, enabled: true
      )
      instance = described_class.new(featurevisor: featurevisor)

      result = instance.fetch_boolean_value(flag_key: "checkout", default_value: false)
      expect(result.reason).to eq(openfeature_reason)
      expect(result.error_code).to be_nil
    ensure
      instance&.shutdown
      featurevisor&.close
    end
  end

  it "maps general evaluation errors" do
    featurevisor = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    allow(featurevisor).to receive(:evaluate_flag).and_return(
      type: "flag", feature_key: "checkout", reason: "error", error: StandardError.new("Evaluation failed")
    )
    instance = described_class.new(featurevisor: featurevisor)

    result = instance.fetch_boolean_value(flag_key: "checkout", default_value: false)
    expect(result.value).to be(false)
    expect(result.reason).to eq(OpenFeature::SDK::Provider::Reason::ERROR)
    expect(result.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::GENERAL)
    expect(result.error_message).to eq("Evaluation failed")
  ensure
    instance&.shutdown
    featurevisor&.close
  end

  it "borrows an existing Featurevisor instance" do
    closed = false
    featurevisor = Featurevisor.create_featurevisor(
      datafile: datafile,
      log_level: "fatal",
      modules: [{ name: "owner", close: -> { closed = true } }]
    )
    instance = described_class.new(featurevisor: featurevisor)

    expect(instance.featurevisor).to equal(featurevisor)
    instance.shutdown
    instance.shutdown
    expect(closed).to be(false)

    featurevisor.close
    expect(closed).to be(true)
  end

  it "prefers a borrowed instance over construction options" do
    featurevisor = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    instance = described_class.new(datafile: "{", featurevisor: featurevisor)

    expect(instance.featurevisor).to equal(featurevisor)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).value).to be(true)
  ensure
    instance&.shutdown
    featurevisor&.close
  end
end
