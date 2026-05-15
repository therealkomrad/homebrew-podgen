# frozen_string_literal: true

require_relative "../test_helper"
require "logger"

# Ambient logger: PodcastAgent.logger / .logger= / .with_logger,
# plus NullLogger and thread-safe file writes in PodcastAgent::Logger#log.
class TestAmbientLogger < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("ambient_logger_test")
    @log_path = File.join(@tmpdir, "test.log")
    @prev_logger = PodcastAgent.logger
  end

  def teardown
    PodcastAgent.logger = @prev_logger
    FileUtils.rm_rf(@tmpdir)
  end

  # --- default ---

  def test_default_logger_is_null_logger
    PodcastAgent.logger = nil # force fresh default
    output = capture_io { PodcastAgent.logger.log("nobody listens") }
    assert_empty output.first
    assert_empty output.last
    assert_kind_of PodcastAgent::NullLogger, PodcastAgent.logger
  end

  def test_null_logger_responds_to_full_interface
    null = PodcastAgent::NullLogger.new
    # Must accept the same calls as PodcastAgent::Logger without raising.
    null.log("x")
    null.error("x")
    null.phase_start("x")
    null.phase_end("x")
    assert_nil null.log_file_path
  end

  # --- assignment ---

  def test_logger_assignment_round_trips
    logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    PodcastAgent.logger = logger
    assert_same logger, PodcastAgent.logger
  end

  def test_assignment_is_thread_safe
    PodcastAgent.logger = nil
    loggers = 8.times.map { PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet) }
    threads = loggers.map { |l| Thread.new { 100.times { PodcastAgent.logger = l } } }
    threads.each(&:join)
    # Final value must be one of the assigned loggers (no torn state, no nil).
    assert_includes loggers, PodcastAgent.logger
  end

  # --- with_logger (scoped override) ---

  def test_with_logger_sets_inside_block_and_restores_after
    outer = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    inner = PodcastAgent::Logger.new(log_path: File.join(@tmpdir, "inner.log"), verbosity: :quiet)
    PodcastAgent.logger = outer

    PodcastAgent.with_logger(inner) do
      assert_same inner, PodcastAgent.logger
    end
    assert_same outer, PodcastAgent.logger
  end

  def test_with_logger_restores_on_exception
    outer = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    inner = PodcastAgent::Logger.new(log_path: File.join(@tmpdir, "inner.log"), verbosity: :quiet)
    PodcastAgent.logger = outer

    assert_raises(RuntimeError) do
      PodcastAgent.with_logger(inner) { raise "boom" }
    end
    assert_same outer, PodcastAgent.logger
  end

  def test_with_logger_returns_block_value
    inner = PodcastAgent::NullLogger.new
    result = PodcastAgent.with_logger(inner) { 42 }
    assert_equal 42, result
  end

  def test_with_logger_isolates_across_threads
    PodcastAgent.logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    a = PodcastAgent::Logger.new(log_path: File.join(@tmpdir, "a.log"), verbosity: :quiet)
    b = PodcastAgent::Logger.new(log_path: File.join(@tmpdir, "b.log"), verbosity: :quiet)

    seen_a = nil
    seen_b = nil
    barrier = Queue.new

    ta = Thread.new do
      PodcastAgent.with_logger(a) do
        barrier.pop # wait for tb to also be inside its block
        seen_a = PodcastAgent.logger
      end
    end
    tb = Thread.new do
      PodcastAgent.with_logger(b) do
        barrier << :ready_b
        sleep 0.02
        seen_b = PodcastAgent.logger
      end
    end
    tb.join
    ta.join

    assert_same a, seen_a
    assert_same b, seen_b
  end

  # --- thread-safe file writes ---

  def test_concurrent_log_writes_do_not_interleave
    logger = PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet)
    threads_count = 8
    per_thread = 50
    capture_io do
      threads = threads_count.times.map do |t|
        Thread.new do
          per_thread.times { |i| logger.log("thread=#{t} i=#{i}") }
        end
      end
      threads.each(&:join)
    end

    lines = File.readlines(@log_path)
    assert_equal threads_count * per_thread, lines.size
    # Every line must be a single intact entry: timestamp prefix + thread=X i=Y.
    lines.each do |line|
      assert_match(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] thread=\d+ i=\d+\n\z/, line,
                   "Interleaved or malformed line: #{line.inspect}")
    end
  end
end
