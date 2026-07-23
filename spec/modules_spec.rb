require "featurevisor"

RSpec.describe Featurevisor::Modules do
  describe "Module" do
    let(:diagnostics) { Featurevisor.const_get(:DiagnosticReporter).new(level: "warn") }

    it "should be a class" do
      expect(Featurevisor::Modules::FeaturevisorModule).to be_a(Class)
    end

    it "should initialize with options" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        setup: ->(_api) {},
        before: ->(opts) { opts.merge(test: true) },
        after: ->(eval, opts) { eval.merge(test: true) },
        close: -> {}
      )

      expect(mod.name).to eq("test-mod")
      expect(mod).to respond_to(:call_setup)
      expect(mod).to respond_to(:call_before)
      expect(mod).to respond_to(:call_after)
      expect(mod).to respond_to(:call_close)
    end

    it "should call setup when defined" do
      received_api = nil
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        setup: ->(api) { received_api = api }
      )

      api = { get_revision: -> { "1" } }
      mod.call_setup(api)

      expect(received_api).to eq(api)
    end

    it "should call close when defined" do
      closed = false
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        close: -> { closed = true }
      )

      mod.call_close

      expect(closed).to be true
    end

    it "should call before mod when defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        before: ->(opts) { opts.merge(test: true) }
      )

      result = mod.call_before({ original: true })
      expect(result[:test]).to be true
      expect(result[:original]).to be true
    end

    it "should return original options when before mod is not defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")

      result = mod.call_before({ original: true })
      expect(result[:original]).to be true
      expect(result[:test]).to be_nil
    end

    it "should call bucket key mod when defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        bucket_key: ->(opts) { "modified-#{opts[:bucket_key]}" }
      )

      result = mod.call_bucket_key({ bucket_key: "original" })
      expect(result).to eq("modified-original")
    end

    it "should return original bucket key when bucket key mod is not defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")

      result = mod.call_bucket_key({ bucket_key: "original" })
      expect(result).to eq("original")
    end

    it "should call bucket value mod when defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        bucket_value: ->(opts) { opts[:bucket_value] * 2 }
      )

      result = mod.call_bucket_value({ bucket_value: 50 })
      expect(result).to eq(100)
    end

    it "should return original bucket value when bucket value mod is not defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")

      result = mod.call_bucket_value({ bucket_value: 50 })
      expect(result).to eq(50)
    end

    it "should call after mod when defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        after: ->(eval, opts) { eval.merge(test: true) }
      )

      result = mod.call_after({ original: true }, { options: true })
      expect(result[:test]).to be true
      expect(result[:original]).to be true
    end

    it "should return original evaluation when after mod is not defined" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")

      result = mod.call_after({ original: true }, { options: true })
      expect(result[:original]).to be true
      expect(result[:test]).to be_nil
    end
  end

  describe "ModulesManager" do
    let(:diagnostics) { Featurevisor.const_get(:DiagnosticReporter).new(level: "warn") }
    let(:diagnostics) { [] }
    let(:modules_manager) do
      Featurevisor::Modules::ModulesManager.new(
        diagnostics: diagnostics,
        report_diagnostic: ->(diagnostic, _mod = nil) { diagnostics << diagnostic }
      )
    end

    it "should be a class" do
      expect(Featurevisor::Modules::ModulesManager).to be_a(Class)
    end

    it "should initialize with options" do
      expect(modules_manager.modules).to eq([])
    end

    it "should add modules" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")
      remove_fn = modules_manager.add(mod)

      expect(modules_manager.modules).to include(mod)
      expect(remove_fn).to be_a(Proc)
    end

    it "should not add duplicate modules" do
      module1 = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")
      module2 = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")

      modules_manager.add(module1)
      result = modules_manager.add(module2)

      expect(modules_manager.modules).to eq([module1])
      expect(result).to be_nil
      expect(diagnostics.last).to include(
        level: "error",
        code: "duplicate_module",
        module_name: "test-mod"
      )
    end

    it "should isolate setup failures and close the failed module" do
      closed = false
      subscriptions_cleared = false
      manager = Featurevisor::Modules::ModulesManager.new(
        report_diagnostic: ->(diagnostic, _mod = nil) { diagnostics << diagnostic },
        module_api_factory: ->(_mod) { {} },
        clear_module_diagnostic_subscriptions: ->(_mod) { subscriptions_cleared = true }
      )
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "broken-setup",
        setup: ->(_api) { raise "setup failed" },
        close: -> { closed = true }
      )

      expect(manager.add(mod)).to be_nil
      expect(manager.modules).to be_empty
      expect(closed).to be true
      expect(subscriptions_cleared).to be true
      expect(diagnostics.last).to include(code: "module_setup_error", module_name: "broken-setup")
    end

    it "should remove modules by name" do
      closed = false
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod", close: -> { closed = true })
      modules_manager.add(mod)

      modules_manager.remove("test-mod")
      expect(modules_manager.modules).to be_empty
      expect(closed).to be true
    end

    it "should get all modules" do
      module1 = Featurevisor::Modules::FeaturevisorModule.new(name: "module1")
      module2 = Featurevisor::Modules::FeaturevisorModule.new(name: "module2")

      modules_manager.add(module1)
      modules_manager.add(module2)

      expect(modules_manager.get_all).to eq([module1, module2])
    end

    it "should run before modules" do
      module1 = Featurevisor::Modules::FeaturevisorModule.new(
        name: "module1",
        before: ->(opts) { opts.merge(module1: true) }
      )
      module2 = Featurevisor::Modules::FeaturevisorModule.new(
        name: "module2",
        before: ->(opts) { opts.merge(module2: true) }
      )

      modules_manager.add(module1)
      modules_manager.add(module2)

      result = modules_manager.run_before_modules({ original: true })
      expect(result[:module1]).to be true
      expect(result[:module2]).to be true
      expect(result[:original]).to be true
    end

    it "should run bucket key modules" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        bucket_key: ->(opts) { "modified-#{opts[:bucket_key]}" }
      )

      modules_manager.add(mod)

      result = modules_manager.run_bucket_key_modules({
        feature_key: "test",
        context: {},
        bucket_by: "userId",
        bucket_key: "original"
      })

      expect(result).to eq("modified-original")
    end

    it "should run bucket value modules" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(
        name: "test-mod",
        bucket_value: ->(opts) { opts[:bucket_value] * 2 }
      )

      modules_manager.add(mod)

      result = modules_manager.run_bucket_value_modules({
        feature_key: "test",
        bucket_key: "test.123",
        context: {},
        bucket_value: 50
      })

      expect(result).to eq(100)
    end

    it "should run after modules" do
      module1 = Featurevisor::Modules::FeaturevisorModule.new(
        name: "module1",
        after: ->(eval, opts) { eval.merge(module1: true) }
      )
      module2 = Featurevisor::Modules::FeaturevisorModule.new(
        name: "module2",
        after: ->(eval, opts) { eval.merge(module2: true) }
      )

      modules_manager.add(module1)
      modules_manager.add(module2)

      result = modules_manager.run_after_modules({ original: true }, { options: true })
      expect(result[:module1]).to be true
      expect(result[:module2]).to be true
      expect(result[:original]).to be true
    end

    it "should initialize with existing modules" do
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod")
      manager = Featurevisor::Modules::ModulesManager.new(modules: [mod], diagnostics: diagnostics)

      expect(manager.modules).to include(mod)
    end

    it "should return remove function when adding mod" do
      closed = []
      mod = Featurevisor::Modules::FeaturevisorModule.new(name: "test-mod", close: -> { closed << "test-mod" })
      remove_fn = modules_manager.add(mod)

      expect(remove_fn).to be_a(Proc)
      remove_fn.call
      remove_fn.call
      expect(modules_manager.modules).to be_empty
      expect(closed).to eq(["test-mod"])
    end

    it "should close all modules" do
      closed = []
      module1 = Featurevisor::Modules::FeaturevisorModule.new(name: "module1", close: -> { closed << "module1" })
      module2 = Featurevisor::Modules::FeaturevisorModule.new(name: "module2", close: -> { closed << "module2" })

      modules_manager.add(module1)
      modules_manager.add(module2)
      modules_manager.close_all

      expect(closed).to eq(%w[module1 module2])
      expect(modules_manager.modules).to be_empty
    end
  end
end
