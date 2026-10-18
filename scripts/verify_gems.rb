# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/featurevisor/version"

version = Featurevisor::VERSION
base_path = "featurevisor-#{version}.gem"
provider_path = "featurevisor-openfeature-#{version}.gem"

def inspect_gem(path)
  raise "Missing built gem: #{path}" unless File.file?(path)

  package = Gem::Package.new(path)
  [package.spec, package.contents]
end

base, base_files = inspect_gem(base_path)
provider, provider_files = inspect_gem(provider_path)

raise "Base gem version mismatch" unless base.version.to_s == version
raise "Provider gem version mismatch" unless provider.version.to_s == version
raise "Base gem Ruby requirement changed" unless base.required_ruby_version == Gem::Requirement.new(">= 3.0.0")
raise "Provider must require Ruby 3.4 or newer" unless provider.required_ruby_version == Gem::Requirement.new(">= 3.4.0")
raise "Base gem is missing its entry point" unless base_files.include?("lib/featurevisor.rb")
raise "Base gem is missing its CLI" unless base_files.include?("bin/featurevisor")
raise "Provider leaked into base gem" if base_files.include?("lib/featurevisor/openfeature_provider.rb")
raise "Provider entry point leaked into base gem" if base_files.include?("lib/featurevisor-openfeature.rb")
raise "Base gem depends on OpenFeature" if base.dependencies.any? { |dependency| dependency.name == "openfeature-sdk" }

expected_provider_files = %w[lib/featurevisor-openfeature.rb lib/featurevisor/openfeature_provider.rb]
missing_provider_files = expected_provider_files - provider_files
raise "Provider gem is missing: #{missing_provider_files.join(', ')}" unless missing_provider_files.empty?

featurevisor_dependency = provider.dependencies.find { |dependency| dependency.name == "featurevisor" }
openfeature_dependency = provider.dependencies.find { |dependency| dependency.name == "openfeature-sdk" }
raise "Provider must depend on matching Featurevisor version" unless featurevisor_dependency&.requirement == Gem::Requirement.new("= #{version}")
raise "Provider must depend on openfeature-sdk ~> 0.6.5" unless openfeature_dependency&.requirement == Gem::Requirement.new("~> 0.6.5")

Dir.mktmpdir("featurevisor-packaged-") do |directory|
  base_directory = File.join(directory, "base")
  provider_directory = File.join(directory, "provider")
  Gem::Package.new(base_path).extract_files(base_directory)
  Gem::Package.new(provider_path).extract_files(provider_directory)
  paths = [File.join(base_directory, "lib"), File.join(provider_directory, "lib")]
  paths.concat(Gem::Specification.find_by_name("openfeature-sdk", "~> 0.6.5").full_require_paths)
  base_script = <<~RUBY
    require "featurevisor"
    abort "OpenFeature leaked into base gem" if defined?(OpenFeature)
    instance = Featurevisor.create_featurevisor(log_level: "fatal")
    instance.close
  RUBY
  stdout, stderr, status = Open3.capture3(
    {"RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil},
    RbConfig.ruby, "--disable-gems", "-I", paths.first, "-e", base_script,
    chdir: directory
  )
  raise "Packaged base could not load without OpenFeature: #{stdout}#{stderr}" unless status.success?
  script = <<~RUBY
    require "featurevisor-openfeature"
    abort "Wrong packaged version" unless Featurevisor::VERSION == #{version.inspect}
    tracked = []
    provider = Featurevisor::OpenFeatureProvider.new(
      log_level: "fatal", on_track: ->(*args) { tracked << args },
      datafile: { schemaVersion: "4", revision: "packaged", segments: {},
                  features: { checkout: { bucketBy: "userId", traffic: [{ key: "all", conditions: "*", percentage: 100_000 }] } } }
    )
    OpenFeature::SDK.configure { |config| config.set_provider_and_wait(provider) }
    client = OpenFeature::SDK.build_client
    abort "Packaged client resolution failed" unless client.fetch_boolean_value(flag_key: "checkout", default_value: false)
    client.track("purchase")
    abort "Packaged tracking failed" unless tracked.first&.first == "purchase"
    OpenFeature::SDK.shutdown
  RUBY
  stdout, stderr, status = Open3.capture3(
    {"RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil},
    RbConfig.ruby, *paths.flat_map { |path| ["-I", path] }, "-e", script,
    chdir: directory
  )
  raise "Packaged provider could not load its separate core gem: #{stdout}#{stderr}" unless status.success?
end

puts "Verified #{base_path} and #{provider_path}"
