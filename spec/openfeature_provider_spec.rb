require "featurevisor/openfeature_provider"

RSpec.describe Featurevisor::OpenFeatureProvider do
  let(:datafile) do
    {
      schemaVersion: "2", revision: "openfeature-test", segments: {},
      features: {
        "checkout" => {
          bucketBy: "userId",
          variations: [{ value: "on", variables: { title: "Hello", count: 3, ratio: 1.5, visible: true, items: ["a"], config: { color: "blue" }, json: '{"nested":true}' } }],
          variablesSchema: {
            title: { type: "string", defaultValue: "Default" }, count: { type: "integer", defaultValue: 0 },
            ratio: { type: "double", defaultValue: 0 }, visible: { type: "boolean", defaultValue: false },
            items: { type: "array", defaultValue: [] }, config: { type: "object", defaultValue: {} }, json: { type: "json", defaultValue: "{}" }
          },
          force: [{ conditions: { attribute: "userId", operator: "equals", value: "forced-user" }, enabled: true, variation: "on" }],
          traffic: [{ key: "all", segments: "*", percentage: 100_000, variation: "on" }]
        }
      }
    }
  end

  def provider(**options)
    described_class.new({ datafile: datafile, logLevel: "fatal" }, **options)
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
    instance = described_class.new({ datafile: "{", logLevel: "fatal" })
    result = instance.fetch_boolean_value(flag_key: "checkout", default_value: false)
    expect(result.error_code).to eq(OpenFeature::SDK::Provider::ErrorCode::PARSE_ERROR)
    expect(result.error_message).to eq("Could not parse datafile")
    instance.featurevisor.set_datafile(datafile, true)
    expect(instance.fetch_boolean_value(flag_key: "checkout", default_value: false).value).to be(true)
  end

  it "borrows an existing Featurevisor instance" do
    closed = false
    featurevisor = Featurevisor.create_featurevisor(
      datafile: datafile,
      logLevel: "fatal",
      modules: [{ name: "owner", close: -> { closed = true } }]
    )
    instance = described_class.new(featurevisor: featurevisor)

    expect(instance.featurevisor).to equal(featurevisor)
    instance.shutdown
    expect(closed).to be(false)

    featurevisor.close
    expect(closed).to be(true)
  end
end
