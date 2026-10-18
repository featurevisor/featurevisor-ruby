require "featurevisor"
require "json"

RSpec.describe "Feature allocation" do
  def flag(key, percentage = 100_000)
    {
      key: key, bucketBy: "userId",
      traffic: [{ key: "1", segments: "*", percentage: percentage, allocation: [] }]
    }
  end

  def datafile(features)
    { schemaVersion: "2", revision: "1", segments: {}, features: features }
  end

  it "ignores legacy ranges as unknown fields without warnings" do
    [nil, [], [[50_000, 100_000]], [[0, 100_000]], "ignored"].each do |ranges|
      [0, 50_000, 100_000].each do |percentage|
        [nil, false, true].each do |enabled|
          feature = flag("test", percentage)
          feature[:traffic][0][:enabled] = enabled unless enabled.nil?
          baseline = Featurevisor.create_featurevisor(datafile: datafile(test: feature), log_level: "warn")
          diagnostics = []
          sdk = Featurevisor.create_featurevisor(
            datafile: JSON.generate(datafile(test: feature.merge(ranges: ranges))),
            log_level: "warn",
            on_diagnostic: ->(diagnostic) { diagnostics << diagnostic }
          )
          32.times do |user|
            context = { userId: "user-#{user}" }
            expect(sdk.evaluate_flag("test", context)).to eq(baseline.evaluate_flag("test", context))
          end
          expect(diagnostics).to be_empty
          sdk.close
          baseline.close
        end
      end
    end
  end

  it "uses ordinary percentage and variation boundaries when JSON contains obsolete metadata" do
    feature = flag("test", 50_000)
    feature[:ranges] = [[50_001, 100_000]]
    feature[:variations] = [{ value: "control" }, { value: "treatment" }]
    feature[:traffic][0][:allocation] = [
      { variation: "control", range: [0, 25_000] },
      { variation: "treatment", range: [25_000, 50_000] }
    ]
    bucket = 0
    diagnostics = []
    sdk = Featurevisor.create_featurevisor(
      datafile: JSON.generate(datafile(test: feature)),
      log_level: "warn",
      on_diagnostic: ->(event) { diagnostics << event },
      modules: [{ name: "boundary", bucket_value: ->(_options) { bucket } }]
    )
    [[0, "control"], [25_000, "control"], [25_001, "treatment"],
      [50_000, "treatment"], [50_001, nil], [100_000, nil]].each do |value, expected|
      bucket = value
      expect(sdk.is_enabled("test", { userId: "user" })).to eq(value <= 50_000)
      expect(sdk.get_variation("test", { userId: "user" })).to eq(expected)
    end
    expect(diagnostics).to be_empty
  ensure
    sdk&.close
  end

  it "uses normal hashing for required variation cohorts and priority exclusion" do
    features = %w[cohort experimentA experimentB priority fallback].to_h { |key| [key.to_sym, flag(key)] }
    features[:cohort][:variations] = %w[a b holdout].map { |value| { value: value } }
    features[:cohort][:traffic][0][:allocation] = [
      { variation: "a", range: [0, 40_000] },
      { variation: "b", range: [40_000, 80_000] },
      { variation: "holdout", range: [80_000, 100_000] }
    ]
    features[:experimentA][:requiredFeatures] = [{ feature: "cohort", variation: "a" }]
    features[:experimentB][:requiredFeatures] = [{ feature: "cohort", variation: "b" }]
    features[:priority][:traffic][0][:percentage] = 50_000
    features[:fallback][:requiredFeatures] = [{ feature: "priority", enabled: false }]
    sdk = Featurevisor.create_featurevisor(datafile: datafile(features), log_level: "warn")
    counts = { "a" => 0, "b" => 0, "holdout" => 0, "priority" => 0, "fallback" => 0 }
    cohort_overlap = priority_overlap = 0
    20_000.times do |user|
      context = { userId: "user-#{user}" }
      variation = sdk.get_variation("cohort", context)
      expect(%w[a b holdout]).to include(variation)
      counts[variation] += 1
      a = sdk.is_enabled("experimentA", context)
      b = sdk.is_enabled("experimentB", context)
      expect(a).to eq(variation == "a")
      expect(b).to eq(variation == "b")
      cohort_overlap += 1 if a && b
      expect(!a && !b).to eq(variation == "holdout")
      priority = sdk.is_enabled("priority", context)
      fallback = sdk.is_enabled("fallback", context)
      expect(priority).not_to eq(fallback)
      priority_overlap += 1 if priority && fallback
      counts[priority ? "priority" : "fallback"] += 1
    end
    expect(cohort_overlap).to eq(0)
    expect(priority_overlap).to eq(0)
    expect(counts.values_at("a", "b", "holdout").sum).to eq(20_000)
    expect(counts.values_at("priority", "fallback").sum).to eq(20_000)
    # Allow two percentage points around each intended population share.
    { "a" => 8000, "b" => 8000, "holdout" => 4000, "priority" => 10_000, "fallback" => 10_000 }.each do |key, expected|
      expect(counts[key]).to be_within(400).of(expected)
    end
  ensure
    sdk&.close
  end
end
