require "featurevisor"

RSpec.describe Featurevisor::Conditions do
  let(:diagnostics) { Featurevisor.const_get(:DiagnosticReporter).new }
  let(:datafile_reader) do
    Featurevisor.const_get(:InstanceEvaluationDataProvider).new(
      datafile: {
        schemaVersion: "2.0",
        revision: "1",
        segments: {},
        features: {}
      },
      diagnostics: diagnostics
    )
  end

  describe "native date values" do
    def date_matches(actual, operator, expected)
      datafile_reader.all_conditions_are_matched(
        { attribute: "date", operator: operator, value: expected }, { date: actual }
      )
    end

    %w[UTC America/Los_Angeles Asia/Tokyo].each do |zone|
      context "with TZ=#{zone}" do
        around do |example|
          previous = ENV["TZ"]
          ENV["TZ"] = zone
          example.run
        ensure
          previous.nil? ? ENV.delete("TZ") : ENV["TZ"] = previous
        end

        it "rejects plain Date on either side of both operators" do
          [Date.new(2026, 1, 1), Class.new(Date).new(2026, 1, 1)].each do |value|
            %w[before after].each do |operator|
              expect(date_matches(value, operator, "2026-01-01T05:00:00Z")).to be false
              expect(date_matches("2026-01-01T05:00:00Z", operator, value)).to be false
            end
          end
        end

        it "accepts Time, DateTime and portable timestamps as the same instant" do
          [Time.utc(2026, 1, 1), Time.new(2026, 1, 1, 9, 0, 0, "+09:00"),
           DateTime.iso8601("2025-12-31T16:00:00-08:00"),
           Class.new(DateTime).iso8601("2026-01-01T00:00:00Z"),
           "2026-01-01T09:00:00+09:00"].each do |value|
            expect(date_matches(value, "before", "2026-01-01T00:00:00.001Z")).to be true
            expect(date_matches(value, "after", "2025-12-31T23:59:59.999Z")).to be true
            expect(date_matches("2026-01-01T00:00:00.001Z", "after", value)).to be true
            expect(date_matches("2025-12-31T23:59:59.999Z", "before", value)).to be true
            %w[before after].each do |operator|
              expect(date_matches(value, operator, "2026-01-01T00:00:00Z")).to be false
            end
          end
        end

        it "truncates native fractions to milliseconds including before the epoch" do
          %w[2026-01-01T00:00:00.000Z 1969-12-31T23:59:59.999Z].each do |boundary|
            instant = Time.iso8601(boundary)
            value = instant + Rational(999999, 1_000_000_000)
            [value, value.getlocal("+09:00"), value.to_datetime].each do |native|
              %w[before after].each do |operator|
                expect(date_matches(native, operator, boundary)).to be false
                expect(date_matches(boundary, operator, native)).to be false
              end
              expect(date_matches(native, "before", instant + Rational(1, 1000))).to be true
              expect(date_matches(native, "after", instant - Rational(1, 1000))).to be true
            end
          end
        end

        it "accepts offsets up to fourteen hours without discarding seconds" do
          instant = Time.utc(2026, 1, 1)
          [-50400, 50400, -50399, 50399, -1, 1].each do |seconds|
            [instant.getlocal(seconds), instant.to_datetime.new_offset(Rational(seconds, 86400))].each do |value|
              expect(date_matches(value, "before", "2026-01-01T00:00:00.001Z")).to be true
              expect(date_matches(value, "after", "2025-12-31T23:59:59.999Z")).to be true
              expect(date_matches("2026-01-01T00:00:00.001Z", "after", value)).to be true
              expect(date_matches("2025-12-31T23:59:59.999Z", "before", value)).to be true
              %w[before after].each do |operator|
                expect(date_matches(value, operator, "2026-01-01T00:00:00Z")).to be false
                expect(date_matches("2026-01-01T00:00:00Z", operator, value)).to be false
              end
            end
          end
          [-1, 1].each do |sign|
            value = instant.getlocal(sign * Rational(100799, 2))
            expect(date_matches(value, "before", "2026-01-01T00:00:00.001Z")).to be true
            expect(date_matches(value, "after", "2025-12-31T23:59:59.999Z")).to be true
          end
        end

        it "rejects offsets beyond fourteen hours including extra seconds and fractions" do
          instant = Time.utc(2026, 1, 1)
          values = [-54000, 54000, -50401, 50401].flat_map do |seconds|
            [instant.getlocal(seconds), instant.to_datetime.new_offset(Rational(seconds, 86400))]
          end
          values += [-1, 1].map { |sign| instant.getlocal(sign * Rational(100801, 2)) }
          values.each do |value|
            %w[before after].each do |operator|
              %w[2025-12-31T23:59:59.999Z 2026-01-01T00:00:00.001Z].each do |boundary|
                expect(date_matches(value, operator, boundary)).to be false
                expect(date_matches(boundary, operator, value)).to be false
              end
            end
          end
        end

        it "rejects native written or UTC years outside the portable range without raising" do
          ["0000-12-31T23:00:00-02:00", "10000-01-01T01:00:00+02:00",
           "0001-01-01T00:00:00+01:00", "9999-12-31T23:59:59-01:00"].each do |text|
            [Time.iso8601(text), DateTime.iso8601(text)].each do |value|
              %w[before after].each do |operator|
                expect(date_matches(value, operator, "2026-01-01T00:00:00Z")).to be false
                expect(date_matches("2026-01-01T00:00:00Z", operator, value)).to be false
              end
            end
          end
        end

        it "accepts both native year range endpoints" do
          [Time.utc(1, 1, 1), Time.utc(9999, 12, 31, 23, 59, Rational(59999, 1000))].each do |value|
            [value, value.to_datetime].each do |native|
              operator = value.year == 1 ? "before" : "after"
              expect(date_matches(native, operator, "2026-01-01T00:00:00Z")).to be true
            end
          end
        end
      end
    end
  end

  describe "basic functionality" do
    it "truncates one to nine string fractional digits to milliseconds" do
      parse = ->(value) { Featurevisor::Conditions.send(:portable_date, value) }
      %w[1239 123999 1239999 123999999].each do |digits|
        expect(parse.call("2024-01-01T00:00:00.#{digits}Z")).to eq(parse.call("2024-01-01T00:00:00.123Z"))
      end
      expect(parse.call("2024-01-01T00:00:00.1234567890Z")).to be_nil
      expect(parse.call("1969-12-31T23:59:59.999999999Z").to_r).to eq(Rational(-1, 1_000))
    end

    it "floors pre epoch host dates to milliseconds and rejects offsets beyond fourteen hours" do
      host = Time.at(Rational(-1, 2000)).utc
      parsed = Featurevisor::Conditions.send(:portable_date, host)
      expect(parsed.to_r).to eq(Rational(-1, 1000))
      expect(Featurevisor::Conditions.send(:portable_date, Time.new(2024, 1, 1, 15, 0, 0, "+15:00"))).to be_nil
      expect(Featurevisor::Conditions.send(:portable_date, "2024-01-01T15:00:00+15:00")).to be_nil
    end

    it "should be a module" do
      expect(Featurevisor::Conditions).to be_a(Module)
    end

    it "should have condition_is_matched method" do
      expect(Featurevisor::Conditions).to respond_to(:condition_is_matched)
    end

    it "should have get_value_from_context method" do
      expect(Featurevisor::Conditions).to respond_to(:get_value_from_context)
    end
  end

  describe "get_value_from_context" do
    it "should get simple values" do
      context = { name: "John", age: 30 }
      expect(Featurevisor::Conditions.get_value_from_context(context, "name")).to eq("John")
      expect(Featurevisor::Conditions.get_value_from_context(context, "age")).to eq(30)
    end

    it "should get nested values using dot notation" do
      context = { user: { profile: { name: "John" } } }
      expect(Featurevisor::Conditions.get_value_from_context(context, "user.profile.name")).to eq("John")
    end

    it "should return nil for non-existent paths" do
      context = { name: "John" }
      expect(Featurevisor::Conditions.get_value_from_context(context, "age")).to be_nil
      expect(Featurevisor::Conditions.get_value_from_context(context, "user.profile.name")).to be_nil
    end

    it "should handle nil context gracefully" do
      expect(Featurevisor::Conditions.get_value_from_context(nil, "name")).to be_nil
    end
  end

  describe "condition operators" do
    let(:get_regex) { ->(pattern, flags) { Regexp.new(pattern, flags) } }

    it "keeps JavaScript primitive equality and presence semantics" do
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "value", operator: "equals", value: 1 },
        { value: "1" }, get_regex
      )).to be false
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "value", operator: "equals", value: 1 },
        { value: true }, get_regex
      )).to be false
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "value", operator: "exists" },
        { value: nil }, get_regex
      )).to be true
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "value", operator: "notExists" },
        { value: nil }, get_regex
      )).to be false
    end

    it "uses strict primitive membership for in and includes" do
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "value", operator: "in", value: [1] },
        { value: "1" }, get_regex
      )).to be false
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "values", operator: "includes", value: 1 },
        { values: [1, true, nil] }, get_regex
      )).to be true
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "values", operator: "includes", value: nil },
        { values: [1, true, nil] }, get_regex
      )).to be true
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "values", operator: "includes", value: 1 },
        { values: ["1"] }, get_regex
      )).to be false
    end

    it "matches empty and notEmpty for shallow string, array and object contents" do
      cases = [
        ["empty", "", true],
        ["notEmpty", "", false],
        ["empty", " ", false],
        ["notEmpty", " ", true],
        ["empty", [], true],
        ["notEmpty", [nil], true],
        ["empty", {}, true],
        ["notEmpty", { value: nil }, true],
        ["empty", nil, false],
        ["notEmpty", nil, false],
        ["empty", 0, false],
        ["notEmpty", false, false],
        ["empty", Object.new, false],
        ["notEmpty", Object.new, false]
      ]

      cases.each do |operator, value, expected|
        condition = { attribute: "profile.value", operator: operator }
        context = { profile: { value: value } }
        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be(expected)
      end

      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "profile.missing", operator: "empty" }, { profile: {} }, get_regex
      )).to be false
      expect(Featurevisor::Conditions.condition_is_matched(
        { attribute: "profile.missing", operator: "notEmpty" }, { profile: {} }, get_regex
      )).to be false
    end

    describe "equals" do
      it "should match exact values" do
        condition = { attribute: "browser_type", operator: "equals", value: "chrome" }
        context = { browser_type: "chrome" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match different values" do
        condition = { attribute: "browser_type", operator: "equals", value: "chrome" }
        context = { browser_type: "firefox" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end

      it "should handle dot notation paths" do
        condition = { attribute: "browser.type", operator: "equals", value: "chrome" }
        context = { browser: { type: "chrome" } }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
    end

    describe "notEquals" do
      it "should match different values" do
        condition = { attribute: "browser_type", operator: "notEquals", value: "chrome" }
        context = { browser_type: "firefox" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match equal values" do
        condition = { attribute: "browser_type", operator: "notEquals", value: "chrome" }
        context = { browser_type: "chrome" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "exists" do
      it "should match when attribute exists" do
        condition = { attribute: "browser_type", operator: "exists" }
        context = { browser_type: "chrome" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when attribute does not exist" do
        condition = { attribute: "browser_type", operator: "exists" }
        context = { other_field: "value" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end

      it "should handle dot notation paths" do
        condition = { attribute: "browser.name", operator: "exists" }
        context = { browser: { name: "chrome" } }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
    end

    describe "notExists" do
      it "should match when attribute does not exist" do
        condition = { attribute: "name", operator: "notExists" }
        context = { other_field: "value" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when attribute exists" do
        condition = { attribute: "name", operator: "notExists" }
        context = { name: "John" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "contains" do
      it "should match when string contains value" do
        condition = { attribute: "name", operator: "contains", value: "Hello" }
        context = { name: "Hello World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when string does not contain value" do
        condition = { attribute: "name", operator: "contains", value: "Hello" }
        context = { name: "Hi World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "notContains" do
      it "should match when string does not contain value" do
        condition = { attribute: "name", operator: "notContains", value: "Hello" }
        context = { name: "Hi World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when string contains value" do
        condition = { attribute: "name", operator: "notContains", value: "Hello" }
        context = { name: "Hello World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "startsWith" do
      it "should match when string starts with value" do
        condition = { attribute: "name", operator: "startsWith", value: "Hello" }
        context = { name: "Hello World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when string does not start with value" do
        condition = { attribute: "name", operator: "startsWith", value: "Hello" }
        context = { name: "Hi Hello World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "endsWith" do
      it "should match when string ends with value" do
        condition = { attribute: "name", operator: "endsWith", value: "World" }
        context = { name: "Hello World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when string does not end with value" do
        condition = { attribute: "name", operator: "endsWith", value: "World" }
        context = { name: "World Hello" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "in" do
      it "should match when value is in array" do
        condition = { attribute: "browser_type", operator: "in", value: ["chrome", "firefox"] }
        context = { browser_type: "chrome" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when value is not in array" do
        condition = { attribute: "browser_type", operator: "in", value: ["chrome", "firefox"] }
        context = { browser_type: "edge" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "notIn" do
      it "should match when value is not in array" do
        condition = { attribute: "browser_type", operator: "notIn", value: ["chrome", "firefox"] }
        context = { browser_type: "edge" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when value is in array" do
        condition = { attribute: "browser_type", operator: "notIn", value: ["chrome", "firefox"] }
        context = { browser_type: "chrome" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "includes" do
      it "should match when array includes value" do
        condition = { attribute: "permissions", operator: "includes", value: "write" }
        context = { permissions: ["read", "write"] }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when array does not include value" do
        condition = { attribute: "permissions", operator: "includes", value: "write" }
        context = { permissions: ["read"] }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "notIncludes" do
      it "should match when array does not include value" do
        condition = { attribute: "permissions", operator: "notIncludes", value: "write" }
        context = { permissions: ["read", "admin"] }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should not match when array includes value" do
        condition = { attribute: "permissions", operator: "notIncludes", value: "write" }
        context = { permissions: ["read", "write", "admin"] }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
      end
    end

    describe "numeric operators" do
      it "should handle greaterThan" do
        condition = { attribute: "age", operator: "greaterThan", value: 18 }
        context = { age: 19 }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle greaterThanOrEquals" do
        condition = { attribute: "age", operator: "greaterThanOrEquals", value: 18 }
        context = { age: 18 }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle lessThan" do
        condition = { attribute: "age", operator: "lessThan", value: 18 }
        context = { age: 17 }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle lessThanOrEquals" do
        condition = { attribute: "age", operator: "lessThanOrEquals", value: 18 }
        context = { age: 18 }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
    end

    describe "semver operators" do
      it "should handle semverEquals" do
        condition = { attribute: "version", operator: "semverEquals", value: "1.0.0" }
        context = { version: "1.0.0" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle semverGreaterThan" do
        condition = { attribute: "version", operator: "semverGreaterThan", value: "1.0.0" }
        context = { version: "2.0.0" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle semverNotEquals" do
        condition = { attribute: "version", operator: "semverNotEquals", value: "1.0.0" }

        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "2.0.0" }, get_regex)
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "1.0.0" }, get_regex)
        ).to be false
      end

      it "should handle semverGreaterThanOrEquals" do
        condition = { attribute: "version", operator: "semverGreaterThanOrEquals", value: "1.0.0" }

        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "2.0.0" }, get_regex)
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "1.0.0" }, get_regex)
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "0.9.0" }, get_regex)
        ).to be false
      end

      it "should handle semverLessThan" do
        condition = { attribute: "version", operator: "semverLessThan", value: "1.0.0" }
        context = { version: "0.9.0" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle semverLessThanOrEquals" do
        condition = { attribute: "version", operator: "semverLessThanOrEquals", value: "1.0.0" }

        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "1.0.0" }, get_regex)
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "0.9.0" }, get_regex)
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(condition, { version: "1.1.0" }, get_regex)
        ).to be false
      end

      it "should compare prereleases and ignore build metadata" do
        expect(
          Featurevisor::Conditions.condition_is_matched(
            { attribute: "version", operator: "semverLessThan", value: "1.2.3" },
            { version: "1.2.3-beta.1" },
            get_regex
          )
        ).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(
            { attribute: "version", operator: "semverEquals", value: "1.2.3+build.9" },
            { version: "1.2.3+build.5" },
            get_regex
          )
        ).to be true
      end
    end

    describe "regex operators" do
      it "should handle matches" do
        condition = { attribute: "name", operator: "matches", value: "^[a-zA-Z]{2,}$" }
        context = { name: "Hello" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle notMatches" do
        condition = { attribute: "name", operator: "notMatches", value: "^[a-zA-Z]{2,}$" }
        context = { name: "Hi World" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end

      it "should handle regex flags" do
        condition = { attribute: "name", operator: "matches", value: "^[a-zA-Z]{2,}$", regexFlags: "i" }
        context = { name: "hello" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
    end

    describe "date operators" do
      it "should handle before" do
        condition = { attribute: "date", operator: "before", value: "2023-05-13T16:23:59Z" }
        context = { date: "2023-05-12T00:00:00Z" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
        expect(
          Featurevisor::Conditions.condition_is_matched(
            condition,
            { date: "2023-05-12T00:00:00" },
            get_regex
          )
        ).to be false
        expect(
          Featurevisor::Conditions.condition_is_matched(
            condition,
            { date: "2023-05-13T17:23:59+01:00" },
            get_regex
          )
        ).to be false
      end

      it "should handle after" do
        condition = { attribute: "date", operator: "after", value: "2023-05-13T16:23:59Z" }
        context = { date: "2023-05-14T00:00:00Z" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
    end
  end

  describe "logical composition via the evaluation data provider" do
    it "should match with multiple conditions inside NOT" do
      conditions = [
        {
          not: [
            { attribute: "browser_type", operator: "equals", value: "chrome" },
            { attribute: "browser_version", operator: "equals", value: "1.0" }
          ]
        }
      ]

      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "firefox",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "1.0"
        })
      ).to be false
    end

    it "should treat empty NOT as false and nested OR under NOT as none-match" do
      none_of_chrome_or_firefox = [
        {
          not: [
            {
              or: [
                { attribute: "browser_type", operator: "equals", value: "chrome" },
                { attribute: "browser_type", operator: "equals", value: "firefox" }
              ]
            }
          ]
        }
      ]

      expect(datafile_reader.all_conditions_are_matched(none_of_chrome_or_firefox, { browser_type: "chrome" })).to be false
      expect(datafile_reader.all_conditions_are_matched(none_of_chrome_or_firefox, { browser_type: "edge" })).to be true
      expect(datafile_reader.all_conditions_are_matched([{ not: [] }], {})).to be false
    end

    it "should match with OR inside AND" do
      conditions = [
        {
          and: [
            { attribute: "browser_type", operator: "equals", value: "chrome" },
            {
              or: [
                { attribute: "browser_version", operator: "equals", value: "1.0" },
                { attribute: "browser_version", operator: "equals", value: "2.0" }
              ]
            }
          ]
        }
      ]

      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "1.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "3.0"
        })
      ).to be false
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_version: "2.0"
        })
      ).to be false
    end

    it "should match with plain conditions, followed by OR inside AND" do
      conditions = [
        { attribute: "country", operator: "equals", value: "nl" },
        {
          and: [
            { attribute: "browser_type", operator: "equals", value: "chrome" },
            {
              or: [
                { attribute: "browser_version", operator: "equals", value: "1.0" },
                { attribute: "browser_version", operator: "equals", value: "2.0" }
              ]
            }
          ]
        }
      ]

      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "nl",
          browser_type: "chrome",
          browser_version: "1.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "nl",
          browser_type: "chrome",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "3.0"
        })
      ).to be false
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "us",
          browser_version: "2.0"
        })
      ).to be false
    end

    it "should match with AND inside OR" do
      conditions = [
        {
          or: [
            { attribute: "browser_type", operator: "equals", value: "chrome" },
            {
              and: [
                { attribute: "device_type", operator: "equals", value: "mobile" },
                { attribute: "orientation", operator: "equals", value: "portrait" }
              ]
            }
          ]
        }
      ]

      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "chrome",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "firefox",
          device_type: "mobile",
          orientation: "portrait"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "firefox",
          browser_version: "2.0"
        })
      ).to be false
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "firefox",
          device_type: "desktop"
        })
      ).to be false
    end

    it "should match with plain conditions, followed by AND inside OR" do
      conditions = [
        { attribute: "country", operator: "equals", value: "nl" },
        {
          or: [
            { attribute: "browser_type", operator: "equals", value: "chrome" },
            {
              and: [
                { attribute: "device_type", operator: "equals", value: "mobile" },
                { attribute: "orientation", operator: "equals", value: "portrait" }
              ]
            }
          ]
        }
      ]

      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "nl",
          browser_type: "chrome",
          browser_version: "2.0"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "nl",
          browser_type: "firefox",
          device_type: "mobile",
          orientation: "portrait"
        })
      ).to be true
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          browser_type: "firefox",
          browser_version: "2.0"
        })
      ).to be false
      expect(
        datafile_reader.all_conditions_are_matched(conditions, {
          country: "de",
          browser_type: "firefox",
          device_type: "desktop"
        })
      ).to be false
    end
  end

  describe "error handling" do
    it "should handle errors gracefully and return false" do
      condition = { attribute: "name", operator: "invalid_operator", value: "test" }
      context = { name: "test" }
      get_regex = ->(pattern, flags) { Regexp.new(pattern, flags) }

      expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be false
    end
  end
end
