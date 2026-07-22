require_relative "lib/featurevisor/version"

Gem::Specification.new do |spec|
  spec.name          = "featurevisor-openfeature"
  spec.version       = Featurevisor::VERSION
  spec.authors       = ["Fahad Heylaal"]
  spec.summary       = "OpenFeature provider for Featurevisor"
  spec.description   = "OpenFeature provider backed by the Featurevisor Ruby SDK"
  spec.homepage      = "https://featurevisor.com/docs/sdks/openfeature/"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata = {
    "source_code_uri" => "https://github.com/featurevisor/featurevisor-ruby",
    "documentation_uri" => "https://featurevisor.com/docs/sdks/ruby/#openfeature",
    "bug_tracker_uri" => "https://github.com/featurevisor/featurevisor-ruby/issues",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  spec.files = %w[
    lib/featurevisor-openfeature.rb
    lib/featurevisor/openfeature_provider.rb
    README.md
    LICENSE
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "featurevisor", "= #{Featurevisor::VERSION}"
  spec.add_dependency "openfeature-sdk", "~> 0.6.5"
end
