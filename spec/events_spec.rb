require "featurevisor"

RSpec.describe Featurevisor::Events do
  let(:diagnostics) { Featurevisor.const_get(:DiagnosticReporter).new(level: "error") }

  describe ".get_params_for_sticky_features_set_event" do
    it "should get params for sticky set event: empty to new" do
      previous_sticky_features = {}
      new_sticky_features = {
        feature2: { enabled: true },
        feature3: { enabled: true }
      }
      replace = true

      result = described_class.get_params_for_sticky_features_set_event(
        previous_sticky_features,
        new_sticky_features,
        replace
      )

      expect(result).to eq({
        features: %i[feature2 feature3],
        replaced: replace
      })
    end

    it "should get params for sticky set event: add, change, remove" do
      previous_sticky_features = {
        feature1: { enabled: true },
        feature2: { enabled: true }
      }
      new_sticky_features = {
        feature2: { enabled: true },
        feature3: { enabled: true }
      }
      replace = true

      result = described_class.get_params_for_sticky_features_set_event(
        previous_sticky_features,
        new_sticky_features,
        replace
      )

      expect(result).to eq({
        features: %i[feature1 feature2 feature3],
        replaced: replace
      })
    end
  end

  describe ".get_params_for_datafile_set_event" do
    def build_reader(revision:, features:, variables: {})
      Featurevisor.const_get(:InstanceEvaluationDataProvider).new(
        datafile: {
          schemaVersion: "1.0.0",
          revision: revision,
          features: features,
          segments: {},
          variables: variables
        },
        diagnostics: diagnostics
      )
    end

    it "reports all initially added entities without constructing dependency indexes" do
      previous = build_reader(revision: "empty", features: {})
      current = build_reader(revision: "loaded", features: {
        subject: { hash: "subject", conditions: { variable: "policy", operator: "notNull" } },
        gate: { hash: "gate", conditions: { feature: "subject" } }
      }, variables: {
        policy: { hash: "policy", type: "object", compose: [{ key: "enabled", feature: "gate" }] }
      })
      expect(Featurevisor.const_get(:Dependencies)).not_to receive(:create_index)
      expect(described_class.get_params_for_datafile_set_event(previous, current, true)).to eq(
        revision: "loaded", previousRevision: "empty", revisionChanged: true,
        features: %i[subject gate], variables: [:policy], replaced: true
      )
    end

    it "still indexes existing dependents when an update contains only new definitions" do
      previous = build_reader(revision: "old", features: {
        subject: { hash: "unchanged", conditions: { variable: "policy", operator: "notNull" } }
      })
      current = build_reader(revision: "new", features: previous.features, variables: {
        policy: { hash: "new", type: "string", defaultValue: "available" }
      })
      result = described_class.get_params_for_datafile_set_event(previous, current)
      expect(result[:features]).to eq([:subject])
      expect(result[:variables]).to eq([:policy])
    end

    it "should get params for datafile set event: empty to new" do
      previous_reader = build_reader(revision: "1", features: {})
      new_reader = build_reader(
        revision: "2",
        features: {
          feature1: { bucketBy: "userId", hash: "hash1", traffic: [] },
          feature2: { bucketBy: "userId", hash: "hash2", traffic: [] }
        }
      )

      result = described_class.get_params_for_datafile_set_event(previous_reader, new_reader)

      expect(result).to eq({
        revision: "2",
        previousRevision: "1",
        revisionChanged: true,
        features: %i[feature1 feature2],
        variables: [],
        replaced: false
      })
    end

    it "should get params for datafile set event: change hash, addition" do
      previous_reader = build_reader(
        revision: "1",
        features: {
          feature1: { bucketBy: "userId", hash: "hash-same", traffic: [] },
          feature2: { bucketBy: "userId", hash: "hash1-2", traffic: [] }
        }
      )
      new_reader = build_reader(
        revision: "2",
        features: {
          feature1: { bucketBy: "userId", hash: "hash-same", traffic: [] },
          feature2: { bucketBy: "userId", hash: "hash2-2", traffic: [] },
          feature3: { bucketBy: "userId", hash: "hash2-3", traffic: [] }
        }
      )

      result = described_class.get_params_for_datafile_set_event(previous_reader, new_reader)

      expect(result).to eq({
        revision: "2",
        previousRevision: "1",
        revisionChanged: true,
        features: %i[feature2 feature3],
        variables: [],
        replaced: false
      })
    end

    it "should get params for datafile set event: change hash, removal" do
      previous_reader = build_reader(
        revision: "1",
        features: {
          feature1: { bucketBy: "userId", hash: "hash-same", traffic: [] },
          feature2: { bucketBy: "userId", hash: "hash1-2", traffic: [] }
        }
      )
      new_reader = build_reader(
        revision: "2",
        features: {
          feature2: { bucketBy: "userId", hash: "hash2-2", traffic: [] }
        }
      )

      result = described_class.get_params_for_datafile_set_event(previous_reader, new_reader)

      expect(result).to eq({
        revision: "2",
        previousRevision: "1",
        revisionChanged: true,
        features: %i[feature1 feature2],
        variables: [],
        replaced: false
      })
    end

    it "marks identical features and global variables with empty hashes as changed" do
      features = {
        feature1: { bucketBy: "userId", hash: "", traffic: [] }
      }
      variables = {
        variable1: { type: "string", defaultValue: "value", hash: "" }
      }
      previous_reader = build_reader(revision: "1", features: features, variables: variables)
      new_reader = build_reader(revision: "2", features: features, variables: variables)

      result = described_class.get_params_for_datafile_set_event(previous_reader, new_reader)

      expect(result[:features]).to eq([:feature1])
      expect(result[:variables]).to eq([:variable1])
    end
  end
end
