require_relative "lib/featurevisor/version"

Gem::Specification.new do |spec|
  spec.name          = "featurevisor"
  spec.version       = Featurevisor::VERSION
  spec.authors       = ["Fahad Heylaal"]
  spec.summary       = "Featurevisor Ruby SDK"
  spec.description   = "Featurevisor Ruby SDK with CLI tools for feature flags management"
  spec.homepage      = "https://featurevisor.com"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.files         = Dir.glob("lib/**/*") + Dir.glob("bin/**/*") + %w[README.md LICENSE]
  spec.bindir        = "bin"
  spec.executables   = ["featurevisor"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rake", "~> 13.0"
end
