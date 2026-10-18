# frozen_string_literal: true

require "featurevisor"

RSpec.describe "full refresh ownership" do
  %w[2 4].each do |schema|
    [false, true].each do |replace|
      it "keeps nested values and cold readers independent for schema #{schema}, replace #{replace}" do
        payload = { conditions: { variable: "ignored", operator: "notNull" }, rows: [{ label: "old" }] }
        definition = { type: "object", hash: "same", defaultValue: payload, metadata: { nested: ["old"] } }
        source = { schemaVersion: schema, revision: "initial", segments: {}, features: {}, variables: {
          value: definition, cold: definition, removed: definition,
          broken: { type: "boolean", defaultValue: true, conditions: "[", hash: "same" }
        } }
        errors = []
        sdk = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) {
          errors << item if item[:code] == "conditions_parse_error"
        })
        old = sdk.instance_variable_get(:@datafile)
        expect(errors.length).to eq(schema == "2" ? 1 : 0)
        2.times { expect(sdk.get_variable("broken")).to be_nil }
        expect(errors.length).to eq(1)
        expect(sdk.get_variable("value")).to eq(payload)
        updated = Marshal.load(Marshal.dump(source))
        updated[:revision] = "next"
        updated[:variables].delete(:removed)
        updated[:variables].values_at(:value, :cold).each do |entry|
          entry[:defaultValue][:rows][0][:label] = "new"
          entry[:metadata][:nested][0] = "new"
        end
        expect(sdk.set_datafile(updated, replace)).to be(true)
        updated[:variables][:value][:defaultValue][:rows][0][:label] = "caller"
        expect(sdk.get_variable("value")[:rows][0][:label]).to eq("new")
        expect(sdk.get_variable("cold")[:rows][0][:label]).to eq("new")
        current = sdk.instance_variable_get(:@datafile)
        expect(current.get_global_variable("cold")[:metadata]).to eq(nested: ["new"])
        expect(old.get_global_variable("cold")[:metadata]).to eq(nested: ["old"])
        expect(old.get_global_variable("cold")[:defaultValue][:rows][0][:label]).to eq("old")
        2.times { expect(sdk.get_variable("broken")).to be_nil }
        expect(errors.length).to eq(2)
        expect(sdk.get_variable_keys.include?(:removed)).to eq(!replace)
        events = []
        sdk.on("datafile_set", ->(event) { events << event })
        expect(sdk.set_datafile({ schemaVersion: schema, revision: "payload", segments: {}, features: {}, variables: {
          ignored: { type: "integer", defaultValue: 1, hash: "new" }
        } })).to be(true)
        expect(events.last[:variables]).to eq([:ignored])
        expect(sdk.set_datafile({ schemaVersion: schema, revision: "empty", segments: {}, features: {}, variables: {} }, true)).to be(true)
        expect(sdk.get_variable_keys).to be_empty
        expect(sdk.instance_variable_get(:@datafile).normalized.values).to all(be_empty)
      ensure
        sdk&.close
      end
    end
  end
end
