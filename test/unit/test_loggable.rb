# frozen_string_literal: true

require_relative "../test_helper"
require "loggable"

class TestLoggable < Minitest::Test
  class DummyAgent
    include Loggable
    public :log, :measure_time

    def initialize(logger: nil)
      @logger = logger
    end
  end

  class Nested
    class InnerAgent
      include Loggable
      public :log

      def initialize(logger: nil)
        @logger = logger
      end
    end
  end

  # --- measure_time ---

  def test_measure_time_returns_result_and_elapsed
    agent = DummyAgent.new
    result, elapsed = agent.measure_time { 42 }

    assert_equal 42, result
    assert_kind_of Float, elapsed
    assert elapsed >= 0
  end

  def test_measure_time_elapsed_reflects_duration
    agent = DummyAgent.new
    _, elapsed = agent.measure_time { sleep 0.05 }

    assert elapsed >= 0.04, "Expected elapsed >= 0.04, got #{elapsed}"
    assert elapsed < 1.0, "Expected elapsed < 1.0, got #{elapsed}"
  end

  def test_measure_time_propagates_block_return_value
    agent = DummyAgent.new
    result, _ = agent.measure_time { "hello" }

    assert_equal "hello", result
  end

  # --- log ---

  def test_log_with_logger_delegates_with_tag
    messages = []
    logger = Object.new
    logger.define_singleton_method(:log) { |msg| messages << msg }

    agent = DummyAgent.new(logger: logger)
    agent.log("test message")

    assert_equal 1, messages.length
    assert_equal "[DummyAgent] test message", messages.first
  end

  def test_log_uses_last_part_of_nested_class_name
    messages = []
    logger = Object.new
    logger.define_singleton_method(:log) { |msg| messages << msg }

    agent = Nested::InnerAgent.new(logger: logger)
    agent.log("nested")

    assert_includes messages.first, "[InnerAgent]"
  end

  def test_log_without_logger_falls_back_to_ambient
    received = nil
    ambient = Object.new
    ambient.define_singleton_method(:log) { |msg| received = msg }

    agent = DummyAgent.new
    PodcastAgent.with_logger(ambient) { agent.log("ambient test") }

    assert_equal "[DummyAgent] ambient test", received
  end

  def test_log_with_default_ambient_is_silent
    prev = PodcastAgent.logger
    PodcastAgent.logger = nil # reset to default NullLogger
    agent = DummyAgent.new
    out, err = capture_io { agent.log("should be silent") }
    assert_empty out
    assert_empty err
  ensure
    PodcastAgent.logger = prev
  end
end
