# frozen_string_literal: true

require_relative "../test_helper"
require "youtube_publisher"
require "regen_cache"
require "google/apis/errors"

class TestYouTubePublisher < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_yt_pub")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @uploads_path = File.join(@tmpdir, "uploads.yml")
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  def test_returns_zero_when_youtube_not_configured
    config = stub_config(youtube_enabled: false)
    publisher = build_publisher(config: config)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 0, result.uploaded
    assert_equal 0, result.attempted
    refute result.rate_limited
    refute_empty result.errors
    assert_equal :not_configured, result.errors.first[:type]
  end

  def test_returns_empty_result_when_nothing_pending
    config = stub_config(youtube_enabled: true)
    publisher = build_publisher(config: config)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 0, result.uploaded
    assert_equal 0, result.attempted
    refute result.rate_limited
    assert_empty result.errors
  end

  def test_uploads_pending_episodes_returns_count
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader { |b| b.upload_video_returns "vid_1" }
    publisher = build_publisher(config: config, uploader: uploader)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 2, result.uploaded
    assert_equal 2, result.attempted
    refute result.rate_limited
    assert_empty result.errors
  end

  def test_max_caps_uploads
    %w[ep-2026-01-15 ep-2026-01-16 ep-2026-01-17].each { |b| seed_ep(b) }

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader
    publisher = build_publisher(config: config, uploader: uploader, options: { max: 1 })

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 1, uploader.uploads.length
  end

  def test_quota_exceeded_sets_rate_limited_and_breaks
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader do |b|
      b.upload_video_raises Google::Apis::ClientError.new("quotaExceeded: daily limit hit")
    end
    publisher = build_publisher(config: config, uploader: uploader)

    result = nil
    capture_io { result = publisher.run }

    assert result.rate_limited
    assert_equal 0, result.uploaded
    assert_equal 1, result.attempted, "should stop after first rate-limited attempt"
  end

  def test_upload_limit_exceeded_sets_rate_limited
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader do |b|
      b.upload_video_raises Google::Apis::ClientError.new("uploadLimitExceeded")
    end
    publisher = build_publisher(config: config, uploader: uploader)

    result = nil
    capture_io { result = publisher.run }

    assert result.rate_limited
  end

  def test_per_episode_failure_does_not_halt_batch
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    config = stub_config(youtube_enabled: true)
    call = 0
    uploader = stub_uploader do |b|
      b.upload_video_with do |*_args, **_kw|
        call += 1
        raise StandardError, "transient" if call == 1
        "vid_#{call}"
      end
    end
    publisher = build_publisher(config: config, uploader: uploader)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 2, result.attempted
    refute result.rate_limited
    assert_equal 1, result.errors.length
  end

  def test_playlist_verification_failure_returns_error_no_uploads
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true, playlist: "PLbad")
    uploader = stub_uploader { |b| b.verify_playlist_raises "Playlist not found" }
    publisher = build_publisher(config: config, uploader: uploader)

    result = nil
    capture_io { result = publisher.run }

    assert_equal 0, result.uploaded
    refute_empty result.errors
    assert_equal :playlist_verification, result.errors.first[:type]
    assert_empty uploader.uploads
  end

  def test_calls_regen_cache_so_block_runs_once_per_pod
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true)
    regen_block_calls = 0
    publisher = build_publisher(config: config, uploader: stub_uploader)
    publisher.define_singleton_method(:regenerate!) { regen_block_calls += 1 }

    capture_io { publisher.run }
    capture_io { build_publisher(config: config, uploader: stub_uploader).tap { |p| p.define_singleton_method(:regenerate!) { regen_block_calls += 1 } }.run }

    assert_equal 1, regen_block_calls,
      "regen block should run once across multiple publisher instances for the same pod (in-process memo)"
  end

  def test_regen_runs_again_for_different_pod
    seed_ep("ep-2026-01-15")
    cfg_a = stub_config(youtube_enabled: true)
    cfg_b = stub_config(youtube_enabled: true)
    cfg_b.name = "other_pod"

    calls = []
    [cfg_a, cfg_b].each do |cfg|
      pub = build_publisher(config: cfg, uploader: stub_uploader)
      pub.define_singleton_method(:regenerate!) { calls << cfg.name }
      capture_io { pub.run }
    end

    assert_equal %w[test_pod other_pod], calls
  end

  def test_verify_playlist_cached_across_publisher_instances
    # Regression: round-robin creates a fresh YouTubePublisher per upload.
    # Without caching, verify_playlist! would hit YouTube's API N×M times
    # per tick (N pods × M pending eps per pod) instead of once per pod.
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true, playlist: "PLcacheme")

    verify_calls = 0
    make_uploader = lambda do
      u = StubUploader.new
      u.singleton_class.send(:define_method, :verify_playlist!) { |_| verify_calls += 1 }
      u
    end

    3.times do
      publisher = build_publisher(config: config, uploader: make_uploader.call)
      capture_io { publisher.run }
    end

    assert_equal 1, verify_calls,
      "verify_playlist! should run once per (pod, playlist) per process, not once per publisher"
  end

  def test_verify_playlist_cache_segregated_by_pod
    seed_ep("ep-2026-01-15")
    cfg_a = stub_config(youtube_enabled: true, playlist: "PLshared")
    cfg_b = stub_config(youtube_enabled: true, playlist: "PLshared")
    cfg_b.name = "other_pod"

    verify_keys = []
    [cfg_a, cfg_b].each do |cfg|
      u = StubUploader.new
      u.singleton_class.send(:define_method, :verify_playlist!) { |id| verify_keys << "#{cfg.name}:#{id}" }
      # force: true bypasses the upload tracker so both runs reach verify_playlist
      capture_io { build_publisher(config: cfg, uploader: u, options: { force: true }).run }
    end

    assert_equal 2, verify_keys.length,
      "different pods sharing the same playlist id should each verify once"
  end

  def test_dry_run_skips_uploads
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader
    publisher = build_publisher(config: config, uploader: uploader, options: { dry_run: true })

    result = nil
    capture_io { result = publisher.run }

    assert_equal 0, result.uploaded
    assert_empty uploader.uploads
  end

  def test_records_in_upload_tracker
    seed_ep("ep-2026-01-15")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader { |b| b.upload_video_returns "vid_xyz" }
    publisher = build_publisher(config: config, uploader: uploader)

    capture_io { publisher.run }

    require "yaml"
    assert File.exist?(@uploads_path), "should persist tracker to #{@uploads_path}"
    data = YAML.load_file(@uploads_path)
    assert data["youtube"]["default"]["ep-2026-01-15"]
  end

  # Regression: `publish --youtube --date X` used to upload every episode
  # because YouTubePublisher consumed its own scan_episodes which never
  # honored the date filter. Combined with --force, that re-uploaded the
  # entire back-catalog.
  def test_episode_id_filters_uploads_to_matching_episode
    seed_ep("ep-2026-01-14")
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader { |b| b.upload_video_returns "vid_x" }
    publisher = build_publisher(config: config, uploader: uploader, episode_id: "2026-01-15")

    result = nil
    capture_io { result = publisher.run }

    assert_equal 1, result.uploaded
    assert_equal 1, uploader.uploads.length
    assert_match(/ep-2026-01-15/, uploader.uploads.first[1][:title])
  end

  def test_episode_id_with_force_does_not_pull_in_other_episodes
    seed_ep("ep-2026-01-14")
    seed_ep("ep-2026-01-15")
    seed_ep("ep-2026-01-16")

    # Pre-populate the tracker as if all three were already uploaded.
    require "yaml"
    File.write(@uploads_path, YAML.dump(
      "youtube" => { "default" => {
        "ep-2026-01-14" => "vid_a",
        "ep-2026-01-15" => "vid_b",
        "ep-2026-01-16" => "vid_c"
      } }
    ))

    config = stub_config(youtube_enabled: true)
    uploader = stub_uploader { |b| b.upload_video_returns "vid_new" }
    publisher = build_publisher(
      config: config, uploader: uploader,
      episode_id: "2026-01-15", options: { force: true, verbosity: :quiet }
    )

    result = nil
    capture_io { result = publisher.run }

    # --force ignores the tracker; --date narrows to one. Result: exactly 1 upload.
    assert_equal 1, result.uploaded
    assert_equal 1, uploader.uploads.length
    assert_match(/ep-2026-01-15/, uploader.uploads.first[1][:title])
  end

  private

  StubYouTubeConfig = Struct.new(:episodes_dir, :name, :transcription_language,
    :target_language, :transcription_engines, :_yt, :base_url,
    keyword_init: true) do
    def initialize(episodes_dir:, name: "test_pod", transcription_language: nil,
                   target_language: nil, transcription_engines: [],
                   _yt: nil, base_url: nil)
      super
    end

    def youtube_enabled? = !_yt.nil?
    def youtube_config = _yt
    def language_for_episode(_) = transcription_language || "en"
    def primary_language = transcription_language || "en"
    def site_episode_url(_) = nil
    def uploads_yml_path = nil
  end

  def stub_config(youtube_enabled:, playlist: nil)
    yt = youtube_enabled ? { playlist: playlist, privacy: "unlisted", category: "27", tags: [] } : nil
    StubYouTubeConfig.new(
      episodes_dir: @episodes_dir,
      name: "test_pod",
      transcription_language: "en",
      _yt: yt
    )
  end

  def seed_ep(base)
    File.write(File.join(@episodes_dir, "#{base}.mp3"), "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}.mp4"), "x" * 100) # skip video gen
    File.write(File.join(@episodes_dir, "#{base}_transcript.md"), "# Title #{base}\n\n## Transcript\n\nHello.\n")
  end

  def build_publisher(config:, uploader: nil, options: {}, episode_id: nil)
    YouTubePublisher.new(
      config: config,
      options: options,
      uploader: uploader,
      tracker_path: @uploads_path,
      episode_id: episode_id
    )
  end

  def stub_uploader
    u = StubUploader.new
    yield(u) if block_given?
    u
  end

  class StubUploader
    attr_reader :uploads, :playlist_calls

    def initialize
      @uploads = []
      @playlist_calls = []
      @upload_video_block = ->(*_a, **_kw) { "vid_default" }
      @verify_block = ->(_id) {}
    end

    def upload_video_returns(id)
      @upload_video_block = ->(*_a, **_kw) { id }
    end

    def upload_video_raises(err)
      @upload_video_block = ->(*_a, **_kw) { raise err }
    end

    def upload_video_with(&blk)
      @upload_video_block = blk
    end

    def verify_playlist_raises(msg)
      @verify_block = ->(id) { raise msg }
    end

    def authorize! = nil
    def verify_playlist!(id) = @verify_block.call(id)
    def upload_video(*args, **kw)
      @uploads << [args, kw]
      @upload_video_block.call(*args, **kw)
    end
    def upload_captions(*_a, **_kw) = nil
    def add_to_playlist(*args)
      @playlist_calls << args
      nil
    end
  end
end
