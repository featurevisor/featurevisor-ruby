# frozen_string_literal: true

require "featurevisor"
require "timeout"
require "weakref"

RSpec.describe "incremental dependency indexing" do
  def datafile(revision = "initial", **values)
    { schemaVersion: "4", revision: revision, segments: {}, features: {}, variables: {} }.merge(values)
  end

  def feature(**values)
    { hash: "stable", bucketBy: "userId", traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }.merge(values)
  end

  [false, true].each do |replace|
    it "reuses identical edges on full #{replace ? 'replacement' : 'merge'} without suppressing hashless events" do
      source = datafile(features: { root: feature(conditions: "gate"), hashless: feature(hash: nil) },
                        segments: { gate: { conditions: "*" } }, variables: {
                          source: { type: "integer", defaultValue: 1, hash: "1" },
                          alias: { type: "integer", compose: "source", hash: "same" }
                        })
      sdk = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      events = []
      sdk.on("datafile_set", ->(event) { events << event })
      dependencies = Featurevisor.const_get(:Dependencies)
      expect(dependencies).to receive(:extract_entity_dependencies).exactly(5).times.and_call_original
      expect(sdk.set_datafile(source, replace)).to be(true)
      expect(events.last[:features]).to eq([:hashless])
      expect(events.last[:variables]).to eq([])
      expect(events.last[:replaced]).to eq(replace)
      expect(sdk.set_datafile(source.merge(revision: "same"), replace)).to be(true)
      expect(events.last[:features]).to eq([:hashless])
      expect(events.last[:variables]).to eq([])
    ensure
      sdk&.close
    end

    it "refreshes same hash edges and removes obsolete owners on full #{replace ? 'replacement' : 'merge'}" do
      source = datafile(features: { root: feature(conditions: "gate") },
                        segments: { gate: { conditions: { variable: "source", operator: "notNull" } } },
                        variables: {
                          source: { type: "integer", defaultValue: 1, hash: "1" },
                          alias: { type: "integer", compose: "source", hash: "same" }
                        })
      sdk = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      events = []
      sdk.on("datafile_set", ->(event) { events << event })
      expect(sdk.set_datafile(source, replace)).to be(true)
      changed = datafile(features: source[:features], segments: { gate: { conditions: "*" } }, variables: {
        source: source[:variables][:source], alias: { type: "integer", compose: "other", hash: "same" }
      })
      expect(sdk.set_datafile(changed, replace)).to be(true)
      expect(events.last[:features]).to eq([:root])
      expect(events.last[:variables]).to eq([])
      expect(sdk.set_datafile(datafile("next", variables: {
        source: { type: "integer", defaultValue: 2, hash: "2" }
      }))).to be(true)
      expect(events.last[:features]).to eq([])
      expect(events.last[:variables]).to eq([:source])
      expect(sdk.set_datafile(datafile("other", variables: {
        other: { type: "integer", defaultValue: 3, hash: "3" }
      }))).to be(true)
      expect(events.last[:variables]).to eq(%i[other alias])
      expect(sdk.set_datafile(datafile("removed"), true)).to be(true)
      expect(events.last[:features]).to eq([:root])
      expect(events.last[:variables]).to eq(%i[source alias other])
    ensure
      sdk&.close
    end
  end

  it "does not traverse unrelated retained entities on cached updates" do
    sdk = nil
    [16, 512].each do |size|
      sdk = Featurevisor.create_featurevisor(log_level: "fatal", datafile: datafile(
        segments: size.times.to_h { |i| ["s#{i}".to_sym, { conditions: '{"attribute":"country","operator":"notNull"}' }] },
        features: size.times.to_h { |i| ["f#{i}".to_sym, feature(conditions: "s#{i}")] },
        variables: { source: { type: "integer", defaultValue: 1, hash: "1" } }
      ))
      expect(sdk.set_datafile(datafile("warm"))).to be(true)
      index = sdk.instance_variable_get(:@datafile).dependency_index
      expect(index).to receive(:dependents).exactly(2).times.and_call_original
      extractions = 0
      allow(Featurevisor.const_get(:Dependencies)).to receive(:extract_entity_dependencies).and_wrap_original do |original, *args|
        extractions += 1
        original.call(*args)
      end
      expect(sdk.set_datafile(datafile("next", variables: { source: { type: "integer", defaultValue: 2, hash: "2" } }))).to be(true)
      expect(extractions).to eq(1)
      sdk.close
    end
  ensure
    sdk&.close
  end

  it "extracts and parses only incoming entities after the first update at increasing corpus sizes" do
    sdk = nil
    [8, 128, 1024].each do |size|
      condition = JSON.generate(variable: "source", operator: "notNull")
      source = datafile(
        segments: size.times.to_h { |i| ["s#{i}".to_sym, { conditions: condition }] },
        features: size.times.to_h { |i| ["f#{i}".to_sym, feature(conditions: "s#{i}")] },
        variables: { source: { type: "integer", defaultValue: 1, hash: "1" } }.merge(
          size.times.to_h { |i| ["v#{i}".to_sym, { type: "integer", compose: "source", hash: "stable" }] })
      )
      extractions = 0
      parses = 0
      allow(Featurevisor.const_get(:Dependencies)).to receive(:extract_entity_dependencies).and_wrap_original do |original, *args|
        extractions += 1
        original.call(*args)
      end
      allow(JSON).to receive(:parse).and_wrap_original do |original, *args, **kwargs|
        parses += 1 if args.first == condition
        original.call(*args, **kwargs)
      end
      sdk = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
      expect(extractions).to eq(0)
      expect(parses).to eq(0)
      events = []
      sdk.on("datafile_set", ->(event) { events << event })
      expect(sdk.set_datafile(datafile("cold", variables: { source: { type: "integer", defaultValue: 2, hash: "2" } }))).to be(true)
      expect(extractions).to eq(size * 3 + 2)
      expect(parses).to eq(size)
      index = sdk.instance_variable_get(:@datafile).dependency_index
      extractions = parses = 0
      3.times do |revision|
        expect(sdk.set_datafile(datafile(revision.to_s, variables: { source: {
          type: "integer", defaultValue: revision, hash: revision.to_s, conditions: condition
        } }))).to be(true)
        expect(sdk.instance_variable_get(:@datafile).dependency_index).to equal(index)
        expect(events.last[:features]).to eq(size.times.map { |i| "f#{i}".to_sym })
        expect(events.last[:variables]).to eq([:source] + size.times.map { |i| "v#{i}".to_sym })
      end
      expect(extractions).to eq(3)
      expect(parses).to eq(3)
      sdk.close
    end
  ensure
    sdk&.close
  end

  it "does not compare unchanged segment contents" do
    retained = Class.new(Hash) do
      def ==(other)
        raise "retained segment compared"
      end
    end.new
    retained[:conditions] = "*"
    sdk = Featurevisor.create_featurevisor(datafile: datafile(segments: { retained: retained }), log_level: "fatal")
    sdk.instance_variable_get(:@datafile).segments[:retained] = retained
    expect(sdk.set_datafile(datafile("next"))).to be(true)
  ensure
    sdk&.close
  end

  it "does not walk a new edge followed by an old edge" do
    sdk = Featurevisor.create_featurevisor(datafile: datafile(variables: {
      source: { type: "integer", defaultValue: 1, hash: "1" },
      bridge: { type: "integer", defaultValue: 0, hash: "same" },
      unreachable: { type: "integer", compose: "bridge", hash: "same" }
    }), log_level: "fatal")
    events = []
    sdk.on("datafile_set", ->(event) { events << event })
    expect(sdk.set_datafile(datafile("next", variables: {
      source: { type: "integer", defaultValue: 2, hash: "2" },
      bridge: { type: "integer", compose: "source", hash: "same" },
      unreachable: { type: "integer", defaultValue: 0, hash: "same" }
    }))).to be(true)
    expect(events.last[:variables]).to eq(%i[source bridge])
  ensure
    sdk&.close
  end

  it "propagates chains, aliases, compositions and feature variable overrides and removes obsolete edges" do
    source = datafile(segments: {
      leaf: { conditions: { variable: "source", operator: "notNull" } }, chain: { conditions: "leaf" }
    }, features: {
      root: feature(conditions: "chain"), override: feature(traffic: [{
        key: "all", conditions: "*", percentage: 100_000,
        variableOverrides: { message: [{ conditions: { variable: "alias", operator: "notNull" }, value: "yes" }] }
      }])
    }, variables: {
      source: { type: "integer", defaultValue: 1, hash: "1" },
      alias: { type: "integer", compose: "source", hash: "same" },
      view: { type: "object", compose: [{ key: "flag", feature: "root" }], hash: "same" }
    })
    sdk = Featurevisor.create_featurevisor(datafile: source, log_level: "fatal")
    events = []
    sdk.on("datafile_set", ->(event) { events << event })
    %w[2 3].each do |revision|
      expect(sdk.set_datafile(datafile(revision, variables: { source: { type: "integer", defaultValue: 2, hash: revision } }))).to be(true)
      expect(events.last[:features]).to match_array(%i[root override])
      expect(events.last[:variables]).to match_array(%i[source alias view])
    end
    expect(sdk.set_datafile(datafile("segments", segments: { chain: { conditions: "*" } }))).to be(true)
    expect(events.last[:features]).to eq([:root])
    expect(events.last[:variables]).to eq([:view])
    expect(sdk.set_datafile(datafile("removed"), true)).to be(true)
    index = sdk.instance_variable_get(:@datafile).dependency_index
    expect(index.instance_variable_get(:@owners)).to be_empty
    expect(index.instance_variable_get(:@reverse)).to be_empty
    expect(sdk.set_datafile(datafile("fresh", variables: { source: { type: "integer", defaultValue: 3, hash: "3" } }))).to be(true)
    expect(events.last[:features]).to be_empty
    expect(events.last[:variables]).to eq([:source])
  ensure
    sdk&.close
  end

  it "serializes concurrent writers without dropping accepted partial updates" do
    sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    entered, release = Queue.new, Queue.new
    allow(sdk).to receive(:merge_datafiles).and_wrap_original do |original, previous, incoming|
      if incoming[:revision] == "first"
        entered << true
        release.pop
      end
      original.call(previous, incoming)
    end
    threads = [Thread.new { sdk.set_datafile(datafile("first", variables: { one: { type: "integer", defaultValue: 1, hash: "1" } })) }]
    Timeout.timeout(5) { entered.pop }
    threads << Thread.new { sdk.set_datafile(datafile("second", variables: { two: { type: "integer", compose: "one", hash: "2" } })) }
    Thread.pass
    release << true
    expect(Timeout.timeout(5) { threads.map(&:value) }).to eq([true, true])
    expect(sdk.get_variable("two")).to eq(1)
    expect(sdk.get_variable_keys).to match_array(%i[one two])
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
    sdk&.close
  end

  it "runs callbacks outside the writer mutex and releases old providers and the closed index" do
    sdk = Featurevisor.create_featurevisor(datafile: datafile(variables: { source: { type: "integer", defaultValue: 1, hash: "1" } }), log_level: "fatal")
    old = WeakRef.new(sdk.instance_variable_get(:@datafile))
    sdk.on("datafile_set", ->(event) {
      if event[:revision] == "first"
        worker = Thread.new { sdk.set_datafile(datafile("callback")) }
        raise "callback refresh rejected" unless Timeout.timeout(5) { worker.value }
      end
    })
    expect(sdk.set_datafile(datafile("first"))).to be(true)
    expect(sdk.get_revision).to eq("callback")
    GC.start(full_mark: true, immediate_sweep: true)
    expect(old.weakref_alive?).to be_falsey
    sdk.close
    expect(sdk.instance_variable_get(:@datafile).dependency_index).to be_nil
  ensure
    sdk&.close
  end
end
