# frozen_string_literal: true

require "fileutils"
require "time"

module PodcastAgent
  # Ambient logger accessors. Reads are lock-free atomic-ref reads;
  # writes are mutex-guarded so concurrent assignment can't tear state.
  # Per-context overrides go through `with_logger`, which uses fiber-local
  # storage so tests / parallel runs don't bleed loggers across contexts.
  AMBIENT_KEY = :__podcast_agent_logger__
  AMBIENT_MUTEX = Mutex.new
  @ambient_logger = nil

  class << self
    def logger
      Fiber[AMBIENT_KEY] || @ambient_logger || (self.logger = NullLogger.new)
    end

    def logger=(value)
      AMBIENT_MUTEX.synchronize { @ambient_logger = value }
    end

    def with_logger(scoped)
      previous = Fiber[AMBIENT_KEY]
      Fiber[AMBIENT_KEY] = scoped
      yield
    ensure
      Fiber[AMBIENT_KEY] = previous
    end
  end

  # No-op logger. Used as the default ambient logger so callers never have
  # to nil-check, and so logging is silent by default in libraries / tests
  # that haven't bootstrapped a real logger.
  class NullLogger
    def log(_message); end
    def error(_message); end
    def phase_start(_name); end
    def phase_end(_name); end
    def log_file_path; nil; end
  end

  class Logger
    # File writes are serialized across threads/fibers — concurrent log()
    # calls would otherwise interleave entries mid-line.
    FILE_MUTEX = Mutex.new

    # verbosity: :normal (default), :verbose, or :quiet
    # File logging always writes full detail regardless of verbosity.
    # Terminal output is gated: :quiet suppresses stdout, :verbose is same as :normal (for future use).
    def initialize(log_path: nil, verbosity: :normal)
      if log_path
        @log_file = log_path
        FileUtils.mkdir_p(File.dirname(@log_file))
      else
        root = File.expand_path("../..", __dir__)
        log_dir = File.join(root, "logs", "runs")
        FileUtils.mkdir_p(log_dir)
        @log_file = File.join(log_dir, "#{Date.today.strftime('%Y-%m-%d')}.log")
      end
      @verbosity = verbosity
      @start_times = {}
    end

    def log(message)
      entry = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}"
      puts entry unless @verbosity == :quiet
      FILE_MUTEX.synchronize { File.open(@log_file, "a") { |f| f.puts(entry) } }
    end

    def phase_start(name)
      @start_times[name] = Time.now
      log("START #{name}")
    end

    def phase_end(name)
      elapsed = if @start_times[name]
        Time.now - @start_times[name]
      else
        0
      end
      log("END #{name} (#{elapsed.round(2)}s)")
    end

    def error(message)
      entry = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] ERROR #{message}"
      $stderr.puts entry
      FILE_MUTEX.synchronize { File.open(@log_file, "a") { |f| f.puts(entry) } }
    end

    def log_file_path
      @log_file
    end
  end
end
