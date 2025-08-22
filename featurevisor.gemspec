Gem::Specification.new do |spec|
  spec.name          = "featurevisor"
  spec.version       = "0.1.0"
  spec.authors       = ["Your Name"]
  spec.email         = ["your.email@example.com"]
  spec.summary       = "Featurevisor Ruby SDK with CLI tools for feature management"
  spec.description   = "Featurevisor is a Ruby SDK that provides feature flag management, A/B testing, and progressive delivery capabilities. Includes CLI tools for testing, benchmarking, and distribution analysis."
  spec.homepage      = "https://github.com/yourusername/featurevisor"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.files         = Dir.glob("lib/**/*") + Dir.glob("bin/**/*") + %w[README.md LICENSE]
  spec.bindir        = "bin"
  spec.executables   = ["featurevisor"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rake", "~> 13.0"
end
