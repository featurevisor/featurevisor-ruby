require "rspec/core/rake_task"
require "fileutils"
require_relative "lib/featurevisor/version"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Build and verify both gems"
task :build do
  sh "gem build featurevisor.gemspec"
  sh "gem build featurevisor-openfeature.gemspec"
  sh "ruby scripts/verify_gems.rb"
end

desc "Install the gem locally"
task :install => :build do
  sh "gem install featurevisor-#{Featurevisor::VERSION}.gem"
  sh "gem install featurevisor-openfeature-#{Featurevisor::VERSION}.gem"
end

desc "Clean up built gems"
task :clean do
  FileUtils.rm_f Dir["*.gem"]
end
