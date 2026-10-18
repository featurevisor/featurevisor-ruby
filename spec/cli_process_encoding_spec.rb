require "featurevisor"
require "rbconfig"
require "shellwords"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "bin"))
require "cli"

RSpec.describe "CLI subprocess encoding" do
  let(:options) do
    FeaturevisorCLI::Options.new.tap do |value|
      value.project_directory_path = Dir.pwd
    end
  end

  def ruby_command(exit_code)
    script = 'STDOUT.write([99, 97, 102, 195, 169].pack("C*")); STDERR.write([195, 169].pack("C*")); exit ARGV[0].to_i'
    [RbConfig.ruby, "-e", script, exit_code.to_s].shelljoin
  end

  around do |example|
    original_encoding = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    example.run
  ensure
    Encoding.default_external = original_encoding
  end

  it "decodes test command output and error diagnostics as UTF-8" do
    command = FeaturevisorCLI::Commands::Test.new(options)
    expect(command.send(:execute_command, ruby_command(0))).to eq("café")
    expect { command.send(:execute_command, ruby_command(7)) }
      .to raise_error(FeaturevisorCLI::Commands::Test::InfrastructureError, /é/)
  end

  it "decodes benchmark output and error diagnostics as UTF-8" do
    command = FeaturevisorCLI::Commands::Benchmark.new(options)
    expect(command.send(:execute_command, ruby_command(0))).to eq("café")
    original_stdout = $stdout
    output = StringIO.new
    $stdout = output
    expect { command.send(:execute_command, ruby_command(7)) }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    expect(output.string).to include("Stderr: é")
  ensure
    $stdout = original_stdout
  end

  it "decodes assessment output and error diagnostics as UTF-8" do
    command = FeaturevisorCLI::Commands::AssessDistribution.new(options)
    stdout, stderr, status = command.send(:execute_command, ruby_command(7))
    expect([stdout, stderr, status]).to eq(["café", "é", 7])
    expect(stdout.encoding).to eq(Encoding::UTF_8)
    expect(stderr.encoding).to eq(Encoding::UTF_8)
  end

  it "decodes target lists as UTF-8" do
    Dir.mktmpdir do |directory|
      script = File.join(directory, "npx")
      File.write(script, "#!/bin/sh\nprintf '[\"caf\\303\\251\"]'\n")
      File.chmod(0o755, script)
      original_path = ENV["PATH"]
      ENV["PATH"] = "#{directory}:#{original_path}"
      options.targets = ["café"]
      [FeaturevisorCLI::Commands::Benchmark, FeaturevisorCLI::Commands::AssessDistribution].each do |klass|
        expect(klass.new(options).send(:resolve_targets)).to eq(["café"])
      end
    ensure
      ENV["PATH"] = original_path
    end
  end
end
