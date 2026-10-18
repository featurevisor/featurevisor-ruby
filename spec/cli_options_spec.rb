require "featurevisor"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../bin/cli"

RSpec.describe "Native CLI option alignment" do
  let(:parser) { FeaturevisorCLI::Parser }

  it "maps camelCase and kebab case aliases in both value forms" do
    aliases = {
      "projectDirectoryPath" => ["project-directory-path", :project_directory_path, "/tmp/quoted ' path"],
      "keyPattern" => ["key-pattern", :key_pattern, "^ready.*$"],
      "assertionPattern" => ["assertion-pattern", :assertion_pattern, "with spaces"],
      "onlyFailures" => ["only-failures", :only_failures, nil],
      "showDatafile" => ["show-datafile", :show_datafile, nil],
      "populateUuid" => ["populate-uuid", :populate_uuid, "userId"],
      "entityType" => ["entity-type", :entity_type, "feature"]
    }
    %w[test benchmark assess-distribution].each do |command|
      aliases.each do |camel, (kebab, field, value)|
        [false, true].each do |separate|
          args = ->(name) { value.nil? ? ["--#{name}"] : (separate ? ["--#{name}", value] : ["--#{name}=#{value}"]) }
          expect(parser.parse([command, *args.call(camel)]).public_send(field))
            .to eq(parser.parse([command, *args.call(kebab)]).public_send(field))
        end
      end
      %w[project-directory-path projectDirectoryPath root-directory-path rootDirectoryPath].each do |name|
        [["--#{name}=/tmp/quoted ' path"], ["--#{name}", "/tmp/quoted ' path"]].each do |args|
          options = parser.parse([command, *args])
          expect(options.project_directory_path).to eq("/tmp/quoted ' path")
          expect(options.project_directory_path_explicit).to be(true)
        end
      end
    end
  end

  it "accepts iteration forms and preserves repeated selectors and quoted JSON" do
    context = '{"userId":"a b", "literal":"$(touch injected)"}'
    %w[test benchmark assess-distribution].each do |command|
      [["--n=2"], ["--n", "2"], ["-n=2"], ["-n", "2"], ["--iterations=2"]].each do |iterations|
        options = parser.parse([command, *iterations, "--target=web space", "--target", "mobile",
          "--target=web space", "--populate-uuid=userId", "--populateUuid", "accountId", "--context", context])
        expect(options.n).to eq(2)
        expect(options.targets).to eq(["web space", "mobile"])
        expect(options.populate_uuid).to eq(%w[userId accountId])
        expect(options.context).to eq(context)
      end
    end
  end

  it "rejects usage errors before any subprocess and without stdout" do
    invalid = [["--unknown"], ["extra"], ["--", "extra"], ["--target", "web", "mobile"],
      ["--populate-uuid", "userId", "accountId"], ["--target="], ["--populate-uuid="],
      ["--root-directory-path="], ["--target"], ["--populate-uuid"], ["--context="],
      ["--context=[]"], ["--context=null"], ["--context={"], ["--feature="], ["--variable="],
      ["--entity-type=unknown"], ["--target", "--quiet"]]
    %w[--n -n --inflate].each do |name|
      %w[0 -1 1.5 bad].push("").each { |value| invalid << ["#{name}=#{value}"] }
      invalid << [name]
    end
    expect(Open3).not_to receive(:capture3)
    %w[test benchmark assess-distribution].each do |command|
      invalid.each do |args|
        expect {
          expect {
            expect { FeaturevisorCLI.run([command, "--feature=ready", *args]) }
              .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
          }.to output(/Error:/).to_stderr
        }.to output("").to_stdout
      end
    end
  end

  it "shows root and command help and rejects unknown dispatch" do
    [[], ["--help"], ["-h"]].each do |args|
      expect { FeaturevisorCLI.run(args) }.to output(/Commands:/).to_stdout
    end
    %w[test benchmark assess-distribution].each do |command|
      expect {
        expect { FeaturevisorCLI.run([command, "--help"]) }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
      }.to output(/Usage: featurevisor #{command}.*--root-directory-path.*--populate-uuid/m).to_stdout
    end
    %w[evaluate typo --unknown].each do |command|
      expect {
        expect { FeaturevisorCLI.run([command]) }
          .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      }.to output(/Unknown command/).to_stderr
    end
  end

  it "preserves literal paths, selectors and the JSON output boundary in real processes" do
    Dir.mktmpdir("featurevisor cli ") do |directory|
      project = File.join(directory, "project ' café $(touch injected)")
      Dir.mkdir(project)
      calls = File.join(directory, "calls.jsonl")
      shim = File.join(directory, "npx")
      File.write(shim, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        args = ARGV.drop(1)
        File.open(ENV.fetch("CLI_CALLS"), "a") { |log| log.puts(JSON.generate([Dir.pwd, args])) }
        value = if args[0] == "config"
          {environments: false, sets: false}
        elsif args[0] == "list"
          if args.include?("--tests")
            {kind: "featurevisor.test-execution", schemaVersion: 1, tests: [{feature: "ready", assertions: [{expectedToBeEnabled: true}]}]}
          elsif args.include?("--targets")
            ["web space", "mobile'quote"]
          else
            []
          end
        else
          warn "delegated warning"
          {schemaVersion: "2", revision: "test", segments: {}, features: {ready: {bucketBy: "userId", traffic: [{key: "all", segments: "*", percentage: 100000}]}}}
        end
        puts JSON.generate(value)
      RUBY
      File.chmod(0o755, shim)
      context = JSON.generate({userId: "a b ' café", literal: "$(touch injected)"})
      pattern = "ready ' café;$()"
      %w[test benchmark assess-distribution].each do |command|
        File.write(calls, "")
        options = command == "test" ? ["--json", "--show-datafile", "--only-failures", "--key-pattern", pattern,
          "--assertion-pattern=with spaces", "--entity-type=feature"] : ["--context", context]
        stdout, stderr, status = Open3.capture3(
          {"PATH" => "#{directory}:#{ENV['PATH']}", "CLI_CALLS" => calls}, RbConfig.ruby,
          File.expand_path("../bin/featurevisor", __dir__), command,
          "--root-directory-path", project, "--feature=ready", "-n=2",
          "--target=web space", "--target", "mobile'quote", "--target=web space", *options
        )
        stdout.force_encoding(Encoding::UTF_8)
        stderr.force_encoding(Encoding::UTF_8)
        expect(status.success?).to be(true), stdout + stderr
        recorded = File.readlines(calls, encoding: "UTF-8").map { |line| JSON.parse(line) }
        expect(recorded.map { |cwd, _| File.realpath(cwd) }.uniq).to eq([File.realpath(project)])
        targets = recorded.filter_map { |_, call| call.grep(/^--target=/) if call[0] == "build" }.flatten
        expect(targets).to eq(["--target=web space", "--target=mobile'quote"])
        if command == "test"
          expect(JSON.parse(stdout)["passed"]).to be(true)
          delegated = recorded.find { |_, call| call.include?("--tests") }.last
          expect(delegated).to include("--keyPattern=#{pattern}", "--assertionPattern=with spaces", "--entityType=feature")
          expect(stderr).to include('"schemaVersion": "2"')
        else
          expect(stdout).not_to include("Environment:")
          expect(stdout).to include(context)
        end
        expect(File.exist?(File.join(project, "injected"))).to be(false)
      end
    end
  end
end
