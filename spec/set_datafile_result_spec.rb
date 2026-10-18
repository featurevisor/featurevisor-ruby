require "featurevisor"
require "json"

RSpec.describe "set_datafile acceptance result" do
  def datafile(key = "original", revision = "1")
    {
      schemaVersion: "2", revision: revision,
      segments: { key => { conditions: "*" } },
      features: { key => { hash: key, bucketBy: "userId", traffic: [
        { key: "all", segments: "*", percentage: 100_000 }
      ] } },
      variables: { key => { hash: key, type: "string", defaultValue: key } }
    }
  end

  it "accepts empty datafiles and changed content with the same revision" do
    sdk = Featurevisor.create_featurevisor(log_level: "fatal")
    empty = { schemaVersion: "2", revision: "1", segments: {}, features: {} }
    expect(sdk.set_datafile(empty)).to be(true)
    expect(sdk.set_datafile(JSON.generate(empty))).to be(true)
    expect(sdk.set_datafile(datafile, true)).to be(true)
    expect(sdk.is_enabled("original")).to be(true)
    expect(sdk.set_datafile(empty, true)).to be(true)
    expect(sdk.get_feature_keys).to eq([])
    expect(sdk.get_variable_keys).to eq([])
    expect(sdk.get_revision).to eq("1")
  ensure
    sdk&.close
  end

  [false, true].each do |json|
    [false, true].each do |replace|
      it "accepts content and unchanged updates with json=#{json}, replace=#{replace}" do
        sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
        child = sdk.spawn
        events = []
        sdk.on("datafile_set", ->(event) { events << event })
        incoming = datafile("next", "2")
        original = Marshal.load(Marshal.dump(incoming))
        input = json ? JSON.generate(incoming) : incoming
        expect(replace ? sdk.set_datafile(input, true) : sdk.set_datafile(input)).to be(true)
        expect(incoming).to eq(original)
        expect(sdk.get_revision).to eq("2")
        expect(sdk.get_feature_keys).to eq(replace ? [:next] : [:original, :next])
        expect(sdk.get_variable_keys).to eq(replace ? [:next] : [:original, :next])
        expect(sdk.get_segment("original").nil?).to eq(replace)
        expect(child.is_enabled("next")).to be(true)
        expect(child.get_variable("next")).to eq("next")
        expect(events).to eq([{
          revision: "2", previousRevision: "1", revisionChanged: true,
          features: replace ? [:original, :next] : [:next],
          variables: replace ? [:original, :next] : [:next], replaced: replace
        }])
        expect(sdk.set_datafile(input, replace)).to be(true)
        expect(events.length).to eq(2)
        expect(events.last).to eq({
          revision: "2", previousRevision: "2", revisionChanged: false,
          features: [], variables: [], replaced: replace
        })
      ensure
        child&.close
        sdk&.close
      end
    end
  end

  ["info", "fatal"].each do |level|
    it "preserves state and reports each rejection once at #{level}" do
      diagnostics, events, errors = [], [], []
      sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: level,
        on_diagnostic: ->(diagnostic) { diagnostics << diagnostic })
      child = sdk.spawn
      diagnostics.clear
      sdk.on("datafile_set", ->(event) { events << event })
      sdk.on("error", ->(event) { errors << event })
      invalid = ["{", "null", "[]", nil, false, 1, [], {},
        datafile.merge(schemaVersion: 2), datafile.merge(revision: 2),
        datafile.merge(segments: []), datafile.merge(features: []), datafile.merge(variables: [])]
      invalid.each do |input|
        [false, true].each do |replace|
          expect(sdk.set_datafile(input, replace)).to be(false)
          expect(sdk.get_revision).to eq("1")
          expect(sdk.get_feature_keys).to eq([:original])
          expect(sdk.get_segment("original")).not_to be_nil
          expect(child.is_enabled("original")).to be(true)
          expect(child.get_variable("original")).to eq("original")
          expect(errors.last[:diagnostic]).to include(code: "invalid_datafile", message: "Could not parse datafile")
          expect(errors.last[:diagnostic][:originalError]).to be_a(StandardError)
        end
      end
      expect(events).to eq([])
      expect(errors.length).to eq(invalid.length * 2)
      expect(diagnostics.length).to eq(level == "info" ? invalid.length * 2 : 0)
      expect(sdk.set_datafile(datafile, true)).to be(true)
    ensure
      child&.close
      sdk&.close
    end
  end

  it "returns false after close without diagnostics or parsing" do
    diagnostics = []
    sdk = Featurevisor.create_featurevisor(datafile: datafile, on_diagnostic: ->(diagnostic) { diagnostics << diagnostic })
    sdk.close
    diagnostics.clear
    expect(sdk.set_datafile(datafile("next", "2"))).to be(false)
    expect(sdk.set_datafile("{", true)).to be(false)
    expect(sdk.get_revision).to eq("1")
    expect(diagnostics).to eq([])
  end

  it "isolates throwing callbacks without changing acceptance or rejection" do
    diagnostics, events, errors = [], [], []
    fail_callback = ->(_value) { raise "callback failed" }
    sdk = Featurevisor.create_featurevisor(
      on_diagnostic: ->(diagnostic) {
        diagnostics << diagnostic[:code]
        raise "callback failed"
      },
      modules: [{ name: "throwing", setup: ->(api) { api[:on_diagnostic].call(fail_callback) } }]
    )
    diagnostics.clear
    sdk.on("datafile_set", fail_callback)
    sdk.on("datafile_set", ->(event) { events << event })
    sdk.on("error", fail_callback)
    sdk.on("error", ->(event) { errors << event })
    expect(sdk.set_datafile(datafile)).to be(true)
    expect(sdk.set_datafile(datafile)).to be(true)
    expect(sdk.set_datafile("{")).to be(false)
    expect(diagnostics).to eq(%w[datafile_set datafile_set invalid_datafile])
    expect(events.length).to eq(2)
    expect(errors.length).to eq(1)
    expect(sdk.get_revision).to eq("1")
  ensure
    sdk&.close
  end
end
