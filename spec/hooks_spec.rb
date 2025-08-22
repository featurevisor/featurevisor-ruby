require "featurevisor"

RSpec.describe Featurevisor::Hooks do
  describe "Hook" do
    let(:logger) { Featurevisor.create_logger(level: "warn") }

    it "should be a class" do
      expect(Featurevisor::Hooks::Hook).to be_a(Class)
    end

    it "should initialize with options" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        before: ->(opts) { opts.merge(test: true) },
        after: ->(eval, opts) { eval.merge(test: true) }
      )

      expect(hook.name).to eq("test-hook")
      expect(hook).to respond_to(:call_before)
      expect(hook).to respond_to(:call_after)
    end

    it "should call before hook when defined" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        before: ->(opts) { opts.merge(test: true) }
      )

      result = hook.call_before({ original: true })
      expect(result[:test]).to be true
      expect(result[:original]).to be true
    end

    it "should return original options when before hook is not defined" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")

      result = hook.call_before({ original: true })
      expect(result[:original]).to be true
      expect(result[:test]).to be_nil
    end

    it "should call bucket key hook when defined" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        bucket_key: ->(opts) { "modified-#{opts[:bucket_key]}" }
      )

      result = hook.call_bucket_key({ bucket_key: "original" })
      expect(result).to eq("modified-original")
    end

    it "should return original bucket key when bucket key hook is not defined" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")

      result = hook.call_bucket_key({ bucket_key: "original" })
      expect(result).to eq("original")
    end

    it "should call bucket value hook when defined" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        bucket_value: ->(opts) { opts[:bucket_value] * 2 }
      )

      result = hook.call_bucket_value({ bucket_value: 50 })
      expect(result).to eq(100)
    end

    it "should return original bucket value when bucket value hook is not defined" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")

      result = hook.call_bucket_value({ bucket_value: 50 })
      expect(result).to eq(50)
    end

    it "should call after hook when defined" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        after: ->(eval, opts) { eval.merge(test: true) }
      )

      result = hook.call_after({ original: true }, { options: true })
      expect(result[:test]).to be true
      expect(result[:original]).to be true
    end

    it "should return original evaluation when after hook is not defined" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")

      result = hook.call_after({ original: true }, { options: true })
      expect(result[:original]).to be true
      expect(result[:test]).to be_nil
    end
  end

  describe "HooksManager" do
    let(:logger) { Featurevisor.create_logger(level: "warn") }
    let(:hooks_manager) { Featurevisor::Hooks::HooksManager.new(logger: logger) }

    it "should be a class" do
      expect(Featurevisor::Hooks::HooksManager).to be_a(Class)
    end

    it "should initialize with options" do
      expect(hooks_manager.logger).to eq(logger)
      expect(hooks_manager.hooks).to eq([])
    end

    it "should add hooks" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")
      remove_fn = hooks_manager.add(hook)

      expect(hooks_manager.hooks).to include(hook)
      expect(remove_fn).to be_a(Proc)
    end

    it "should not add duplicate hooks" do
      hook1 = Featurevisor::Hooks::Hook.new(name: "test-hook")
      hook2 = Featurevisor::Hooks::Hook.new(name: "test-hook")

      hooks_manager.add(hook1)
      result = hooks_manager.add(hook2)

      expect(hooks_manager.hooks).to eq([hook1])
      expect(result).to be_nil
    end

    it "should remove hooks by name" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")
      hooks_manager.add(hook)

      hooks_manager.remove("test-hook")
      expect(hooks_manager.hooks).to be_empty
    end

    it "should get all hooks" do
      hook1 = Featurevisor::Hooks::Hook.new(name: "hook1")
      hook2 = Featurevisor::Hooks::Hook.new(name: "hook2")

      hooks_manager.add(hook1)
      hooks_manager.add(hook2)

      expect(hooks_manager.get_all).to eq([hook1, hook2])
    end

    it "should run before hooks" do
      hook1 = Featurevisor::Hooks::Hook.new(
        name: "hook1",
        before: ->(opts) { opts.merge(hook1: true) }
      )
      hook2 = Featurevisor::Hooks::Hook.new(
        name: "hook2",
        before: ->(opts) { opts.merge(hook2: true) }
      )

      hooks_manager.add(hook1)
      hooks_manager.add(hook2)

      result = hooks_manager.run_before_hooks({ original: true })
      expect(result[:hook1]).to be true
      expect(result[:hook2]).to be true
      expect(result[:original]).to be true
    end

    it "should run bucket key hooks" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        bucket_key: ->(opts) { "modified-#{opts[:bucket_key]}" }
      )

      hooks_manager.add(hook)

      result = hooks_manager.run_bucket_key_hooks({
        feature_key: "test",
        context: {},
        bucket_by: "userId",
        bucket_key: "original"
      })

      expect(result).to eq("modified-original")
    end

    it "should run bucket value hooks" do
      hook = Featurevisor::Hooks::Hook.new(
        name: "test-hook",
        bucket_value: ->(opts) { opts[:bucket_value] * 2 }
      )

      hooks_manager.add(hook)

      result = hooks_manager.run_bucket_value_hooks({
        feature_key: "test",
        bucket_key: "test.123",
        context: {},
        bucket_value: 50
      })

      expect(result).to eq(100)
    end

    it "should run after hooks" do
      hook1 = Featurevisor::Hooks::Hook.new(
        name: "hook1",
        after: ->(eval, opts) { eval.merge(hook1: true) }
      )
      hook2 = Featurevisor::Hooks::Hook.new(
        name: "hook2",
        after: ->(eval, opts) { eval.merge(hook2: true) }
      )

      hooks_manager.add(hook1)
      hooks_manager.add(hook2)

      result = hooks_manager.run_after_hooks({ original: true }, { options: true })
      expect(result[:hook1]).to be true
      expect(result[:hook2]).to be true
      expect(result[:original]).to be true
    end

    it "should initialize with existing hooks" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")
      manager = Featurevisor::Hooks::HooksManager.new(hooks: [hook], logger: logger)

      expect(manager.hooks).to include(hook)
    end

    it "should return remove function when adding hook" do
      hook = Featurevisor::Hooks::Hook.new(name: "test-hook")
      remove_fn = hooks_manager.add(hook)

      expect(remove_fn).to be_a(Proc)
      remove_fn.call
      expect(hooks_manager.hooks).to be_empty
    end
  end
end
