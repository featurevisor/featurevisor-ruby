require "featurevisor"
require "json"
require_relative "../bin/test_checks"

RSpec.describe "Array overlap operators" do
  cases = JSON.parse(<<~'JSON')
    [
      ["strings",["read","write"],["admin","write"],true],
      ["no match",["read"],["write"],false],
      ["mixed primitives",["one",2,true,null],["missing",2,false],true],
      ["null",[null],[null],true],
      ["true",[true],[true],true],
      ["false",[false],[false],true],
      ["numeric equality",[1],[1],true],
      ["number not boolean",[1],[true],false],
      ["boolean not number",[true],[1],false],
      ["zero not false",[0],[false],false],
      ["false not zero",[false],[0],false],
      ["number not string",[1],["1"],false],
      ["string not number",["1"],[1],false],
      ["null not false",[null],[false],false],
      ["duplicates",["write","write"],["write","write"],true],
      ["candidate order",["read","write"],["write","read"],true],
      ["empty candidate",["read"],[],false],
      ["empty actual",[],["read"],false],
      ["both empty",[],[],false],
      ["structured actual ignored",[{},[],{"x":1},"read"],["read"],true],
      ["only structured actual",[{},[],{"x":1}],[null,1],false],
      ["null actual",null,[],null],
      ["string actual","read",["read"],null],
      ["number actual",1,[1],null],
      ["boolean actual",true,[true],null],
      ["object actual",{},[],null],
      ["numeric object actual",{"0":"read"},["read"],null],
      ["null candidate",["read"],null,null],
      ["scalar candidate",["read"],"read",null],
      ["object candidate",["read"],{},null],
      ["nested candidate after match",["read"],["read",[]],null],
      ["object candidate after match",["read"],["read",{}],null],
      ["invalid before match",["read"],[{},"read"],null],
      ["invalid candidate empty actual",[],[{}],null]
    ]
  JSON

  cases.each do |name, actual, candidate, matched|
    %w[includesAny notIncludesAny].each do |operator|
      it "#{name} #{operator}" do
        expected = !matched.nil? && (operator == "includesAny" ? matched : !matched)
        requirement = { variable: "source", path: ["items"], operator: operator, value: candidate }
        traffic = [{ key: "all", segments: "*", percentage: 100000, allocation: [] }]
        source = { type: "object", defaultValue: { items: actual } }
        datafile = {
          schemaVersion: "2", revision: "any", segments: {},
          features: {
            sourceFeature: { bucketBy: "userId", traffic: traffic, variablesSchema: { source: source } },
            condition: { bucketBy: "userId", traffic: [], force: [{
              conditions: { attribute: "profile.items", operator: operator, value: candidate }, enabled: true
            }] }
          },
          variables: { source: source, other: { type: "object", defaultValue: { items: candidate } } }
        }
        [false, true].each do |feature_source|
          selected = requirement.merge(feature_source ? { feature: "sourceFeature" } : {})
          %w[direct not or].each do |group|
            requirements = group == "direct" ? [selected] : [{ group.to_sym => [selected] }]
            key = "gate#{feature_source}#{group}".to_sym
            datafile[:variables][key] = { type: "boolean", defaultValue: true, disabledValue: false, conditions: requirements }
            datafile[:features][key] = { bucketBy: "userId", traffic: traffic, conditions: requirements }
          end
        end
        sdk = Featurevisor.create_featurevisor(datafile: datafile, log_level: "fatal")
        begin
          expect(sdk.is_enabled("condition", profile: { items: actual })).to eq(expected)
          expect(sdk.is_enabled("condition", profile: {})).to eq(false)
          condition = datafile[:features][:condition][:force][0][:conditions]
          [nil, :not, :or].each do |group|
            expression = group.nil? ? condition : { group => [condition] }
            datafile[:features][:condition][:force][0][:conditions] = JSON.generate(expression)
            sdk.set_datafile(datafile, true)
            expect(sdk.is_enabled("condition", profile: { items: actual })).to eq(group == :not ? !expected : expected)
          end
          [false, true].each do |feature_source|
            selected = requirement.merge(feature_source ? { feature: "sourceFeature" } : {})
            %w[direct not or].each do |group|
              key = "gate#{feature_source}#{group}"
              expect(sdk.get_variable(key)).to eq(group == "not" ? !expected : expected)
              expect(sdk.is_enabled(key)).to eq(group == "not" ? !expected : expected)
            end
            [false, true].each do |compare_to|
              check = selected.dup
              if compare_to
                check.delete(:value)
                check[:compareTo] = { variable: "other", path: ["items"] }
              end
              %w[direct not or].each do |group|
                node = group == "direct" ? check : { group.to_sym => [check] }
                report = FeaturevisorCLI::TestChecks.evaluate_result(sdk, datafile, [node], owner_variable: nil, diagnostics: [])
                expect(report[:error]).to eq(matched.nil?)
                expect(report[:passed]).to eq(!matched.nil? && (group == "not" ? !expected : expected))
                if matched.nil?
                  expect(report[:errors][0][:type]).to eq("check")
                  expect(["valid check", "successful comparison"]).to include(report[:errors][0][:expected])
                  expect(report[:errors][0][:details][:evaluated]).not_to be_empty if compare_to
                end
              end
            end
          end
          check = { variable: "source", path: ["absent"], operator: operator, value: [] }
          report = FeaturevisorCLI::TestChecks.evaluate_result(sdk, datafile, [check], owner_variable: nil, diagnostics: [])
          expect(report[:error]).to eq(false)
          expect(report[:passed]).to eq(false)
          malformed = { variable: "source", path: ["items"], operator: operator, compareTo: { variable: "other", path: ["items"] } }
          report = FeaturevisorCLI::TestChecks.evaluate_result(sdk, datafile, [{ or: [{ variable: "source", operator: "exists" }, malformed] }], owner_variable: nil, diagnostics: [])
          expect(report[:passed]).to eq(true)
          expect(report[:error]).to eq(false)
        ensure
          sdk.close
        end
      end
    end
  end
end
