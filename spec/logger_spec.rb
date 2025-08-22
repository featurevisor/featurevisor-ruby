require "featurevisor"

RSpec.describe Featurevisor::Logger do
  let(:console_output) { StringIO.new }
  let(:original_stdout) { $stdout }
  let(:original_stderr) { $stderr }

  before(:each) do
    $stdout = console_output
    $stderr = console_output
  end

  after(:each) do
    $stdout = original_stdout
    $stderr = original_stderr
  end

  describe "create_logger" do
    it "should create a logger with default options" do
      logger = Featurevisor.create_logger
      expect(logger).to be_instance_of(Featurevisor::Logger)
    end

    it "should create a logger with custom level" do
      logger = Featurevisor.create_logger(level: "debug")
      expect(logger).to be_instance_of(Featurevisor::Logger)
    end

    it "should create a logger with custom handler" do
      custom_handler = double("custom_handler")
      expect(custom_handler).to receive(:call).with("info", "test message", nil)

      logger = Featurevisor.create_logger(handler: custom_handler)
      logger.info("test message")
    end
  end

  describe "Logger" do
    describe "constructor" do
      it "should use default log level when none provided" do
        logger = Featurevisor::Logger.new
        logger.debug("debug message")

        # Debug should not be logged with default level (info)
        expect(console_output.string).not_to include("debug message")
      end

      it "should use provided log level" do
        logger = Featurevisor::Logger.new(level: "debug")
        logger.debug("debug message")

        # Debug should be logged with debug level
        expect(console_output.string).to include("[Featurevisor]")
        expect(console_output.string).to include("debug message")
      end

      it "should use default handler when none provided" do
        logger = Featurevisor::Logger.new
        logger.info("test message")

        expect(console_output.string).to include("[Featurevisor]")
        expect(console_output.string).to include("test message")
      end

      it "should use provided handler" do
        custom_handler = double("custom_handler")
        expect(custom_handler).to receive(:call).with("info", "test message", nil)

        logger = Featurevisor::Logger.new(handler: custom_handler)
        logger.info("test message")
      end
    end

    describe "set_level" do
      it "should update the log level" do
        logger = Featurevisor::Logger.new(level: "info")

        # Debug should not be logged initially
        logger.debug("debug message")
        expect(console_output.string).not_to include("debug message")

        # Set to debug level
        logger.set_level("debug")
        logger.debug("debug message")
        expect(console_output.string).to include("debug message")
      end
    end

    describe "log level filtering" do
      it "should log error messages at all levels" do
        levels = %w[debug info warn error]

        levels.each do |level|
          console_output.truncate(0)
          logger = Featurevisor::Logger.new(level: level)
          logger.error("error message")
          expect(console_output.string).to include("error message")
        end
      end

      it "should log warn messages at warn level and above" do
        logger = Featurevisor::Logger.new(level: "warn")

        logger.warn("warn message")
        expect(console_output.string).to include("warn message")

        logger.error("error message")
        expect(console_output.string).to include("error message")
      end

      it "should not log info messages at warn level" do
        logger = Featurevisor::Logger.new(level: "warn")

        logger.info("info message")
        expect(console_output.string).not_to include("info message")
      end

      it "should not log debug messages at info level" do
        logger = Featurevisor::Logger.new(level: "info")

        logger.debug("debug message")
        expect(console_output.string).not_to include("debug message")
      end

      it "should log all messages at debug level" do
        logger = Featurevisor::Logger.new(level: "debug")

        logger.debug("debug message")
        expect(console_output.string).to include("debug message")

        logger.info("info message")
        expect(console_output.string).to include("info message")

        logger.warn("warn message")
        expect(console_output.string).to include("warn message")

        logger.error("error message")
        expect(console_output.string).to include("error message")
      end
    end

    describe "convenience methods" do
      let(:logger) { Featurevisor::Logger.new(level: "debug") }

      it "should call debug method correctly" do
        logger.debug("debug message")
        expect(console_output.string).to include("debug message")
      end

      it "should call info method correctly" do
        logger.info("info message")
        expect(console_output.string).to include("info message")
      end

      it "should call warn method correctly" do
        logger.warn("warn message")
        expect(console_output.string).to include("warn message")
      end

      it "should call error method correctly" do
        logger.error("error message")
        expect(console_output.string).to include("error message")
      end

      it "should call fatal method correctly" do
        logger.fatal("fatal message")
        expect(console_output.string).to include("fatal message")
      end

      it "should handle details parameter" do
        details = { key: "value", number: 42 }

        logger.info("message with details", details)
        expect(console_output.string).to include("message with details")
        expect(console_output.string).to include("key")
        expect(console_output.string).to include("value")
        expect(console_output.string).to include("42")
      end
    end

    describe "log method" do
      it "should call handler with correct parameters" do
        custom_handler = double("custom_handler")
        expect(custom_handler).to receive(:call).with("info", "test message", { test: true })

        logger = Featurevisor::Logger.new(handler: custom_handler, level: "debug")
        details = { test: true }

        logger.log("info", "test message", details)
      end

      it "should not call handler when level is filtered out" do
        custom_handler = double("custom_handler")
        expect(custom_handler).not_to receive(:call)

        logger = Featurevisor::Logger.new(handler: custom_handler, level: "warn")
        logger.log("debug", "debug message")
      end
    end
  end

  describe "default_log_handler" do
    it "should use puts for debug level" do
      Featurevisor.default_log_handler("debug", "debug message")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("debug message")
    end

    it "should use puts for info level" do
      Featurevisor.default_log_handler("info", "info message")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("info message")
    end

    it "should use warn for warn level" do
      Featurevisor.default_log_handler("warn", "warn message")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("warn message")
    end

    it "should use warn for error level" do
      Featurevisor.default_log_handler("error", "error message")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("error message")
    end

    it "should use warn for fatal level" do
      Featurevisor.default_log_handler("fatal", "fatal message")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("fatal message")
    end

    it "should handle nil details" do
      Featurevisor.default_log_handler("info", "message without details")
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("message without details")
    end

    it "should handle provided details" do
      details = { key: "value" }
      Featurevisor.default_log_handler("info", "message with details", details)
      expect(console_output.string).to include("[Featurevisor]")
      expect(console_output.string).to include("message with details")
      expect(console_output.string).to include("key")
      expect(console_output.string).to include("value")
    end
  end

  describe "constants" do
    it "should have correct log levels" do
      expect(Featurevisor::LOG_LEVELS).to eq(%w[fatal error warn info debug])
    end

    it "should have correct default log level" do
      expect(Featurevisor::DEFAULT_LOG_LEVEL).to eq("info")
    end

    it "should have correct logger prefix" do
      expect(Featurevisor::LOGGER_PREFIX).to eq("[Featurevisor]")
    end
  end
end
