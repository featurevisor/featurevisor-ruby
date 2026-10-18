# frozen_string_literal: true

require "featurevisor"

RSpec.describe "Evaluation session bookkeeping" do
  it "does not allocate prerequisite fingerprint options on ordinary global roots" do
    sdk = Featurevisor.create_featurevisor(log_level: "fatal", datafile: {
      schemaVersion: "4", revision: "allocations", features: {}, segments: {
        eligible: { conditions: '{"attribute":"country","operator":"equals","value":"de"}' }
      }, variables: {
        value: { type: "object", defaultValue: { currency: "USD" }, overrides: [
          { key: "eligible", conditions: "eligible", value: { currency: "EUR" } }
        ] }
      }
    })
    context = { country: "de", userId: "one" }
    20.times { expect(sdk.get_variable("value", context)).to eq(currency: "EUR") }
    expect(sdk).not_to receive(:global_variable_session_options)
    before = GC.stat(:total_allocated_objects)
    100.times { sdk.get_variable("value", context) }
    allocated = GC.stat(:total_allocated_objects) - before
    expect(allocated).to be <= 2000
  ensure
    sdk&.close
  end

  it "keeps ordinary roots free of dependency containers and identity copies" do
    session = Featurevisor::EvaluationSession.new
    options = { type: "flag", feature_key: "root", context: {} }
    2.times do
      session.run(options) do
        original = session.dependency_of
        session.update_current(options.merge(context: { country: "nl" }))
        expect(session.dependency_of).to equal(original)
        %i[@active @memo @sticky_inputs @segments].each do |name|
          expect(session.instance_variable_get(name)).to be_nil
        end
      end
      expect(session.dependency_of).to be_nil
      expect(session.instance_variable_get(:@root)).to be_nil
    end
  end

  it "activates bookkeeping at a handoff and retains both original and redirected roots" do
    session = Featurevisor::EvaluationSession.new
    original = { type: "flag", feature_key: "root", context: {} }
    redirected = original.merge(feature_key: "redirected")
    expect do
      session.run(original) do
        session.update_current(redirected)
        expect(session.dependency_of).to eq(type: "flag", feature_key: "redirected")
        session.segment("gate") do
          session.run(original, prerequisite: true) { raise "cycle was missed" }
        end
      end
    end.to raise_error(Featurevisor::RequirementCycleError)
    expect(session.dependency_of).to be_nil
    expect(session.instance_variable_get(:@segments)).to be_empty
    expect(session.instance_variable_get(:@pending_error)).to be_nil
    session.run(original) do
      session.update_current(redirected)
      expect { session.run(redirected, prerequisite: true) {} }.to raise_error(Featurevisor::RequirementCycleError)
    end
    expect(session.run(original) { :recovered }).to eq(:recovered)
  end

  def datafile
    {
      schemaVersion: "4", revision: "session-bookkeeping", segments: {
        audience: { conditions: { and: [
          { attribute: "country", operator: "equals", value: "nl" },
          { not: [{ attribute: "blocked", operator: "equals", value: true }] }
        ] } },
        dependent: { conditions: { feature: "leaf" } }
      }, features: {
        root: { conditions: "audience", bucketBy: "userId",
                traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] },
        leaf: { conditions: "*", bucketBy: "userId",
                traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] },
        mixed: { conditions: "dependent", bucketBy: "userId",
                 traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
      }, variables: {}
    }
  end

  it "classifies each segment syntax once while evaluating fresh contexts" do
    sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    provider = sdk.instance_variable_get(:@datafile)
    syntax = provider.get_segment("audience")[:conditions]
    allow(Featurevisor::UnifiedConditions).to receive(:attribute_only?).and_call_original
    expect(Featurevisor::UnifiedConditions).to receive(:attribute_only?).with(syntax).once.and_call_original
    3.times do
      expect(sdk.is_enabled("root", country: "nl")).to be(true)
      expect(sdk.is_enabled("root", country: "us")).to be(false)
      expect(sdk.is_enabled("root", country: "nl", blocked: true)).to be(false)
    end
    cache = provider.instance_variable_get(:@attribute_conditions_cache)
    expect(cache[syntax.object_id]).to eq([syntax, true])
    expect(cache[syntax.object_id][0]).to equal(syntax)
    expect(provider.get_feature("root")).to equal(provider.get_feature("root"))
    expect(provider.get_segment("audience")).to equal(provider.get_segment("audience"))
    sdk.close
    expect(cache).to be_empty
  ensure
    sdk&.close
  end

  it "keeps mixed segment dependencies on the session path and refreshes syntax after updates" do
    reads = []
    sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal", modules: [{
      before_evaluation: ->(options) { reads << options; options }
    }])
    2.times do
      expect(sdk.is_enabled("mixed")).to be(true)
      expect(reads.last[:dependency_of]).to eq(type: "flag", feature_key: "mixed")
      expect(reads.last[:dependency_purpose]).to eq("condition")
    end
    sdk.set_sticky_features({ "leaf" => { enabled: false } })
    expect(sdk.is_enabled("mixed")).to be(false)
    expect(sdk.is_enabled("root", country: "nl")).to be(true)
    updated = datafile
    updated[:revision] = "next"
    updated[:segments][:audience][:conditions] = { attribute: "country", operator: "equals", value: "us" }
    expect(sdk.set_datafile(updated, true)).to be(true)
    expect(sdk.is_enabled("root", country: "nl")).to be(false)
    expect(sdk.is_enabled("root", country: "us")).to be(true)
  ensure
    sdk&.close
  end
end
