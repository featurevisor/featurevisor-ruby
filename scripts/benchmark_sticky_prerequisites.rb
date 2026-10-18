# frozen_string_literal: true

require "json"
require_relative "../lib/featurevisor"

iterations = [Integer(ARGV.fetch(0, "1000")), 1].max
exported = ARGV[1] && JSON.parse(File.read(ARGV[1]), symbolize_names: true)
traffic = [{ key: "all", segments: "*", percentage: 100_000 }]
datafile = exported || { schemaVersion: "2", revision: "sticky-benchmark", segments: {}, features: {}, variables: {} }
datafile[:features][:leafFlag] = { bucketBy: "userId", traffic: traffic }
datafile[:variables] ||= {}
datafile[:variables][:source] = { type: "integer", defaultValue: 1 }
# Add the nonsticky global gate only after loading or constructing the exported shape.
datafile[:variables][:featureGated] = { type: "integer", defaultValue: 1,
                                        requiredFeatures: ["leafFlag", "leafFlag"] }
datafile[:variables][:gated] = { type: "integer", defaultValue: 1,
                                 requiredVariables: Array.new(2) { { variable: "source", operator: "equals", value: 1 } } }

puts "kind,size,owner,mean_microseconds_per_evaluation,iterations"
%w[features variables].each do |kind|
  [0, 100, 1000, 5000].each do |size|
    sticky = size.times.to_h do |index|
      ["unrelated#{index}", kind == "features" ? { enabled: true } : index]
    end
    %w[instance child].each do |owner_name|
      field = kind == "features" ? :sticky_features : :sticky_variables
      # The no op hook exercises the public sticky handoff on every prerequisite.
      sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal",
                                             modules: [{ before_evaluation: ->(options) { options } }], field => sticky)
      owner = owner_name == "child" ? sdk.spawn({}, field => sticky) : sdk
      read = if kind == "features"
               -> { owner.get_variable("featureGated", { userId: "bench" }) == 1 }
             else
               -> { owner.get_variable("gated", { userId: "bench" }) == 1 }
             end
      100.times { raise "Incorrect warmup result" unless read.call }
      total = 0
      iterations.times do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        raise "Incorrect benchmark result" unless read.call
        total += Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
      end
      puts format("%s,%d,%s,%.3f,%d", kind, size, owner_name, total.to_f / iterations / 1000, iterations)
      owner.close if owner_name == "child"
      sdk.close
    end
  end
end
