require "featurevisor"

RSpec.describe Featurevisor do
  # Tests for the main module - only testing what exists in TypeScript version
  it "should have an Error class" do
    expect(Featurevisor::Error).to be_a(Class)
    expect(Featurevisor::Error).to be < StandardError
  end
end
