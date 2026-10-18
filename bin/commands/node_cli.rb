module FeaturevisorCLI
  # Runs the project's own Node based Featurevisor CLI.
  #
  # Node starts the local package entry directly, with an argument list and a
  # working directory, so no shell quoting is involved on any platform. Without a
  # local package, npx resolves the CLI as before, through npx.cmd on Windows.
  module NodeCli
    def self.command(project_path)
      directory = File.expand_path(project_path)
      loop do
        entry = File.join(directory, "node_modules", "@featurevisor", "cli", "bin.js")
        return ["node", entry] if File.file?(entry)
        parent = File.dirname(directory)
        break if parent == directory
        directory = parent
      end
      [Gem.win_platform? ? "npx.cmd" : "npx", "featurevisor"]
    end
  end
end
