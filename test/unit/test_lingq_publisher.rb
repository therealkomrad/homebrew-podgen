# frozen_string_literal: true

require_relative "../test_helper"
require "lingq_publisher"
require "regen_cache"

class TestLingQPublisher < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lingq_pub")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @uploads_path = File.join(@tmpdir, "uploads.yml")
    RegenCache.reset!
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
  end

  def test_returns_not_configured_when_lingq_disabled
    config = stub_config(lingq_enabled: false)
    publisher = build_publisher(config: config)

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    assert_equal :not_configured, result.errors.first[:type]
    assert_equal 0, result.uploaded
  end

  def test_returns_no_language_when_transcription_language_missing
    config = stub_config(lingq_enabled: true, transcription_language: nil)
    publisher = build_publisher(config: config)

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    assert_equal :no_language, result.errors.first[:type]
  end

  def test_drains_all_pending_episodes
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")
    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_123" }
    publisher = build_publisher(config: config, agent: agent)

    result = nil
    capture_io { result = publisher.run }

    assert result.success?
    assert_equal 2, result.uploaded
    assert_equal 2, agent.uploads.length
  end

  def test_per_episode_failure_continues_batch
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")
    config = stub_config(lingq_enabled: true)
    call = 0
    agent = stub_agent do |a|
      a.upload_with do |**_kw|
        call += 1
        raise "transient" if call == 1
        "lesson_#{call}"
      end
    end
    publisher = build_publisher(config: config, agent: agent)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 1, result.errors.length
    assert_equal :upload, result.errors.first[:type]
  end

  def test_dry_run_skips_uploads
    seed_ep("ep-2026-01-15")
    config = stub_config(lingq_enabled: true)
    agent = stub_agent
    publisher = build_publisher(config: config, agent: agent, options: { dry_run: true })

    capture_io { publisher.run }

    assert_empty agent.uploads
  end

  def test_records_in_upload_tracker
    seed_ep("ep-2026-01-15")
    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_xyz" }
    publisher = build_publisher(config: config, agent: agent)

    capture_io { publisher.run }

    require "yaml"
    assert File.exist?(@uploads_path)
    data = YAML.load_file(@uploads_path)
    assert_equal "lesson_xyz", data["lingq"]["mycollection"]["ep-2026-01-15"]
  end

  def test_skips_already_uploaded_episodes
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")
    require "yaml"
    File.write(@uploads_path, { "lingq" => { "mycollection" => { "ep-2026-01-15" => "old_lesson" } } }.to_yaml)

    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_new" }
    publisher = build_publisher(config: config, agent: agent)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded, "should skip ep-2026-01-15 already in tracker"
    assert_equal 1, agent.uploads.length
  end

  def test_force_reuploads_already_uploaded
    seed_ep("ep-2026-01-15")
    require "yaml"
    File.write(@uploads_path, { "lingq" => { "mycollection" => { "ep-2026-01-15" => "old_lesson" } } }.to_yaml)

    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_re" }
    publisher = build_publisher(config: config, agent: agent, options: { force: true })

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
  end

  def test_calls_regen_cache_once_per_pod
    seed_ep("ep-2026-01-15")
    config = stub_config(lingq_enabled: true)
    regen_calls = 0

    publisher = build_publisher(config: config, agent: stub_agent)
    publisher.define_singleton_method(:regenerate!) { regen_calls += 1 }
    capture_io { publisher.run }

    publisher2 = build_publisher(config: config, agent: stub_agent)
    publisher2.define_singleton_method(:regenerate!) { regen_calls += 1 }
    capture_io { publisher2.run }

    assert_equal 1, regen_calls
  end

  def test_returns_zero_uploaded_when_nothing_pending
    config = stub_config(lingq_enabled: true)
    agent = stub_agent
    publisher = build_publisher(config: config, agent: agent)

    result = nil
    capture_io { result = publisher.run }

    assert result.success?
    assert_equal 0, result.uploaded
    assert_empty agent.uploads
  end

  # Regression: --date used to be ignored on the LingQ path (same bug as
  # YouTube). Combined with --force, that re-uploaded the whole catalog.
  def test_episode_id_filters_uploads_to_matching_episode
    seed_ep("ep-2026-01-14")
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_x" }
    publisher = build_publisher(config: config, agent: agent, episode_id: "2026-01-15")

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 1, agent.uploads.length
    assert_match(/ep-2026-01-15/, agent.uploads.first[:title])
  end

  def test_episode_id_with_force_does_not_pull_in_other_episodes
    seed_ep("ep-2026-01-14")
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    require "yaml"
    File.write(@uploads_path, YAML.dump(
      "lingq" => { "mycollection" => {
        "ep-2026-01-14" => 1,
        "ep-2026-01-15" => 2,
        "ep-2026-01-16" => 3
      } }
    ))

    config = stub_config(lingq_enabled: true)
    agent = stub_agent { |a| a.upload_returns "lesson_new" }
    publisher = build_publisher(
      config: config, agent: agent,
      episode_id: "2026-01-15", options: { force: true }
    )

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 1, agent.uploads.length
    assert_match(/ep-2026-01-15/, agent.uploads.first[:title])
  end

  private

  StubLingQConfig = Struct.new(:episodes_dir, :name, :transcription_language,
    :_lingq, :base_url, keyword_init: true) do
    def initialize(episodes_dir:, name: "test_pod", transcription_language: "en",
                   _lingq: nil, base_url: "https://example.com")
      super
    end
    def lingq_enabled? = !_lingq.nil?
    def lingq_config = _lingq
    def cover_generation_enabled? = false
    def cover_static_image = nil
    def cover_base_image = nil
    def cover_options = {}
  end

  def stub_config(lingq_enabled:, transcription_language: "en")
    lq = lingq_enabled ? { collection: "mycollection", token: "k", level: 2, tags: ["t"], status: 0 } : nil
    StubLingQConfig.new(
      episodes_dir: @episodes_dir,
      name: "test_pod",
      transcription_language: transcription_language,
      _lingq: lq
    )
  end

  def seed_ep(base)
    File.write(File.join(@episodes_dir, "#{base}.mp3"), "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_transcript.md"),
               "# Title #{base}\n\nDescription.\n\n## Transcript\n\nBody text.\n")
  end

  def build_publisher(config:, agent: nil, options: {}, episode_id: nil)
    LingQPublisher.new(
      config: config,
      options: options,
      agent: agent,
      tracker_path: @uploads_path,
      episode_id: episode_id
    )
  end

  def stub_agent
    a = StubLingQAgent.new
    yield(a) if block_given?
    a
  end

  class StubLingQAgent
    attr_reader :uploads
    def initialize
      @uploads = []
      @upload_block = ->(**_kw) { "lesson_default" }
    end
    def upload_returns(id) = @upload_block = ->(**_kw) { id }
    def upload_with(&blk) = @upload_block = blk
    def upload(**kw)
      @uploads << kw
      @upload_block.call(**kw)
    end
  end
end
