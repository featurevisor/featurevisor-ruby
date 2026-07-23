# frozen_string_literal: true

require "featurevisor"

RSpec.describe "Featurevisor public API" do
  it "keeps reader and diagnostic implementation types private" do
    expect { Featurevisor::InstanceEvaluationDataProvider }.to raise_error(NameError)
    expect { Featurevisor::DiagnosticReporter }.to raise_error(NameError)
    expect(Featurevisor.const_defined?(:DatafileReader, false)).to be(false)
    expect(Featurevisor.const_defined?(:Logger, false)).to be(false)
  end
end
