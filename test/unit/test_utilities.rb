# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Tests for utility classes/modules that previously lacked coverage:
# PodcastAgent::Logger, Loggable, LANGUAGE_NAMES.
class TestUtilities < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_util_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    Object.send(:remove_const, :TestLoggableWidget) if defined?(TestLoggableWidget)
  end

  # --- LANGUAGE_NAMES ---

  def test_language_names_frozen
    require "language_names"
    assert LANGUAGE_NAMES.frozen?
  end

  def test_language_names_has_common_codes
    require "language_names"
    { "en" => "English", "es" => "Spanish", "ja" => "Japanese",
      "de" => "German", "sl" => "Slovenian" }.each do |code, name|
      assert_equal name, LANGUAGE_NAMES[code], "Expected #{code} => #{name}"
    end
  end

  def test_language_names_all_two_letter_codes
    require "language_names"
    LANGUAGE_NAMES.each_key do |code|
      assert_match(/\A[a-z]{2}\z/, code, "#{code} is not a 2-letter ISO code")
    end
  end

  # --- PodcastAgent::Logger ---

  def test_logger_custom_path
    require "logger"
    log_path = File.join(@tmpdir, "custom.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    assert_equal log_path, logger.log_file_path
  end

  def test_logger_creates_parent_directory
    require "logger"
    log_path = File.join(@tmpdir, "deep", "nested", "test.log")
    PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    assert Dir.exist?(File.join(@tmpdir, "deep", "nested"))
  end

  def test_logger_log_writes_to_file
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.log("hello world")

    content = File.read(log_path)
    assert_includes content, "hello world"
    assert_match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/, content)
  end

  def test_logger_log_quiet_suppresses_stdout
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    out, = capture_io { logger.log("hidden") }
    assert_empty out
  end

  def test_logger_log_normal_shows_stdout
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :normal)

    out, = capture_io { logger.log("visible") }
    assert_includes out, "visible"
  end

  def test_logger_error_writes_to_stderr_and_file
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    _, err = capture_io { logger.error("something broke") }

    assert_includes err, "ERROR something broke"
    assert_includes File.read(log_path), "ERROR something broke"
  end

  def test_logger_phase_tracking
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.phase_start("TTS")
    logger.phase_end("TTS")

    content = File.read(log_path)
    assert_includes content, "START TTS"
    assert_match(/END TTS \(\d+\.\d+s\)/, content)
  end

  def test_logger_phase_end_without_start
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :quiet)

    logger.phase_end("Unknown")

    content = File.read(log_path)
    assert_includes content, "END Unknown (0s)"
  end

  def test_logger_verbose_shows_stdout
    require "logger"
    log_path = File.join(@tmpdir, "test.log")
    logger = PodcastAgent::Logger.new(log_path: log_path, verbosity: :verbose)

    out, = capture_io { logger.log("verbose msg") }
    assert_includes out, "verbose msg"
  end

  def test_logger_default_path_without_log_path
    require "logger"
    logger = PodcastAgent::Logger.new(verbosity: :quiet)

    assert_match(%r{logs/runs/\d{4}-\d{2}-\d{2}\.log$}, logger.log_file_path)
  end

  # --- Loggable ---

  def test_loggable_with_logger
    require "loggable"

    mock_logger = Minitest::Mock.new
    mock_logger.expect(:log, nil, [String])

    obj = Class.new { include Loggable }.new
    obj.instance_variable_set(:@logger, mock_logger)
    obj.send(:log, "test message")

    mock_logger.verify
  end

  def test_loggable_tag_from_class_name
    require "loggable"

    received = nil
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received = msg }

    klass = Class.new { include Loggable }
    # Give it a name by assigning to a constant
    Object.const_set(:TestLoggableWidget, klass) unless defined?(TestLoggableWidget)
    obj = TestLoggableWidget.new
    obj.instance_variable_set(:@logger, logger_stub)
    obj.send(:log, "hello")

    assert_match(/\[TestLoggableWidget\] hello/, received)
  end

  def test_loggable_nested_class_uses_last_part
    require "loggable"

    received = nil
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received = msg }

    mod = Module.new
    klass = Class.new { include Loggable }
    mod.const_set(:InnerClass, klass)

    obj = mod::InnerClass.new
    obj.instance_variable_set(:@logger, logger_stub)
    obj.send(:log, "nested")

    assert_includes received, "[InnerClass]"
  end

  def test_loggable_anonymous_class_does_not_raise
    require "loggable"

    obj = Class.new { include Loggable }.new
    # With no @logger and ambient defaulted to NullLogger, this is silent
    # but must not raise.
    capture_io { obj.send(:log, "anon test") }
  end

  def test_loggable_without_logger_falls_back_to_ambient
    require "loggable"

    received = nil
    ambient = Object.new
    ambient.define_singleton_method(:log) { |msg| received = msg }

    obj = Class.new { include Loggable }.new
    PodcastAgent.with_logger(ambient) do
      obj.send(:log, "fallback")
    end

    assert_includes received, "fallback"
  end

  def test_loggable_default_ambient_is_silent
    require "loggable"

    prev = PodcastAgent.logger
    PodcastAgent.logger = nil # reset to default NullLogger
    obj = Class.new { include Loggable }.new
    out, err = capture_io { obj.send(:log, "should be silent") }
    assert_empty out
    assert_empty err
  ensure
    PodcastAgent.logger = prev
  end

  def test_loggable_phase_start_and_end_delegate_to_logger
    require "loggable"

    starts = []
    ends = []
    logger = Object.new
    logger.define_singleton_method(:phase_start) { |n| starts << n }
    logger.define_singleton_method(:phase_end) { |n| ends << n }

    obj = Class.new { include Loggable }.new
    obj.instance_variable_set(:@logger, logger)
    obj.send(:phase_start, "Work")
    obj.send(:phase_end, "Work")

    assert_equal ["Work"], starts
    assert_equal ["Work"], ends
  end

  def test_loggable_log_error_delegates_to_logger_error
    require "loggable"

    errors = []
    logger = Object.new
    logger.define_singleton_method(:error) { |m| errors << m }

    obj = Class.new { include Loggable }.new
    obj.instance_variable_set(:@logger, logger)
    obj.send(:log_error, "boom")

    assert_equal 1, errors.size
    assert_includes errors.first, "boom"
  end

  # --- Loggable#measure_time ---

  def test_measure_time_returns_result_and_elapsed
    require "loggable"

    obj = Class.new { include Loggable }.new
    result, elapsed = obj.send(:measure_time) { 42 }

    assert_equal 42, result
    assert_kind_of Float, elapsed
    assert elapsed >= 0
  end

  def test_measure_time_measures_elapsed
    require "loggable"

    obj = Class.new { include Loggable }.new
    _, elapsed = obj.send(:measure_time) { sleep(0.05) }

    assert elapsed >= 0.04, "Expected elapsed >= 0.04, got #{elapsed}"
  end

  # --- AnthropicClient ---

  def test_anthropic_client_sets_client_and_model
    require "anthropic_client"
    ENV["ANTHROPIC_API_KEY"] ||= "test-key"

    klass = Class.new { include AnthropicClient }
    obj = klass.new
    obj.send(:init_anthropic_client)

    assert_kind_of Anthropic::Client, obj.instance_variable_get(:@client)
    assert_equal ENV.fetch("CLAUDE_MODEL", "claude-opus-4-7"), obj.instance_variable_get(:@model)
  end

  def test_anthropic_client_custom_env_key
    require "anthropic_client"
    ENV["ANTHROPIC_API_KEY"] ||= "test-key"

    klass = Class.new { include AnthropicClient }
    obj = klass.new
    obj.send(:init_anthropic_client, env_key: "CLAUDE_WEB_MODEL", default_model: "claude-haiku-4-5-20251001")

    expected = ENV.fetch("CLAUDE_WEB_MODEL", "claude-haiku-4-5-20251001")
    assert_equal expected, obj.instance_variable_get(:@model)
  end

  # --- UsageLogger ---

  def test_usage_logger_logs_token_counts
    require "loggable"
    require "usage_logger"

    received = []
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received << msg }

    klass = Class.new do
      include Loggable
      include UsageLogger
    end
    obj = klass.new
    obj.instance_variable_set(:@logger, logger_stub)

    usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
      .new(500, 100, 0, 0)
    message = Struct.new(:usage, :stop_reason).new(usage, "end_turn")

    obj.send(:log_api_usage, "Test completed", message, 1.23)

    assert received.any? { |l| l.include?("Test completed in 1.23s") }
    assert received.any? { |l| l.include?("Input: 500") && l.include?("Output: 100") }
    refute received.any? { |l| l.include?("Cache") }
  end

  def test_usage_logger_includes_stop_reason
    require "loggable"
    require "usage_logger"

    received = []
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received << msg }

    klass = Class.new do
      include Loggable
      include UsageLogger
    end
    obj = klass.new
    obj.instance_variable_set(:@logger, logger_stub)

    usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
      .new(100, 50, 0, 0)
    message = Struct.new(:usage, :stop_reason).new(usage, "max_tokens")

    obj.send(:log_api_usage, "Truncated", message, 2.0)

    assert received.any? { |l| l.include?("max_tokens") }
  end

  def test_usage_logger_logs_cache_when_present
    require "loggable"
    require "usage_logger"

    received = []
    logger_stub = Object.new
    logger_stub.define_singleton_method(:log) { |msg| received << msg }

    klass = Class.new do
      include Loggable
      include UsageLogger
    end
    obj = klass.new
    obj.instance_variable_set(:@logger, logger_stub)

    usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
      .new(500, 100, 200, 300)
    message = Struct.new(:usage, :stop_reason).new(usage, "end_turn")

    obj.send(:log_api_usage, "Cached call", message, 0.5)

    assert received.any? { |l| l.include?("Cache create: 200") && l.include?("Cache read: 300") }
  end
end
