require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Build the gem"
task :build do
  system "gem build featurevisor.gemspec"
end

desc "Install the gem locally"
task :install => :build do
  system "gem install featurevisor-*.gem"
end

desc "Clean up built gems"
task :clean do
  FileUtils.rm_f Dir["*.gem"]
end
