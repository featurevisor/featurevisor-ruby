require "featurevisor"

RSpec.describe Featurevisor::Conditions do
  let(:logger) { Featurevisor.create_logger }
  let(:datafile_reader) do
    Featurevisor::DatafileReader.new(
      datafile: {
        schemaVersion: "2.0",
        revision: "1",
        segments: {},
        features: {}
      },
      logger: logger
    )
  end

  describe "basic functionality" do
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

      it "should handle semverLessThan" do
        condition = { attribute: "version", operator: "semverLessThan", value: "1.0.0" }
        context = { version: "0.9.0" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
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
      end

      it "should handle after" do
        condition = { attribute: "date", operator: "after", value: "2023-05-13T16:23:59Z" }
        context = { date: "2023-05-14T00:00:00Z" }

        expect(Featurevisor::Conditions.condition_is_matched(condition, context, get_regex)).to be true
      end
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
