# frozen_string_literal: true

require_relative "logger"

# Mixin that provides logging helpers using the injected @logger, falling
# back to the ambient PodcastAgent.logger (a NullLogger by default).
#
# `log` adds a tag derived from the class name (e.g. "[TTSAgent]"). The
# phase_start / phase_end / log_error helpers pass through unchanged.
#
# Usage:
#   class MyAgent
#     include Loggable
#     def initialize(logger: nil)
#       @logger = logger
#     end
#   end
module Loggable
  private

  def log(message)
    tag = "[#{self.class.name&.split('::')&.last || self.class.name}]"
    logger_target.log("#{tag} #{message}")
  end

  def log_error(message)
    tag = "[#{self.class.name&.split('::')&.last || self.class.name}]"
    logger_target.error("#{tag} #{message}")
  end

  def phase_start(name)
    logger_target.phase_start(name)
  end

  def phase_end(name)
    logger_target.phase_end(name)
  end

  # Times a block and returns [result, elapsed_seconds].
  #   message, elapsed = measure_time { @client.messages.create(...) }
  def measure_time
    start = Time.now
    result = yield
    elapsed = (Time.now - start).round(2)
    [result, elapsed]
  end

  def logger_target
    @logger || PodcastAgent.logger
  end
end
