require "featurevisor"

RSpec.describe Featurevisor::Bucketer do
  describe "get_bucketed_number" do
    it "should be a method" do
      expect(Featurevisor::Bucketer).to respond_to(:get_bucketed_number)
    end

    it "should return a number between 0 and 100000" do
      keys = ["foo", "bar", "baz", "123adshlk348-93asdlk"]

      keys.each do |key|
        n = Featurevisor::Bucketer.get_bucketed_number(key)

        expect(n).to be >= 0
        expect(n).to be <= Featurevisor::Bucketer::MAX_BUCKETED_NUMBER
      end
    end

    # These assertions will be copied to unit tests of SDKs ported to other languages,
    # so we can keep consistent bucketing across all SDKs
    it "should return expected number for known keys" do
      expected_results = {
        "foo" => 20_602,
        "bar" => 89_144,
        "123.foo" => 3_151,
        "123.bar" => 9_710,
        "123.456.foo" => 14_432,
        "123.456.bar" => 1_982
      }

      expected_results.each do |key, expected_value|
        n = Featurevisor::Bucketer.get_bucketed_number(key)

        expect(n).to eq(expected_value)
      end
    end
  end

  describe "get_bucket_key" do
    let(:diagnostics) { Featurevisor.const_get(:DiagnosticReporter).new(level: "warn") }

    it "should be a method" do
      expect(Featurevisor::Bucketer).to respond_to(:get_bucket_key)
    end

    it "plain: should return a bucket key for a plain bucketBy" do
      feature_key = "test-feature"
      bucket_by = "userId"
      context = { userId: "123", browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("123.test-feature")
    end

    it "plain: should return a bucket key with feature key only if value is missing in context" do
      feature_key = "test-feature"
      bucket_by = "userId"
      context = { browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("test-feature")
    end

    it "and: should combine multiple field values together if present" do
      feature_key = "test-feature"
      bucket_by = ["organizationId", "userId"]
      context = { organizationId: "123", userId: "234", browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("123.234.test-feature")
    end

    it "and: should combine only available field values together if present" do
      feature_key = "test-feature"
      bucket_by = ["organizationId", "userId"]
      context = { organizationId: "123", browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("123.test-feature")
    end

    it "and: should combine all available fields, with dot separated paths" do
      feature_key = "test-feature"
      bucket_by = ["organizationId", "user.id"]
      context = {
        organizationId: "123",
        user: {
          id: "234"
        },
        browser: "chrome"
      }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("123.234.test-feature")
    end

    it "or: should take first available field value" do
      feature_key = "test-feature"
      bucket_by = { or: ["userId", "deviceId"] }
      context = { deviceId: "deviceIdHere", userId: "234", browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("234.test-feature")
    end

    it "or: should take first available field value when userId is missing" do
      feature_key = "test-feature"
      bucket_by = { or: ["userId", "deviceId"] }
      context = { deviceId: "deviceIdHere", browser: "chrome" }

      bucket_key = Featurevisor::Bucketer.get_bucket_key(
        feature_key: feature_key,
        bucket_by: bucket_by,
        context: context,
        diagnostics: diagnostics
      )

      expect(bucket_key).to eq("deviceIdHere.test-feature")
    end

    it "should raise error for invalid bucketBy" do
      feature_key = "test-feature"
      bucket_by = { invalid: "config" }
      context = { userId: "123" }

      expect do
        Featurevisor::Bucketer.get_bucket_key(
          feature_key: feature_key,
          bucket_by: bucket_by,
          context: context,
          diagnostics: diagnostics
        )
      end.to raise_error(StandardError, "invalid bucketBy")
    end

    it "stringifies bucket values like JavaScript" do
      diagnostics = Featurevisor.const_get(:DiagnosticReporter).new(level: "fatal")

      expect(Featurevisor::Bucketer.get_bucket_key(
        feature_key: "feature", bucket_by: %w[missing enabled values object],
        context: { missing: nil, enabled: false, values: [1, true, nil], object: { id: 1 } },
        diagnostics: diagnostics
      )).to eq(".false.1,true,.[object Object].feature")
    end

    it "normalizes whole floating point values and negative zero like JavaScript" do
      diagnostics = Featurevisor.const_get(:DiagnosticReporter).new(level: "fatal")

      expect(Featurevisor::Bucketer.get_bucket_key(
        feature_key: "feature", bucket_by: %w[whole negative_zero small large],
        context: { whole: 1.0, negative_zero: -0.0, small: 1e-6, large: 1e21 }, diagnostics: diagnostics
      )).to eq("1.0.0.000001.1e+21.feature")
    end
  end

  describe "constants" do
    it "should have MAX_BUCKETED_NUMBER constant" do
      expect(Featurevisor::Bucketer::MAX_BUCKETED_NUMBER).to eq(100_000)
    end

    it "should have HASH_SEED constant" do
      expect(Featurevisor::Bucketer::HASH_SEED).to eq(1)
    end

    it "should have MAX_HASH_VALUE constant" do
      expect(Featurevisor::Bucketer::MAX_HASH_VALUE).to eq(2**32)
    end

    it "should have DEFAULT_BUCKET_KEY_SEPARATOR constant" do
      expect(Featurevisor::Bucketer::DEFAULT_BUCKET_KEY_SEPARATOR).to eq(".")
    end
  end
end
