# frozen_string_literal: true

module Featurevisor
  # Diagnostic severity levels
  LOG_LEVELS = %w[fatal error warn info debug].freeze
  DEFAULT_LOG_LEVEL = "info".freeze
  DIAGNOSTIC_PREFIX = "[Featurevisor]".freeze

  # Private evaluator adapter for structured diagnostics.
  class DiagnosticReporter
    attr_reader :level, :handler

    # Initialize a diagnostic reporter.
    # @param options [Hash] Reporter options
    # @option options [String] :level Log level (default: "info")
    # @option options [Proc] :handler Internal structured diagnostic sink
    def initialize(options = {})
      @level = options[:level] || DEFAULT_LOG_LEVEL
      @filter = !options.key?(:handler)
      @handler = options[:handler] || method(:default_log_handler)
    end

    # Set the log level
    # @param level [String] New log level
    def set_level(level)
      @level = level
    end

    # Forward an evaluator diagnostic. Filtering is performed centrally by
    # Instance so module subscriptions and error events remain independent.
    # @param level [String] Diagnostic level
    # @param message [String] Diagnostic message
    # @param details [Hash, nil] Additional details
    def log(level, message, details = nil)
      return if @filter && !should_handle?(level)

      @handler.call(level, message, details)
    end

    # Log a debug message
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def debug(message, details = nil)
      log("debug", message, details)
    end

    # Log an info message
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def info(message, details = nil)
      log("info", message, details)
    end

    # Log a warning message
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def warn(message, details = nil)
      log("warn", message, details)
    end

    # Log an error message
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def error(message, details = nil)
      log("error", message, details)
    end

    # Log a fatal message
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def fatal(message, details = nil)
      log("fatal", message, details)
    end

    private

    def should_handle?(level)
      LOG_LEVELS.index(level).to_i <= LOG_LEVELS.index(@level).to_i
    end

    # Default log handler that outputs to console
    # @param level [String] Log level
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def default_log_handler(level, message, details = nil)
      method_name = case level
                   when "info" then "puts"
                   when "warn" then "warn"
                   when "error", "fatal" then "warn"
                   else "puts"
                   end

      case method_name
      when "puts"
        if details && !details.empty?
          Kernel.puts("#{DIAGNOSTIC_PREFIX} #{message} #{details.inspect}")
        else
          Kernel.puts("#{DIAGNOSTIC_PREFIX} #{message}")
        end
      when "warn"
        if details && !details.empty?
          Kernel.warn("#{DIAGNOSTIC_PREFIX} #{message} #{details.inspect}")
        else
          Kernel.warn("#{DIAGNOSTIC_PREFIX} #{message}")
        end
      end
    end
  end

end
