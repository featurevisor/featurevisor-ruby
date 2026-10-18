# frozen_string_literal: true

require "featurevisor"
require_relative "../bin/cli"

RSpec.describe "SDK backed CLI segment gates" do
  def feature
    { bucketBy: "userId", traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] }
  end

  def datafile
    { schemaVersion: "4", revision: "segment-tests", segments: {}, features: { flag: feature }, variables: {} }
  end

  def command(coverage: false)
    options = FeaturevisorCLI::Options.new
    options.coverage = coverage
    FeaturevisorCLI::Commands::Test.new(options)
  end

  def reference!(segments, source = datafile)
    FeaturevisorCLI::SegmentTests.references!("subject", source, segments)
  end

  it "does not prepare or reinstall datafiles when no segment gates are needed" do
    source = datafile
    source[:variables][:policy] = { type: "string", defaultValue: "value" }
    expect(FeaturevisorCLI::SegmentTests.prepare(source, {})).to equal(source)
    runner = command
    checks = [{ variable: "policy", operator: "equals", value: "value" }]
    f, diagnostics = runner.send(:create_tester_instance, source, "error", {})
    expect(f.instance_variable_get(:@__segment_test_keys)).to eq({})
    expect(f).not_to receive(:set_datafile)
    expect(runner.send(:run_test_variable, { expectedValue: "value", checks: checks }, "policy", f, source, diagnostics)[:has_error]).to be(false)
    expect(runner.send(:run_test_scenario, { checks: checks }, f, source, diagnostics)[:has_error]).to be(false)
  ensure
    f&.close
  end

  it "does not reinstall an ordinary SDK instance merely to create an empty matcher" do
    f = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
    expect(f).not_to receive(:set_datafile)
    expect(command.send(:segment_matcher, f, {})).to respond_to(:call)
  ensure
    f&.close
  end

  it "preserves selected Target definitions for owners and checks while restoring missing transitive segments" do
    source = datafile
    source[:segments][:subject] = { conditions: "restored" }
    segments = { subject: { conditions: { feature: "flag", enabled: false } }, restored: { conditions: "*" } }
    runner = command
    result = runner.send(:run_test_segment, { expectedToMatch: true }, segments[:subject], "error", source, segments)
    expect(result[:has_error]).to be(false)
    prepared = FeaturevisorCLI::SegmentTests.prepare(source, segments)
    f, diagnostics = runner.send(:create_tester_instance, prepared, "error", {})
    result = FeaturevisorCLI::TestChecks.evaluate_result(f, prepared, [{ segment: "subject", matches: true }],
      owner_variable: nil, diagnostics: diagnostics, segments: segments, segment_matcher: runner.send(:segment_matcher, f))
    expect(result).to include(passed: true, error: false)
    expect(source[:segments]).to eq(subject: { conditions: "restored" })
    expect(source[:features].keys).to eq([:flag])
  ensure
    f&.close
  end

  it "preflights preferred protocol definitions even when selected segments are specialized" do
    source = datafile
    source[:segments][:subject] = { conditions: "*" }
    expect { reference!({ subject: { conditions: { feature: "missing" } } }, source) }
      .to raise_error(FeaturevisorCLI::TestChecks::CheckError, /feature.*missing/)
  end

  %i[root force traffic rule_override variation_override].each do |site|
    it "preflights the reached feature #{site} closure without reading getters" do
      source = datafile
      source[:features][:flag][:variablesSchema] = { title: { type: "string", defaultValue: "ok" } }
      target = source[:features][:flag]
      case site
      when :root then target[:conditions] = { feature: "missing" }
      when :force then target[:force] = [{ conditions: { feature: "missing" }, enabled: true }]
      when :traffic then target[:traffic][0][:conditions] = { feature: "missing" }
      when :rule_override then target[:traffic][0][:variableOverrides] = { title: [{ conditions: { feature: "missing" }, value: "wrong" }] }
      when :variation_override then target[:variations] = [{ value: "on", variableOverrides: { title: [{ conditions: { feature: "missing" }, value: "wrong" }] } }]
      end
      segments = { subject: { conditions: { feature: "flag", variable: "title", operator: "notNull" } } }
      expect(Featurevisor).not_to receive(:create_featurevisor)
      expect { reference!(segments, source) }.to raise_error(FeaturevisorCLI::TestChecks::CheckError, /feature.*missing/)
    end
  end

  %i[root override program alias map].each do |site|
    it "preflights the reached global #{site} closure without reading getters" do
      source = datafile
      source[:variables][:policy] = { type: "object", defaultValue: {} }
      target = source[:variables][:policy]
      case site
      when :root then target[:conditions] = { variable: "missing", operator: "isNull" }
      when :override then target[:overrides] = [{ conditions: { variable: "missing", operator: "isNull" }, value: {} }]
      when :program then target[:overrideProgram] = [{ conditions: { variable: "missing", operator: "isNull" }, operations: [] }]
      when :alias then target[:compose] = "missing"
      when :map then target[:compose] = [{ key: "property", variable: "missing" }]
      end
      expect(Featurevisor).not_to receive(:create_featurevisor)
      expect { reference!({ subject: { conditions: { variable: "policy", operator: "notNull" } } }, source) }
        .to raise_error(FeaturevisorCLI::TestChecks::CheckError, /variable.*missing/)
    end
  end

  it "visits each feature variable identity and terminates cyclic closure traversal" do
    source = datafile
    source[:features][:flag][:variablesSchema] = { first: { type: "string" }, second: { type: "string" } }
    source[:features][:flag][:traffic][0][:variableOverrides] = { second: [{ conditions: "missing", value: "wrong" }] }
    segments = { subject: { conditions: ["subject", { feature: "flag", variable: "first", operator: "isNull" },
                                        { feature: "flag", variable: "second", operator: "isNull" }] } }
    expect { reference!(segments, source) }.to raise_error(FeaturevisorCLI::TestChecks::CheckError, /segment.*missing/)
    source[:features][:flag][:traffic][0].delete(:variableOverrides)
    expect { reference!(segments, source) }.not_to raise_error
  end

  it "uses fixed bucketing and sticky values through ordinary SDK getters" do
    source = datafile
    source[:features][:flag][:traffic][0][:percentage] = 50_000
    segments = { subject: { conditions: { feature: "flag" } } }
    runner = command
    [[25, {}, true], [75, {}, false], [75, { flag: { enabled: true } }, true]].each do |at, sticky, expected|
      result = runner.send(:run_test_segment, { at: at, stickyFeatures: sticky, expectedToMatch: expected }, segments[:subject], "error", source, segments)
      expect(result[:has_error]).to be(false)
    end
  end

  it "binds child checks to child context and sticky state and excludes only actual helpers from coverage" do
    source = datafile
    collision = :__featurevisor_segment_test__subject
    source[:features][collision] = feature
    segments = { subject: { conditions: [{ feature: collision.to_s }, { variable: "policy", operator: "equals", value: "child" }] } }
    source[:variables][:policy] = { type: "string", defaultValue: "parent" }
    prepared = FeaturevisorCLI::SegmentTests.prepare(source, segments)
    expect(prepared[:_segment_test_keys]["subject"]).to eq("#{collision}_")
    assertion = { checks: [{ segment: "subject", matches: false }], children: [
      { context: { country: "nl" }, stickyVariables: { policy: "child" }, checks: [{ segment: "subject", matches: true }] },
      { stickyVariables: { policy: "child" }, stickyFeatures: { collision => { enabled: false } }, checks: [{ segment: "subject", matches: false }] }
    ] }
    runner = command(coverage: true)
    f, diagnostics = runner.send(:create_tester_instance, prepared, "error", assertion)
    expect(runner.send(:run_test_scenario, assertion, f, prepared, diagnostics, segments)[:has_error]).to be(false)
    selections = runner.send(:coverage_report)[:selections]
    expect(selections.map { |item| item[:featureKey] }).to include(collision.to_s)
    expect(selections.map { |item| item[:featureKey] }).not_to include("#{collision}_")
  ensure
    f&.close
  end

  it "allows unscoped attribute chains but rejects absent dependencies and malformed selectors" do
    runner = command
    segments = { subject: { conditions: "attributes" }, attributes: { conditions: { attribute: "country", operator: "equals", value: "nl" } } }
    expect(runner.send(:run_test_segment, { context: { country: "nl" }, expectedToMatch: true }, segments[:subject], "error", nil, segments)[:has_error]).to be(false)
    [{ conditions: { feature: "flag" } }, { conditions: "{oops" }, { conditions: { not: ["subject"] } }].each do |segment|
      %w[error fatal].each do |level|
        expect(runner.send(:run_test_segment, { expectedToMatch: false }, segment, level, nil, {})[:has_error]).to be(true)
      end
    end
  end
end
