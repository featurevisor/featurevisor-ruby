# frozen_string_literal: true

require "featurevisor"
require "timeout"

RSpec.describe "lazy normalization concurrency" do
  def datafile(revision = "initial")
    { schemaVersion: "4", revision: revision, segments: {}, features: {}, variables: {} }
  end

  def feature
    { bucketBy: [], traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
  end

  def wait_for_thread(thread)
    Timeout.timeout(5) { Thread.pass while thread.alive? && thread.status != "sleep" }
  end

  def join_threads(threads)
    Timeout.timeout(10) { threads.map(&:value) }
  ensure
    threads.each { |thread| thread.kill if thread.alive? }
    threads.each(&:join)
  end

  { feature: [:features, :get_feature], segment: [:segments, :get_segment], variable: [:variables, :get_global_variable] }.each do |kind, (collection, getter)|
    it "publishes a cold #{kind} once before concurrent readers and reentrant diagnostics" do
      source = datafile
      definition = kind == :feature ? feature : kind == :variable ? { type: "boolean", defaultValue: true } : {}
      source[collection][:broken] = definition.merge(conditions: "{broken")
      source[collection][:healthy] = definition.merge(conditions: "*")
      captured = Queue.new
      reentries = Queue.new
      f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) {
        next unless item[:code] == "conditions_parse_error"
        captured << item
        # A different thread must be able to acquire the cache lock during the callback.
        worker = Thread.new do
          provider = f.instance_variable_get(:@datafile)
          value = provider.public_send(getter, "broken")
          provider.public_send(getter, "healthy")
          value
        end
        reentries << join_threads([worker]).first
      })
      provider = f.instance_variable_get(:@datafile)
      entered, release, attempted = Queue.new, Queue.new, Queue.new
      calls = Queue.new
      allow(Featurevisor::Normalize).to receive(:entity).and_wrap_original do |original, *args|
        calls << args.first(2)
        if Thread.current[:first_reader]
          entered << true
          release.pop
        end
        original.call(*args)
      end
      threads = [Thread.new { Thread.current[:first_reader] = true; provider.public_send(getter, "broken") }]
      Timeout.timeout(5) { entered.pop }
      threads << Thread.new { attempted << true; provider.public_send(getter, "broken") }
      Timeout.timeout(5) { attempted.pop }
      wait_for_thread(threads.last)
      release << true
      values = join_threads(threads)
      expect(values.first).to equal(values.last)
      expect(calls.size).to eq(2)
      expect([calls.pop, calls.pop]).to match_array([[kind, :broken], [kind, :healthy]])
      expect(captured.size).to eq(1)
      expect(Timeout.timeout(5) { reentries.pop }).to equal(values.first)
      expect(captured.pop[:details]).to eq(conditions: "{broken", entityType: kind.to_s, entityKey: "broken")
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
      threads&.each(&:join)
      f&.close
    end
  end

  it "does not insert into a hash while refresh takes its retained cache snapshot" do
    source = datafile
    source[:features] = { warm: feature, cold: feature }
    captured = Queue.new
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { captured << item })
    expect(f.is_enabled("warm")).to be(true)
    entered, release = Queue.new, Queue.new
    gate_hash = Class.new(Hash) do
      attr_accessor :entered, :release

      def each
        return enum_for(:each) unless block_given?
        super do |key, value|
          if Thread.current[:retaining] && entered
            self.entered << true
            self.entered = nil
            release.pop
          end
          yield key, value
        end
      end

      def dup
        each_with_object({}) { |(key, value), copy| copy[key] = value }
      end
    end.new
    provider = f.instance_variable_get(:@datafile)
    gate_hash.update(provider.normalized[:feature])
    gate_hash.entered, gate_hash.release = entered, release
    provider.normalized[:feature] = gate_hash
    threads = [Thread.new { Thread.current[:retaining] = true; f.set_datafile(datafile("refresh")) }]
    Timeout.timeout(5) { entered.pop }
    attempted = Queue.new
    threads << Thread.new { attempted << true; f.is_enabled("cold") }
    Timeout.timeout(5) { attempted.pop }
    wait_for_thread(threads.last)
    release << true
    expect(join_threads(threads)).to eq([true, true])
    expect(f.get_revision).to eq("refresh")
    expect(f.evaluate_flag("cold")).to include(enabled: true, reason: "rule")
    expect(captured.size).to eq(0)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
    f&.close
  end

  it "shares unread slots across retained generations and resets only replaced entities" do
    source = datafile
    source[:features][:broken] = feature.merge(force: [{ conditions: "{broken", enabled: false }])
    captured = Queue.new
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { captured << item })
    old = f.instance_variable_get(:@datafile)
    expect(f.set_datafile(datafile("retained"))).to be(true)
    current = f.instance_variable_get(:@datafile)
    expect(old.normalized.values).to all(be_empty)
    expect(current.normalized.values).to all(be_empty)
    threads = [old, current].map { |provider| Thread.new { provider.get_feature("broken") } }
    values = join_threads(threads)
    expect(values.first).to equal(values.last)
    expect(captured.size).to eq(1)
    10.times { |index| expect(f.set_datafile(datafile("unrelated#{index}"))).to be(true) }
    expect(f.is_enabled("broken")).to be(true)
    expect(captured.size).to eq(1)
    expect(f.set_datafile(source)).to be(true)
    expect(f.is_enabled("broken")).to be(true)
    expect(captured.size).to eq(2)
    expect(f.set_datafile(source, true)).to be(true)
    expect(f.is_enabled("broken")).to be(true)
    expect(captured.size).to eq(3)
  ensure
    f&.close
  end

  it "allows diagnostic setters and module changes outside the lock to invalidate completed source memos" do
    source = datafile
    source[:features][:broken] = feature.merge(force: [{ conditions: "{broken", enabled: false }])
    source[:features][:healthy] = feature
    source[:variables][:source] = { type: "string", defaultValue: "before" }
    source[:variables][:view] = { type: "object", compose: [
      { key: "first", variable: "source" }, { key: "flag", feature: "broken" }, { key: "last", variable: "source" }
    ] }
    captured = []
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) {
      next unless item[:code] == "conditions_parse_error"
      captured << item
      worker = Thread.new do
        patch = datafile("callback")
        patch[:variables][:source] = { type: "string", defaultValue: "after" }
        raise "callback refresh rejected" unless f.set_datafile(patch)
        f.set_context(callback: true)
        f.add_module(name: "diagnostic-installed", after_evaluation: ->(result, options) {
          options[:variable_key] == "source" ? result.merge(variable_value: "#{result[:variable_value]}-hook") : result
        })
        raise "callback reentry failed" unless f.is_enabled("healthy")
      end
      join_threads([worker])
    })
    expect(f.get_variable("view")).to eq(first: "before", flag: true, last: "after-hook")
    expect(f.get_revision).to eq("callback")
    expect(captured.length).to eq(1)
  ensure
    f&.close
  end

  it "accepts every valid refresh without false flags, null variables or error evaluations" do
    source = datafile
    count, rounds, workers = 32, 30, 4
    count.times do |index|
      source[:segments]["s#{index}".to_sym] = { conditions: '{"attribute":"country","operator":"equals","value":"nl"}' }
      source[:features]["f#{index}".to_sym] = feature.merge(conditions: "s#{index}")
      source[:variables]["v#{index}".to_sym] = { type: "string", conditions: "s#{index}", defaultValue: "present" }
    end
    captured = Queue.new
    f = Featurevisor.create_featurevisor(datafile: source, log_level: "error", on_diagnostic: ->(item) { captured << item })
    starts, finishes = Array.new(workers) { Queue.new }, Queue.new
    threads = workers.times.map do |worker|
      Thread.new do
        rounds.times do
          starts[worker].pop
          count.times do |offset|
            index = (offset + worker) % count
            raise "silent false flag" unless f.is_enabled("f#{index}", country: "nl") == true
            raise "silent variable fallback" unless f.get_variable("v#{index}", country: "nl") == "present"
            raise "flag error" if f.evaluate_flag("f#{index}", country: "nl")[:reason] == "error"
            raise "variable error" if f.evaluate_variable("v#{index}", country: "nl")[:reason] == "error"
            Thread.pass
          end
          finishes << true
        end
      end
    end
    Timeout.timeout(30) do
      rounds.times do |round|
        # Replacement makes every round cold, followed by partial refreshes while readers run.
        expect(f.set_datafile(source, true)).to be(true)
        starts.each { |queue| queue << true }
        4.times do |refresh|
          expect(f.set_datafile(datafile("r#{round}.#{refresh}"))).to be(true)
          Thread.pass
        end
        workers.times { finishes.pop }
      end
      expect(join_threads(threads)).to eq(Array.new(workers, rounds))
    end
    expect(captured.size).to eq(0)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
    f&.close
  end
end
