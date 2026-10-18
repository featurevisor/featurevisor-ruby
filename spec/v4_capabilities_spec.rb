# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "v4 conditions and composition capabilities" do
  def portable(value)
    JSON.parse(JSON.generate(value))
  end

  { "sdk-conditions.json" => [1, "unified-conditions"],
    "sdk-composition.json" => [2, "composition-and-overrides"] }.each do |filename, (version, capability)|
    it "executes all #{capability} cases twice", :aggregate_failures do
      fixture = JSON.parse(File.read(File.expand_path("../conformance/#{filename}", __dir__)), symbolize_names: true)
      expect(fixture[:version]).to eq(version)
      expect(fixture[:capability]).to eq(capability)
      expect(fixture[:cases]).not_to be_empty
      expect(fixture[:cases].map { |test| test[:name] }.uniq.length).to eq(fixture[:cases].length)
      fields = { ruleKey: :rule_key, variableOverridePaths: :variable_override_paths, variableOverridePath: :variable_override_path,
                 variableOverrideKey: :variable_override_key, variableOverrideIndex: :variable_override_index }
      fixture[:cases].each do |test_case|
        dependencies = []
        options = (test_case[:options] || {}).to_h do |key, value|
          [{ stickyFeatures: :sticky_features, stickyVariables: :sticky_variables, logLevel: :log_level }.fetch(key, key), value]
        end
        options[:sticky_features] = test_case[:stickyFeatures] if test_case.key?(:stickyFeatures)
        options[:sticky_variables] = test_case[:stickyVariables] if test_case.key?(:stickyVariables)
        options[:modules] = [{ name: "trace", before_evaluation: lambda do |input|
          if input[:dependency_purpose]
            dependencies << { feature: input[:feature_key], variable: input[:variable_key], dependencyPurpose: input[:dependency_purpose] }.compact
          end
          input
        end }]
        datafile = test_case[:datafile] || fixture[:datafile]
        source = portable(datafile)
        f = Featurevisor.create_featurevisor(**options, datafile: datafile, log_level: "fatal")
        begin
          2.times do |run|
            context = test_case[:context] || {}
            type = test_case[:type] || "variable"
            value = type == "flag" ? f.is_enabled(test_case[:feature], context) : f.get_variable(test_case[:variable] || "subject", context)
            expected = test_case[:expected] || test_case[:expectedEvaluation].merge(value: test_case[:expectedValue])
            expect(value).to eq(expected[:enabled] == true), "#{test_case[:name]} flag getter #{run}" if type == "flag"
            expect(portable(value)).to eq(portable(expected[:value])), "#{test_case[:name]} getter #{run}" if expected.key?(:value)
            dependencies.clear
            evaluated = type == "flag" ? f.evaluate_flag(test_case[:feature], context) : f.evaluate_variable(test_case[:variable] || "subject", context)
            expected.each do |key, wanted|
              next if key == :value
              expect(evaluated).to have_key(:conditions), test_case[:name] if key == :conditions
              expect(portable(evaluated[fields.fetch(key, key)])).to eq(portable(wanted)), "#{test_case[:name]} #{key} #{run}"
            end
            expect(portable(dependencies)).to eq(portable(test_case[:dependencies])), test_case[:name] if test_case.key?(:dependencies)
            if capability == "composition-and-overrides"
              sticky_policy = test_case.fetch(:stickyVariables, {})
              policy = sticky_policy.key?(:policy) && sticky_policy[:policy].nil? ? nil : { limit: 50, methods: ["card"] }
              expect(f.get_variable("policy")).to eq(policy), "#{test_case[:name]} source ownership #{run}"
              definition = datafile[:variables][test_case[:variable].to_sym]
              if definition[:compose].is_a?(Array) && !%w[error sticky].include?(expected[:reason])
                fresh = f.get_variable(test_case[:variable], context)
                expect(fresh).to be_a(Hash)
                expect(fresh).not_to equal(value), "#{test_case[:name]} outer ownership #{run}"
              end
            end
          end
          expect(portable(datafile)).to eq(source)
        ensure
          f.close
        end
      end
    end
  end
end
