# frozen_string_literal: true

module Featurevisor
  # Log levels for the logger
  LOG_LEVELS = %w[fatal error warn info debug].freeze
  DEFAULT_LOG_LEVEL = "info".freeze
  LOGGER_PREFIX = "[Featurevisor]".freeze

  # Logger class for handling different log levels
  class Logger
    attr_reader :level, :handler

    # Initialize a new logger
    # @param options [Hash] Logger options
    # @option options [String] :level Log level (default: "info")
    # @option options [Proc] :handler Custom log handler (default: default_log_handler)
    def initialize(options = {})
      @level = options[:level] || DEFAULT_LOG_LEVEL
      @handler = options[:handler] || method(:default_log_handler)
    end

    # Set the log level
    # @param level [String] New log level
    def set_level(level)
      @level = level
    end

    # Log a message at a specific level
    # @param level [String] Log level
    # @param message [String] Log message
    # @param details [Hash, nil] Additional details
    def log(level, message, details = nil)
      return unless should_handle?(level)

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

    # Check if the current level should handle the given log level
    # @param log_level [String] Log level to check
    # @return [Boolean] True if should handle
    def should_handle?(log_level)
      current_index = LOG_LEVELS.index(@level)
      target_index = LOG_LEVELS.index(log_level)

      return false if current_index.nil? || target_index.nil?

      current_index >= target_index
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
          Kernel.puts("#{LOGGER_PREFIX} #{message} #{details.inspect}")
        else
          Kernel.puts("#{LOGGER_PREFIX} #{message}")
        end
      when "warn"
        if details && !details.empty?
          Kernel.warn("#{LOGGER_PREFIX} #{message} #{details.inspect}")
        else
          Kernel.warn("#{LOGGER_PREFIX} #{message}")
        end
      end
    end
  end

  # Create a new logger instance
  # @param options [Hash] Logger options
  # @return [Logger] New logger instance
  def self.create_logger(options = {})
    Logger.new(options)
  end

  # Default log handler function
  # @param level [String] Log level
  # @param message [String] Log message
  # @param details [Hash, nil] Additional details
  def self.default_log_handler(level, message, details = nil)
    method_name = case level
                 when "info" then "puts"
                 when "warn" then "warn"
                 when "error", "fatal" then "warn"
                 else "puts"
                 end

    case method_name
    when "puts"
      if details && !details.empty?
        Kernel.puts("#{LOGGER_PREFIX} #{message} #{details.inspect}")
      else
        Kernel.puts("#{LOGGER_PREFIX} #{message}")
      end
    when "warn"
      if details && !details.empty?
        Kernel.warn("#{LOGGER_PREFIX} #{message} #{details.inspect}")
      else
        Kernel.warn("#{LOGGER_PREFIX} #{message}")
      end
    end
  end
end
