require "featurevisor"

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "bin"))
require "cli"

RSpec.describe FeaturevisorCLI::Commands::Test do
  let(:options) do
    opts = FeaturevisorCLI::Options.new
    opts.project_directory_path = "/tmp/featurevisor-project"
    opts
  end

  describe "datafile routing helpers" do
    it "prefers scoped datafile over tagged and base datafile" do
      command = described_class.new(options)

      datafiles_by_key = {
        "production" => { schemaVersion: "2" },
        "production-tag-web" => { schemaVersion: "2", tagged: true },
        "production-scope-browsers" => { schemaVersion: "2", scoped: true }
      }

      assertion = {
        environment: "production",
        scope: "browsers",
        tag: "web"
      }

      datafile = command.send(:resolve_datafile_for_assertion, assertion, datafiles_by_key)
      expect(datafile[:scoped]).to be true
    end

    it "returns parsed scope context by name" do
      command = described_class.new(options)
      config = {
        scopes: [
          { name: "browsers", context: { "platform" => "web" } }
        ]
      }

      scope_context = command.send(:get_scope_context, config, "browsers")
      expect(scope_context).to eq({ platform: "web" })
    end
  end

  describe "build command generation" do
    it "includes scope and environment flags when building scoped datafiles" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(include("featurevisor build", "--environment=production", "--scope=browsers", "--json"))
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: "production",
        schema_version: "2",
        inflate: nil,
        scope: "browsers"
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end

    it "does not include environment flag when environment is false" do
      command = described_class.new(options)

      expect(command).to receive(:execute_command)
        .with(satisfy { |cmd| cmd.include?("featurevisor build") && !cmd.include?("--environment=") })
        .and_return('{"schemaVersion":"2","revision":"1","segments":{},"features":{}}')

      datafile = command.send(
        :build_single_datafile,
        environment: false,
        schema_version: nil,
        inflate: nil
      )

      expect(datafile[:schemaVersion]).to eq("2")
    end
  end
end
