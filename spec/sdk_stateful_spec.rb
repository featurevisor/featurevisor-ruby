# frozen_string_literal: true

require "json"
require "featurevisor"

RSpec.describe "Featurevisor stateful conformance" do
  def normalize_events(events)
    events.map do |event|
      details = event[:details].dup
      %i[features variables].each do |key|
        details[key] = details[key].map(&:to_s).sort if details.key?(key)
      end
      event.merge(details: details)
    end
  end

  it "runs every stateful fixture case and operation" do
    fixture = JSON.parse(
      File.read(File.expand_path("../conformance/sdk-stateful.json", __dir__), encoding: "UTF-8"),
      symbolize_names: true
    )
    expect(fixture[:kind]).to eq("featurevisor.sdk-stateful")
    expect(fixture[:schemaVersion]).to eq(1)
    expect(fixture[:cases].length).to eq(8)

    fixture[:cases].each do |test_case|
      diagnostics = []
      events = []
      targets = {
        "root" => Featurevisor.create_featurevisor(
          datafile: test_case.dig(:initial, :datafile),
          context: test_case.dig(:initial, :context) || {},
          log_level: "error",
          on_diagnostic: ->(diagnostic) { diagnostics << diagnostic }
        )
      }
      watch = lambda do |target_name|
        %w[datafile_set sticky_features_set sticky_variables_set].each do |event_name|
          targets.fetch(target_name).on(event_name, lambda do |details|
            events << { target: target_name, name: event_name, details: details }
          end)
        end
      end
      watch.call("root")

      begin
        test_case[:operations].each do |operation|
          events.clear
          diagnostics.clear
          error = nil
          begin
            case operation[:action]
            when "setDatafile"
              targets.fetch(operation[:target]).set_datafile(operation[:datafile], operation[:replace])
            when "spawn"
              targets[operation[:target]] = targets.fetch(operation[:parent]).spawn(
                operation[:context] || {}, operation[:options] || {}
              )
              watch.call(operation[:target])
            when "setStickyFeatures"
              targets.fetch(operation[:target]).set_sticky_features(
                operation[:stickyFeatures], operation[:replace]
              )
            when "setStickyVariables"
              targets.fetch(operation[:target]).set_sticky_variables(
                operation[:stickyVariables], operation[:replace]
              )
            else
              raise "Unsupported fixture action: #{operation[:action]}"
            end
          rescue => caught
            error = caught
          end

          expected = operation[:expect]
          expect(normalize_events(events)).to eq(normalize_events(expected[:events])), test_case[:name]
          if expected[:error]
            matching = diagnostics.any? { |diagnostic| diagnostic[:code] == expected.dig(:error, :code) }
            expect(matching).to be(true), test_case[:name]
            expect(error).to be_nil, test_case[:name]
          else
            expect(error).to be_nil, test_case[:name]
          end

          expected[:results].each do |result|
            target = targets.fetch(result[:target])
            actual = case result[:method]
                     when "getRevision" then target.get_revision
                     when "isEnabled" then target.is_enabled(*result[:args])
                     when "getVariable" then target.get_variable(*result[:args])
                     else raise "Unsupported fixture method: #{result[:method]}"
                     end
            expect(actual).to eq(result[:value]), test_case[:name]
          end
        end
      ensure
        targets.reverse_each { |name, target| target.close unless name == "root" }
        targets.fetch("root").close
      end
    end
  end
end
