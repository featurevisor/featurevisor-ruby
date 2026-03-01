require "featurevisor"

RSpec.describe Featurevisor::Events do
  let(:logger) { Featurevisor.create_logger(level: "error") }

  describe ".get_params_for_sticky_set_event" do
    it "should get params for sticky set event: empty to new" do
      previous_sticky_features = {}
      new_sticky_features = {
        feature2: { enabled: true },
        feature3: { enabled: true }
      }
      replace = true

      result = described_class.get_params_for_sticky_set_event(
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

      result = described_class.get_params_for_sticky_set_event(
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
    def build_reader(revision:, features:)
      Featurevisor::DatafileReader.new(
        datafile: {
          schemaVersion: "1.0.0",
          revision: revision,
          features: features,
          segments: {}
        },
        logger: logger
      )
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
        previous_revision: "1",
        revision_changed: true,
        features: %i[feature1 feature2]
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
        previous_revision: "1",
        revision_changed: true,
        features: %i[feature2 feature3]
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
        previous_revision: "1",
        revision_changed: true,
        features: %i[feature1 feature2]
      })
    end
  end
end
