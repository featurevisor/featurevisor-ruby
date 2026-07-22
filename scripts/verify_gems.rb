# frozen_string_literal: true

require "rubygems/package"
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

puts "Verified #{base_path} and #{provider_path}"
