require "featurevisor/openfeature_provider"

RSpec.describe Featurevisor::OpenFeatureProvider do
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
      }
    }
  end

  def provider(**options)
    described_class.new({ datafile: datafile, log_level: "fatal" }, **options)
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

  it "returns a parse error for malformed datafiles" do
    instance = described_class.new(datafile: "{", log_level: "fatal")
    result = instance.fetch_boolean_value(flag_key: "checkout", default_value: false)
    expect(result.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::PARSE_ERROR)
    expect(result.error_message).to eq("Could not parse datafile")
    instance.featurevisor.set_datafile(datafile, true)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).value).to be(true)
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
      modules: [{ name: "capture", before: ->(options) { captured << options[:context]; options } }]
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

  {
    "required" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "forced" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "sticky" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "rule" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "variable_override_variation" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "variable_override_rule" => OpenFeature::SDK::Provider::Reason::TARGETING_MATCH,
    "allocated" => OpenFeature::SDK::Provider::Reason::SPLIT,
    "disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "variation_disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "variable_disabled" => OpenFeature::SDK::Provider::Reason::DISABLED,
    "out_of_range" => OpenFeature::SDK::Provider::Reason::DEFAULT,
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
