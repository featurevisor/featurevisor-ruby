require "featurevisor"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "bin"))
require "cli"

RSpec.describe FeaturevisorCLI::Commands::Test do
  let(:options) do
    opts = FeaturevisorCLI::Options.new
    opts.project_directory_path = "/tmp/featurevisor-project"
    opts
  end

  describe "datafile routing helpers" do
    it "keeps every built base and target separate for delimiter and Unicode names" do
      command = described_class.new(options)
      environments = [false, "false", "prod", "prod-target-web", "prod-target-a", "café\"\\\n東京"]
      targets = ["web", "a-target-b", "b", "web\"\\\n東京"]
      allow(command).to receive(:build_single_datafile) do |environment:, target: nil, **_options|
        { route: [environment == false ? nil : environment, target] }
      end
      cache = command.send(:build_datafiles, environments, targets, nil)
      expect(cache.length).to eq(environments.length * (targets.length + 1))
      environments.each do |environment|
        [nil, *targets].each do |target|
          assertion = { environment: environment, target: target }
          expected = [environment == false ? nil : environment, target]
          expect(command.send(:resolve_datafile_for_assertion, assertion, cache)[:route]).to eq(expected)
        end
      end
      expect(command.send(:base_datafile_key, nil)).to eq([nil, nil])
      expect(command.send(:target_datafile_key, nil, "web")).to eq([nil, "web"])
      expect(command.send(:resolve_datafile_for_assertion, {}, cache)[:route]).to eq([nil, nil])
      expect(command.send(:resolve_datafile_for_assertion, { environment: nil, target: "web" }, cache)[:route]).to eq([nil, "web"])
      expect(command.send(:resolve_datafile_for_assertion, { environment: "prod", target: "missing" }, cache)).to be_nil
    end

    it "prefers target datafile over base datafile" do
      command = described_class.new(options)

      datafiles_by_key = {
        ["production", nil] => { schemaVersion: "2" },
        ["production", "checkout"] => { schemaVersion: "2", target: "checkout" }
      }

      assertion = {
        environment: "production",
        target: "checkout"
      }

      datafile = command.send(:resolve_datafile_for_assertion, assertion, datafiles_by_key)
      expect(datafile[:target]).to eq("checkout")
    end

    it "does not fall back when a target datafile is missing" do
      command = described_class.new(options)
      datafiles_by_key = { ["production", nil] => { schemaVersion: "2" } }
      assertion = { environment: "production", target: "checkout" }

      expect(command.send(:resolve_datafile_for_assertion, assertion, datafiles_by_key)).to be_nil
    end
  end

  describe "Node CLI resolution" do
    it "runs the nearest local CLI entry with node, then falls back to npx" do
      Dir.mktmpdir do |directory|
        root = File.realpath(directory)
        project = File.join(root, "packages", "flags")
        FileUtils.mkdir_p(project)
        expect(FeaturevisorCLI::NodeCli.command(project)).to eq(["npx", "featurevisor"])
        entry = File.join(root, "node_modules", "@featurevisor", "cli", "bin.js")
        FileUtils.mkdir_p(File.dirname(entry))
        File.write(entry, "")
        expect(FeaturevisorCLI::NodeCli.command(project)).to eq(["node", entry])
      end
    end

    it "passes values with quotes and spaces without shell quoting" do
      command = described_class.new(options)
      command.instance_variable_set(:@active_set, "web team's set")
      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.last(3) == ["--json", "--target=it's checkout", "--set=web team's set"] })
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')
      command.send(:build_single_datafile, environment: false, inflate: nil, target: "it's checkout")
    end
  end

  describe "build command generation" do
    it "includes target and environment flags when building target datafiles" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.last(4) == ["build", "--json", "--environment=production", "--target=checkout"] })
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: "production",
        inflate: nil,
        target: "checkout"
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end

    it "does not include environment flag when environment is false" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.include?("build") && cmd.none? { |part| part.start_with?("--environment=") } })
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: false,
        inflate: nil
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end
  end

  describe "test execution protocol" do
    it "requires the versioned execution envelope" do
      command = described_class.new(options)
      valid = {
        kind: "featurevisor.test-execution",
        schemaVersion: 1,
        tests: [{ scenario: "ready", assertions: [] }]
      }
      malformed = [
        [], {}, valid.merge(kind: "other"), valid.merge(schemaVersion: true),
        valid.merge(schemaVersion: "1"), valid.merge(schemaVersion: 2),
        valid.merge(tests: nil), valid.merge(tests: [nil])
      ]
      malformed.each do |payload|
        allow(command).to receive(:execute_command).and_return(JSON.generate(payload))
        expect { command.send(:get_tests, nil) }
          .to raise_error(FeaturevisorCLI::Commands::Test::InfrastructureError)
      end

      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.last(5) == ["list", "--tests", "--execution-protocol", "--json", "--keyPattern=ready"] })
        .and_return(JSON.generate(valid))
      options.key_pattern = "ready"
      expect(command.send(:get_tests, nil)).to eq(valid[:tests])
    end
  end

  describe "test execution behavior" do
    it "executes every shared check fixture case with a fresh native instance" do
      fixture = JSON.parse(File.read(File.expand_path("../conformance/test-checks.json", __dir__), encoding: "UTF-8"), symbolize_names: true)
      expect(fixture[:version]).to eq(3)
      expect(fixture[:cases].length).to eq(255)
      expect(fixture[:datafile]).to be_a(Hash)

      executed_any = 0
      fixture[:cases].each do |item|
        expect(item[:name]).to be_a(String)
        expect(item).to include(:checks, :passed)
        diagnostics = []
        instance = Featurevisor.create_featurevisor(
          datafile: fixture[:datafile], log_level: "fatal",
          on_diagnostic: ->(diagnostic) { diagnostics << diagnostic }
        )
        begin
          result = FeaturevisorCLI::TestChecks.evaluate_result(
            instance, fixture[:datafile], item[:checks],
            owner_variable: item[:owner], diagnostics: diagnostics
          )
        ensure
          instance.close
        end
        preflight_error = [
          "or skips unreached missing feature", "and skips unreached missing feature",
          "short circuit skips unresolved ref", "AND short circuit"
        ].include?(item[:name])
        expect(result[:passed]).to eq(preflight_error ? false : item[:passed]), "#{item[:name]}: #{result[:failures].join("; ")}"
        expect(result[:error]).to eq(preflight_error ? true : item.fetch(:error, false)), "#{item[:name]}: #{result[:failures].join("; ")}"
        executed_any += 1 if JSON.generate(item[:checks]).match?(/includesAny|notIncludesAny/)
      end
      expect(executed_any).to eq(36)
    end

    it "turns malformed JSON getter diagnostics into errors at quiet log levels" do
      datafile = {
        schemaVersion: "2", revision: "bad-json", segments: {}, features: {},
        variables: { broken: { type: "json", defaultValue: "[" } }
      }
      diagnostics = []
      instance = Featurevisor.create_featurevisor(
        datafile: datafile, log_level: "error",
        on_diagnostic: ->(diagnostic) { diagnostics << diagnostic }
      )
      result = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile, [{ variable: "broken", operator: "isNull" }],
        owner_variable: nil, diagnostics: diagnostics
      )
      expect(result[:passed]).to be(false)
      expect(result[:error]).to be(true)
      expect(result[:failures].first).to include("variable getter reported")
    ensure
      instance&.close
    end

    it "treats feature getter exceptions and diagnostics as check errors" do
      datafile = { features: { experiment: {} } }
      calls = []
      evaluator = double("feature evaluator")
      allow(evaluator).to receive(:is_enabled) do |feature, _context|
        calls << "enabled:#{feature}"
        false
      end
      allow(evaluator).to receive(:get_variation) do |feature, _context|
        calls << "variation:#{feature}"
        raise "variation exploded"
      end

      result = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator, datafile, [{ feature: "experiment", enabled: true, variation: "treatment" }],
        owner_variable: nil, diagnostics: []
      )
      expect(result[:error]).to be(true)
      expect(calls).to eq(%w[enabled:experiment variation:experiment])
      expect(result[:failures].first).to include("variation getter failed")
      expect(result[:failures].first).to include('feature "experiment"')

      diagnostics = []
      diagnostic_evaluator = double("diagnostic feature evaluator")
      allow(diagnostic_evaluator).to receive(:is_enabled) do
        diagnostics << { level: "error", code: "evaluation_error", message: "flag failed" }
        false
      end
      result = FeaturevisorCLI::TestChecks.evaluate_result(
        diagnostic_evaluator, datafile, [{ feature: "experiment", enabled: false }],
        owner_variable: nil, diagnostics: diagnostics
      )
      expect(result[:error]).to be(true)
      expect(result[:failures].first).to include("enabled getter reported evaluation_error")
      expect(result[:failures].first).to include('feature "experiment"')

      mismatching = double("mismatching feature evaluator", is_enabled: false, get_variation: "treatment")
      result = FeaturevisorCLI::TestChecks.evaluate_result(
        mismatching, datafile, [{ feature: "experiment", enabled: true, variation: "control" }],
        owner_variable: nil, diagnostics: []
      )
      expect(result[:passed]).to be(false)
      expect(result[:error]).to be(false)
      expect(result[:failures].first).to include('feature "experiment"')
      expect(result[:failures].first).to include("expected enabled=true, actual enabled=false")
      expect(result[:failures].first).to include('expected variation="control", actual variation="treatment"')
    end

    it "validates the complete check syntax before running getters" do
      evaluator = double("tracking evaluator")
      expect(evaluator).not_to receive(:is_enabled)

      result = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator,
        { features: { checkout: {} } },
        [
          { feature: "checkout", enabled: true },
          { feature: "checkout", enabled: "true" }
        ],
        owner_variable: nil,
        diagnostics: []
      )
      expect(result[:error]).to be(true)
    end

    it "evaluates segment checks from authored definitions with nested and merged contexts" do
      datafile = { schemaVersion: "2", revision: "target", segments: {}, features: {}, variables: {} }
      segments = {
        adult: { conditions: [{ attribute: "age", operator: "greaterThanOrEquals", value: 18 }] },
        netherlands: { conditions: { attribute: "country", operator: "equals", value: "nl" } },
        not_netherlands: { conditions: { not: [{ attribute: "country", operator: "equals", value: "nl" }] } },
        everyone: { conditions: "*" }
      }
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      matcher = described_class.new(options).send(:segment_matcher, instance, segments)
      checks = [{ and: [
        { segment: "adult", matches: true },
        { or: [{ segment: "netherlands", matches: true }, { segment: "everyone", matches: false }] },
        { not: [{ segment: "not_netherlands", matches: true }] }
      ] }]
      result = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile, checks, owner_variable: "unused", diagnostics: [],
        segments: segments, context: { country: "nl", age: 20 }, segment_matcher: matcher
      )
      expect(result[:passed]).to be(true), result[:failures].join("; ")

      child = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile, [{ segment: "adult", matches: false }],
        owner_variable: nil, diagnostics: [], segments: segments,
        context: { country: "nl", age: 20 }.merge(age: 17), segment_matcher: matcher
      )
      expect(child[:passed]).to be(true), child[:failures].join("; ")
    ensure
      instance&.close
    end

    it "rejects malformed segment checks in skipped groups and missing definitions" do
      datafile = { schemaVersion: "2", revision: "target", segments: {}, features: {}, variables: {} }
      segments = { everyone: { conditions: "*" } }
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      matcher = described_class.new(options).send(:segment_matcher, instance, segments)
      [
        { matches: true },
        { segment: "", matches: true },
        { segment: "everyone" },
        { segment: "everyone", matches: "true" },
        { segment: "everyone", matches: true, operator: "equals" }
      ].each do |leaf|
        result = FeaturevisorCLI::TestChecks.evaluate_result(
          instance, datafile, [leaf], owner_variable: nil, diagnostics: [],
          segments: segments, context: {}, segment_matcher: matcher
        )
        expect(result[:error]).to be(true)
        expect(result[:failures].first).to include("segment")
      end

      skipped = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile,
        [{ or: [{ segment: "everyone", matches: true }, { segment: "everyone", matches: "yes" }] }],
        owner_variable: nil, diagnostics: [], segments: segments, context: {}, segment_matcher: matcher
      )
      expect(skipped[:error]).to be(true)

      missing = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile, [{ segment: "missing", matches: false }],
        owner_variable: nil, diagnostics: [], segments: segments, context: {}, segment_matcher: matcher
      )
      expect(missing[:error]).to be(true)
      expect(missing[:failures].first).to include('segment "missing"')
    ensure
      instance&.close
    end

    it "records typed evidence for a failed segment check" do
      datafile = { schemaVersion: "2", revision: "target", segments: {}, features: {}, variables: {} }
      segments = { adult: { conditions: { attribute: "age", operator: "greaterThanOrEquals", value: 18 } } }
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      matcher = described_class.new(options).send(:segment_matcher, instance, segments)
      result = FeaturevisorCLI::TestChecks.evaluate_result(
        instance, datafile, [{ key: "adult-check", segment: "adult", matches: false }],
        owner_variable: nil, diagnostics: [],
        segments: { adult: { conditions: { attribute: "age", operator: "greaterThanOrEquals", value: 18 } } },
        context: { age: 20 }, segment_matcher: matcher
      )
      expect(result[:passed]).to be(false)
      expect(result[:failures].first).to include('segment "adult"')
      expect(result.dig(:errors, 0, :details, :evaluated, 0)).to eq(
        path: [0], key: "adult-check", reference: { segment: "adult" }, property: "matches",
        operator: "equals", expected: false, actual: true
      )
    ensure
      instance&.close
    end

    it "passes root, child and global variable contexts to segment checks" do
      command = described_class.new(options)
      datafile = {
        schemaVersion: "2", revision: "runner", segments: {}, features: {},
        variables: { message: { type: "string", defaultValue: "ready" } }
      }
      segments = {
        netherlands: { conditions: { attribute: "country", operator: "equals", value: "nl" } },
        young_dutch: { conditions: [
          { attribute: "country", operator: "equals", value: "nl" },
          { attribute: "age", operator: "lessThan", value: 18 }
        ] }
      }
      diagnostics = []
      scenario = {
        context: { country: "nl", age: 30 },
        checks: [{ segment: "netherlands", matches: true }],
        children: [{ context: { age: 17 }, checks: [{ segment: "young_dutch", matches: true }] }]
      }
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      scenario_result = command.send(:run_test_scenario, scenario, instance, datafile, diagnostics, segments)
      expect(scenario_result[:has_error]).to be(false), scenario_result[:errors].inspect
      instance.close

      variable_assertion = {
        context: { country: "nl" },
        checks: [{ segment: "netherlands", matches: true }]
      }
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
      variable_result = command.send(
        :run_test_variable, variable_assertion, "message", instance, datafile, diagnostics, segments
      )
      expect(variable_result[:has_error]).to be(false), variable_result[:errors].inspect
    ensure
      instance&.close
    end

    it "validates named check metadata and preserves operand evidence" do
      evaluator = double("named evaluator", get_variable: "actual")
      datafile = { variables: { message: { type: "string", defaultValue: "actual" } } }
      checks = [{ key: "message-ready", description: "Message is ready", variable: "message", operator: "equals", value: "expected" }]

      result = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator, datafile, checks, owner_variable: nil, diagnostics: []
      )
      expect(result[:passed]).to be(false)
      expect(result[:errors].first[:message]).to include('key="message-ready"', 'description="Message is ready"')
      expect(result[:errors].first[:message]).to include('left="actual"', 'right="expected"')
      expect(result[:errors].first).to include(type: "check", expected: true, actual: false)
      expect(result[:errors].first[:details]).to include(
        checkIndex: 0,
        checkKey: "message-ready",
        checkDescription: "Message is ready"
      )
      expect(result.dig(:errors, 0, :details, :evaluated, 0)).to include(
        path: [0],
        reference: { variable: "message" },
        operator: "equals",
        actual: "actual",
        expected: "expected"
      )

      duplicate = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator,
        datafile,
        [
          { key: "same", variable: "message", operator: "exists" },
          { key: "same", variable: "message", operator: "exists" }
        ],
        owner_variable: nil,
        diagnostics: []
      )
      expect(duplicate[:error]).to be(true)
      expect(duplicate[:failures].first).to include('duplicate sibling key "same"')
    end

    it "preflights skipped references, comparison operands and children before getters" do
      calls = 0
      evaluator = double("tracking evaluator")
      allow(evaluator).to receive(:get_variable) { calls += 1; "ready" }
      allow(evaluator).to receive(:is_enabled) { calls += 1; true }
      allow(evaluator).to receive(:get_variation) { calls += 1; "control" }
      datafile = {
        features: { checkout: { variablesSchema: { message: { type: "string" } } } },
        variables: { message: { type: "string", defaultValue: "ready" } }
      }
      invalid = [
        [{ or: [{ variable: "message", operator: "exists" }, { feature: "missing", enabled: true }] }],
        [{ and: [{ feature: "checkout", enabled: true }, { variable: "missing", operator: "exists" }] }],
        [{ not: [{ feature: "checkout", variable: "missing", operator: "exists" }] }],
        [{ variable: "message", operator: "equals", compareTo: { variable: "missing" } }],
        [{ segment: "missing", matches: false }],
        [{ or: [{ variable: "message", operator: "exists" }, { variable: "message", operator: "unknown", value: "x" }] }]
      ]
      invalid.each do |checks|
        result = FeaturevisorCLI::TestChecks.evaluate_result(
          evaluator, datafile, checks, owner_variable: nil, diagnostics: [],
          segments: { known: { conditions: "*" } }
        )
        expect(result[:error]).to be(true), checks.inspect
        expect(calls).to eq(0)
      end

      expect do
        FeaturevisorCLI::TestChecks.preflight!(
          datafile, [{ segment: "known", matches: true }], owner_variable: nil,
          segments: { known: { conditions: { attribute: "never-called" } } }
        )
      end.not_to raise_error

      command = described_class.new(options)
      expect do
        command.send(:preflight_assertion!, { variable: "missing" }, { checks: [{ operator: "isNull" }] }, datafile, {})
      end.to raise_error(FeaturevisorCLI::TestChecks::CheckError)
      expect do
        command.send(
          :preflight_assertion!,
          { scenario: "child" },
          {
            checks: [{ variable: "message", operator: "exists" }],
            children: [{ checks: [{ variable: "missing", operator: "exists" }] }]
          },
          datafile,
          {}
        )
      end.to raise_error(FeaturevisorCLI::TestChecks::CheckError)
      expect(calls).to eq(0)
    end

    it "records comparison references, typed operands and missing values without parsing labels" do
      evaluator = double("evidence evaluator")
      allow(evaluator).to receive(:get_variable) do |variable, _context|
        { "minimum" => 12, "maximum" => 10, "nothing" => nil }.fetch(variable)
      end
      datafile = {
        variables: {
          minimum: { type: "integer", defaultValue: 12 },
          maximum: { type: "integer", defaultValue: 10 },
          nothing: { type: "object", defaultValue: nil }
        }
      }
      checks = [{
        key: "bounds", and: [
          { key: "checks[1]", variable: "minimum", operator: "lessThan", compareTo: { variable: "maximum" } }
        ]
      }]

      result = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator, datafile, checks, owner_variable: nil, diagnostics: [], child_index: 2
      )
      error = result[:errors].first
      expect(error).to include(type: "check", expected: true, actual: false)
      expect(error[:details]).to include(checkIndex: 0, checkKey: "bounds", childIndex: 2)
      expect(error.dig(:details, :evaluated, 0)).to include(
        path: [0, "and", 0], key: "checks[1]",
        reference: { variable: "minimum" }, compareTo: { variable: "maximum" },
        operator: "lessThan", actual: 12, expected: 10
      )

      missing = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator,
        datafile,
        [{ variable: "nothing", path: "absent", operator: "equals", value: nil }],
        owner_variable: nil,
        diagnostics: []
      )
      leaf = missing.dig(:errors, 0, :details, :evaluated, 0)
      expect(leaf[:actual]).to eq("$type" => "undefined")
      expect(leaf[:actualMissing]).to be(true)
      expect(leaf[:expected]).to be_nil
      expect(leaf).not_to have_key(:expectedMissing)

      nullable = FeaturevisorCLI::TestChecks.evaluate_result(
        evaluator,
        datafile,
        [{ variable: "nothing", operator: "isNull" }],
        owner_variable: nil,
        diagnostics: []
      )
      expect(nullable[:passed]).to be(true)
    end

    it "emits a clean versioned JSON report with exact reruns, coverage and uncovered entities" do
      datafile = {
        schemaVersion: "2", revision: "report", segments: {}, features: {},
        variables: {
          message: {
            type: "string", defaultValue: "default",
            overrides: [{ key: "selected", keyPath: "selected", segments: "*", value: "actual" }]
          }
        }
      }
      tests = [{
        key: "tests/scenarios/checkout.spec.yml", scenario: "checkout",
        _test: { source: "tests/scenarios/checkout.spec.yml", set: nil, entityType: "scenario" },
        assertions: [{
          description: "Checkout is ready", environment: "production", target: "checkout", context: {},
          checks: [{ key: "message", variable: "message", operator: "equals", value: "expected" }],
          _case: { id: "opaque case", assertionIndex: 0, matrixIndex: nil, matrixValues: {} }
        }]
      }]

      Dir.mktmpdir do |directory|
        npx = File.join(directory, "npx")
        log = File.join(directory, "calls.log")
        File.write(npx, <<~RUBY)
          #!#{RbConfig.ruby}
          require "json"
          File.open(ENV.fetch("FAKE_NPX_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
          args = ARGV.drop(1)
          value = if args[0, 2] == ["config", "--json"]
                    { environments: ["production"] }
                  elsif args[0, 2] == ["list", "--targets"]
                    ["checkout"]
                  elsif args[0, 2] == ["list", "--segments"]
                    []
                  elsif args[0, 2] == ["list", "--tests"]
                    { kind: "featurevisor.test-execution", schemaVersion: 1, tests: JSON.parse(ENV.fetch("FAKE_TESTS")) }
                  elsif args[0, 2] == ["list", "--features"]
                    [{ key: "untestedFeature" }]
                  elsif args[0, 2] == ["list", "--variables"]
                    [{ key: "untestedVariable" }]
                  elsif args.first == "build"
                    JSON.parse(ENV.fetch("FAKE_DATAFILE"))
                  else
                    abort "unexpected arguments: \#{args.inspect}"
                  end
          puts JSON.generate(value)
        RUBY
        File.chmod(0o755, npx)
        env = {
          "PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
          "FAKE_NPX_LOG" => log,
          "FAKE_DATAFILE" => JSON.generate(datafile),
          "FAKE_TESTS" => JSON.generate(tests)
        }
        stdout, stderr, status = Open3.capture3(
          env, RbConfig.ruby, "bin/featurevisor", "test", "--projectDirectoryPath=#{directory}",
          "--json", "--pretty", "--case=opaque case", "--target=checkout", "--coverage", "--uncovered"
        )
        expect(status.exitstatus).to eq(1), stdout + stderr
        report = JSON.parse(stdout)
        expect(report).to include("schemaVersion" => 1, "runner" => "ruby", "passed" => false)
        expect(report.dig("summary", "scenarioCases")).to eq("passed" => 0, "failed" => 1)
        expect(report.dig("results", 0, "cases", 0, "rerun", "args")).to eq(
          ["test", "--case=opaque case", "--projectDirectoryPath=#{directory}", "--target=checkout"]
        )
        check_error = report.dig("results", 0, "cases", 0, "errors", 0)
        expect(check_error).to include(
          "type" => "check", "message" => "Check did not match",
          "expected" => true, "actual" => false, "path" => ["checks", 0]
        )
        expect(check_error.dig("details", "checkKey")).to eq("message")
        expect(check_error.dig("details", "evaluated", 0)).to include(
          "path" => ["checks", 0],
          "reference" => { "variable" => "message" },
          "operator" => "equals", "actual" => "actual", "expected" => "expected"
        )
        expect(report.dig("coverage", "mode")).to eq("observed-selections")
        expect(report.dig("coverage", "selections", 0)).to include(
          "environment" => "production", "target" => "checkout",
          "variableKey" => "message", "overridePath" => "selected"
        )
        expect(report["uncovered"]).to eq([
          { "set" => nil, "features" => ["untestedFeature"], "variables" => ["untestedVariable"] }
        ])
        expect(stderr).to include("Running tests...")
        expect(File.read(log, encoding: "UTF-8")).to include(
          "list --tests --execution-protocol --json --case=opaque case"
        )
      end
    end

    it "evaluates native checks with paths, references, feature variables and groups" do
      datafile = {
        schemaVersion: "2", revision: "checks", segments: {},
        features: {
          account: {
            bucketBy: "userId",
            variablesSchema: { plan: { type: "string", defaultValue: "pro" } },
            force: [{ segments: "*", enabled: true }], traffic: []
          }
        },
        variables: {
          profile: { type: "object", defaultValue: { name: "Ada", :"a.b" => "literal" } },
          count: { type: "integer", defaultValue: 2 },
          numbers: { type: "array", defaultValue: [1, 2, 3] },
          nothing: { type: "json", defaultValue: nil },
          version: { type: "semver", defaultValue: "2.1.0" }
        }
      }
      diagnostics = []
      instance = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal", on_diagnostic: ->(item) { diagnostics << item })
      checks = [
        { path: "name", operator: "equals", value: "Ada" },
        { path: ["a.b"], operator: "equals", value: "literal" },
        { variable: "numbers", path: "1", operator: "equals", compareTo: { variable: "count" } },
        { variable: "numbers", operator: "includes", value: 3 },
        { variable: "nothing", operator: "isNull" },
        { not: [{ variable: "profile", path: "missing", operator: "notNull" }] },
        { feature: "account", variable: "plan", operator: "equals", value: "pro" },
        { variable: "version", operator: "semverGreaterThan", value: "2.0.0" },
        { or: [
          { variable: "count", operator: "equals", value: 1 },
          { not: [{ variable: "count", operator: "lessThan", value: 2 }] }
        ] }
      ]

      expect(FeaturevisorCLI::TestChecks.evaluate(instance, datafile, checks, owner_variable: "profile", diagnostics: diagnostics)).to eq([])
      type_errors = FeaturevisorCLI::TestChecks.evaluate(
        instance, datafile, [{ variable: "count", operator: "notContains", value: "2" }],
        owner_variable: "profile", diagnostics: diagnostics
      )
      expect(type_errors.first).to include("requires string operands")
      missing_errors = FeaturevisorCLI::TestChecks.evaluate(
        instance, datafile, [{ variable: "missing", operator: "notEquals", value: "anything" }],
        owner_variable: "profile", diagnostics: diagnostics
      )
      expect(missing_errors.first).to include("absent from the selected datafile")
    ensure
      instance&.close
    end

    it "runs scenario children through the executable and preserves failure exits and filtering" do
      datafile = {
        schemaVersion: "2", revision: "runner", segments: {}, features: {},
        variables: {
          message: {
            type: "string", defaultValue: "parent",
            overrides: [{ key: "child", segments: "*", conditions: { attribute: "mode", operator: "equals", value: "child" }, value: "child" }]
          }
        }
      }
      passing = [{
        key: "scenarios/context.spec", scenario: "context",
        assertions: [{
          description: "matrix expanded scenario",
          checks: [{ variable: "message", operator: "equals", value: "parent" }],
          children: [{ context: { mode: "child" }, checks: [{ variable: "message", operator: "equals", value: "child" }] }]
        }]
      }]
      failing = [{
        key: "scenarios/failure.spec", scenario: "failure",
        assertions: [{ description: "failing scenario", checks: [{ variable: "message", operator: "equals", value: "wrong" }] }]
      }]
      malformed = [
        { key: "scenarios/empty.spec", scenario: "empty", assertions: [] },
        {
          key: "scenarios/hybrid.spec", scenario: "hybrid", variable: "message",
          assertions: [{ description: "hybrid", checks: [{ variable: "message", operator: "exists" }] }]
        }
      ]

      Dir.mktmpdir do |directory|
        npx = File.join(directory, "npx")
        log = File.join(directory, "calls.log")
        File.write(npx, <<~RUBY)
          #!#{RbConfig.ruby}
          require "json"
          File.open(ENV.fetch("FAKE_NPX_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
          args = ARGV.drop(1)
          value = if args[0, 2] == ["config", "--json"]
                    { environments: false }
                  elsif args[0, 2] == ["list", "--targets"] || args[0, 2] == ["list", "--segments"]
                    []
                  elsif args[0, 2] == ["list", "--tests"]
                    if ENV["FAKE_MODE"] == "protocol"
                      []
                    else
                      fixture = ENV["FAKE_MODE"] == "pass" ? "FAKE_PASSING" : (ENV["FAKE_MODE"] == "malformed" ? "FAKE_MALFORMED" : "FAKE_FAILING")
                      { kind: "featurevisor.test-execution", schemaVersion: 1, tests: JSON.parse(ENV.fetch(fixture)) }
                    end
                  elsif args.first == "build"
                    JSON.parse(ENV.fetch("FAKE_DATAFILE"))
                  else
                    abort "unexpected arguments: \#{args.inspect}"
                  end
          puts JSON.generate(value)
        RUBY
        File.chmod(0o755, npx)
        env = {
          "PATH" => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
          "FAKE_NPX_LOG" => log,
          "FAKE_DATAFILE" => JSON.generate(datafile),
          "FAKE_PASSING" => JSON.generate(passing),
          "FAKE_FAILING" => JSON.generate(failing),
          "FAKE_MALFORMED" => JSON.generate(malformed),
          "FAKE_MODE" => "pass"
        }
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "bin/featurevisor", "test", "--projectDirectoryPath=#{directory}", "--set=staging", "--entityType=scenario", "--onlyFailures")
        expect(status).to be_success, stdout + stderr
        expect(stdout).to include("Total cases: 1 passed, 0 failed")
        expect(File.read(log, encoding: "UTF-8")).to include("--entityType=scenario")
        expect(File.read(log, encoding: "UTF-8")).to include("--set=staging")

        env["FAKE_MODE"] = "fail"
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "bin/featurevisor", "test", "--projectDirectoryPath=#{directory}", "--set=staging", "--entityType=scenario", "--onlyFailures")
        expect(status.exitstatus).to eq(1), stdout + stderr
        expect(stdout).to include("checks[1]", 'left="parent"')

        env["FAKE_MODE"] = "malformed"
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "bin/featurevisor", "test", "--projectDirectoryPath=#{directory}", "--set=staging", "--entityType=scenario", "--onlyFailures")
        expect(status.exitstatus).to eq(1), stdout + stderr
        expect(stdout).to include("scenario spec requires assertions")
        expect(stdout).to include("requires exactly one of feature, variable, segment or scenario")

        File.write(log, "")
        env["FAKE_MODE"] = "protocol"
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "bin/featurevisor", "test", "--projectDirectoryPath=#{directory}", "--set=staging", "--entityType=scenario", "--onlyFailures")
        expect(status.exitstatus).to eq(1), stdout + stderr
        expect((stdout + stderr).downcase).to include("test execution protocol")
        calls = File.read(log, encoding: "UTF-8")
        expect(calls).to include("list --tests --execution-protocol --json")
        expect(calls).not_to include("featurevisor build")
      end
    end

    it "allows expectations for excluded owners while preflighting child checks before owner evaluation" do
      command = described_class.new(options)
      datafile = { schemaVersion: "2", revision: "target", features: {}, variables: {}, segments: {} }
      datafiles = { ["production", "filtered"] => datafile }
      routing = { environment: "production", target: "filtered" }
      [
        [:feature, { expectedToBeEnabled: false }],
        [:variable, { expectedEvaluation: { reason: "variable_not_found" } }]
      ].each do |type, expectation|
        result = command.send(
          :execute_assertion, { type => "excluded" }, type,
          routing.merge(expectation).merge(children: [expectation]), datafiles, {}, "fatal", nil
        )
        expect(result[:has_error]).to be(false), result[:errors].inspect
      end

      expect(command).not_to receive(:create_tester_instance)
      result = command.send(
        :execute_assertion, { variable: "excluded" }, :variable,
        routing.merge(
          expectedValue: nil,
          children: [{ checks: [{ operator: "isNull" }] }]
        ),
        datafiles, {}, "fatal", nil
      )
      expect(result[:has_error]).to be(true)
      expect(result[:errors].first[:message]).to include('global variable "excluded"')
    end

    it "retains structured malformed version errors from preflight and evaluated comparisons" do
      command = described_class.new(options)
      datafile = {
        schemaVersion: "2", revision: "semver-errors", features: {}, segments: {},
        variables: { version: { type: "string", defaultValue: "" } }
      }
      datafiles = { [nil, nil] => datafile }
      [
        [{ variable: "version", operator: "semverEquals", value: "" }, "valid checks"],
        [{ variable: "version", operator: "semverEquals", value: "1.0.0" }, "successful comparison"],
        [{ variable: "version", operator: "semverEquals", compareTo: { variable: "version" } }, "successful comparison"]
      ].each do |check, expected|
        [check, { not: [check] }].each do |node|
          [:scenario, :variable].each do |type|
            [false, true].each do |child|
              expectation = { checks: [node] }
              assertion = child ? { children: [expectation] } : expectation
              assertion = assertion.merge(_case: { assertionIndex: 4 })
              result = command.send(
                :execute_assertion, { type => "version" }, type, assertion,
                datafiles, {}, "fatal", nil
              )
              errors = command.send(:error_objects, result[:errors], type: type, assertion: assertion)
              expect(result[:has_error]).to be(true)
              expect(errors.length).to eq(1)
              error = errors.first
              path = type == :scenario ? [] : ["assertions", 4]
              path += ["children", 0] if child
              path += ["checks"]
              path << 0 if expected == "successful comparison"
              expect(error).to include(type: "check", expected: expected, path: path)
              expect(error[:actual]).to eq(error[:message])
              expect(error[:actual]).to include("Invalid argument not valid semver")
            end
          end
        end
      end
    end

    it "evaluates expectedEvaluations in child assertions" do
      command = described_class.new(options)
      instance = double("child-instance")

      allow(instance).to receive(:is_enabled).and_return(true)
      allow(instance).to receive(:get_variation).and_return("control")
      allow(instance).to receive(:get_variable).and_return("v")
      allow(instance).to receive(:evaluate_flag).and_return({ type: "flag", enabled: false })
      allow(instance).to receive(:evaluate_variation).and_return({ type: "variation", variation_value: "control" })
      allow(instance).to receive(:evaluate_variable).and_return({ type: "variable", variable_key: "k", variable_value: "v" })

      assertion = {
        expectedEvaluations: {
          flag: {
            enabled: true
          }
        }
      }

      result = command.send(:run_test_feature_child, assertion, "myFeature", instance, "warn")
      expect(result[:has_error]).to be true
      expect(result[:errors]).to include(
        type: "evaluation",
        expected: true,
        actual: false,
        details: { evaluationType: "flag", evaluationKey: :enabled }
      )
    end

    it "reports typed expectation values and authored assertion and child paths" do
      command = described_class.new(options)
      assertion = { _case: { assertionIndex: 4 } }
      errors = command.send(
        :error_objects,
        [
          { type: "flag", expected: true, actual: false, details: {} },
          { type: "variation", expected: "control", actual: nil, details: { childIndex: 2 } },
          { type: "variable", expected: 10, actual: 12, details: { variableKey: "limit" } }
        ],
        type: :feature,
        assertion: assertion
      )

      expect(errors[0]).to include(
        type: "flag", expected: true, actual: false,
        path: ["assertions", 4, "expectedToBeEnabled"]
      )
      expect(errors[1]).to include(
        type: "variation", expected: "control", actual: nil,
        path: ["assertions", 4, "children", 2, "expectedVariation"]
      )
      expect(errors[2]).to include(
        type: "variable", expected: 10, actual: 12,
        path: ["assertions", 4, "expectedVariables", "limit"]
      )
    end

    it "reports actual segment failures with typed values and an authored path" do
      command = described_class.new(options)
      assertion = { expectedToMatch: false, _case: { assertionIndex: 4 } }
      result = command.send(:run_test_segment, assertion, { conditions: "*" }, "fatal")
      errors = command.send(:error_objects, result[:errors], type: :segment, assertion: assertion)
      expect(result[:has_error]).to be(true)
      expect(errors.length).to eq(1)
      expect(errors.first).to include(
        type: "segment", expected: false, actual: true,
        path: ["assertions", 4, "expectedToMatch"]
      )
    end

    it "counts missing-datafile assertion as failed" do
      command = described_class.new(options)

      allow(command).to receive(:exit).and_raise(SystemExit.new(1))

      tests = [
        {
          key: "features/missing.spec",
          feature: "foo",
          assertions: [
            {
              description: "missing datafile assertion",
              environment: "production",
              target: "checkout"
            }
          ]
        }
      ]

      report = command.send(:run_tests, tests, {}, {}, "warn", {}, nil)
      expect(report[:passed]).to be(false)
      expect(report.dig(:summary, :entityAssertions, :failed)).to eq(1)
      expect(report.dig(:results, 0, :cases, 0, :errors, 0, :message)).to include(
        "no datafile found for assertion target/environment combination"
      )
    end
  end

  describe "comparison helpers" do
    it "compares empty hashes and arrays as equal" do
      command = described_class.new(options)

      expect(command.send(:compare_values, {}, {})).to be true
      expect(command.send(:compare_values, [], [])).to be true
    end

    it "treats hash key order as irrelevant" do
      command = described_class.new(options)

      expect(command.send(:compare_values, { a: 1, b: 2 }, { b: 2, a: 1 })).to be true
    end

    it "handles nested hash and array equality correctly" do
      command = described_class.new(options)

      expect(
        command.send(
          :compare_values,
          { a: { b: [1, { c: 2 }] }, d: 3 },
          { a: { b: [1, { c: 2 }] }, d: 3 }
        )
      ).to be true

      expect(
        command.send(
          :compare_values,
          { a: { b: [1, { c: 2 }] }, d: 3 },
          { a: { b: [1, { c: 4 }] }, d: 3 }
        )
      ).to be false
    end

    it "returns false for arrays with same elements in different order" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [1, 2, 3], [3, 2, 1])).to be false
    end

    it "distinguishes nil hash values from missing keys" do
      command = described_class.new(options)

      expect(command.send(:compare_values, { a: nil }, {})).to be false
    end

    it "handles nil positions in arrays" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [nil, 2], [nil, 2])).to be true
      expect(command.send(:compare_values, [2, nil], [nil, 2])).to be false
    end

    it "returns false for different array lengths including extra nil at end" do
      command = described_class.new(options)

      expect(command.send(:compare_values, [1, 2], [1, 2, nil])).to be false
    end
  end
end
