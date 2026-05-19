# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "yaml"
require "cli/publish_command"
require "regen_cache"
require "youtube_publisher"

class TestPublishCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_publish_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
    YouTubePublisher.reset_playlist_cache!
  end

  # The following per-method behaviors used to live on PublishCommand and
  # are now in their dedicated classes; their tests moved with them:
  #   parse_transcript            → test_transcript_parser.rb
  #   scan_episodes               → test_episode_scanner.rb
  #   upload_tracker              → test_upload_tracker.rb
  #   reconcile_subtitles_if_needed → test_subtitle_reconciliation_runner.rb
  #                                  + test_youtube_publisher.rb integration
  #   retranscribe_for_timestamps → covered by the publisher tests' setup
  #   pick_timestamp_engine       → folded into the publishers (private)
  #   cleanup_cover               → covered by test_cover_resolver.rb
  #   rclone_available?           → covered by test_r2_publisher.rb

  # --- publish_to_youtube: playlist verification ---

  def test_publish_to_youtube_verifies_playlist_before_uploading
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# Title\n\n## Transcript\n\nHello.")

    yt_config = { playlist: "PLbadplaylist", privacy: "unlisted", category: "27", tags: [] }
    cmd = build_command(youtube_config: yt_config)

    uploaded = []
    verified = []

    stub_uploader = Object.new
    stub_uploader.define_singleton_method(:authorize!) { nil }
    stub_uploader.define_singleton_method(:verify_playlist!) { |id| verified << id; raise "Playlist not found: #{id}" }
    stub_uploader.define_singleton_method(:upload_video) { |*args, **kw| uploaded << args; "vid_123" }
    stub_uploader.define_singleton_method(:upload_captions) { |*args, **kw| nil }
    stub_uploader.define_singleton_method(:add_to_playlist) { |*args| nil }

    cmd.define_singleton_method(:build_youtube_uploader) { stub_uploader }

    _, err = capture_io { code = cmd.send(:publish_to_youtube); assert_equal 1, code }

    assert_equal ["PLbadplaylist"], verified, "should have called verify_playlist!"
    assert_empty uploaded, "should NOT upload any videos when playlist verification fails"
    assert_includes err, "Playlist not found"
  end

  def test_publish_to_youtube_caps_uploads_at_max
    %w[ep-2026-01-15 ep-2026-01-16 ep-2026-01-17].each do |b|
      create_mp3("#{b}.mp3")
      File.write(File.join(@episodes_dir, "#{b}.mp4"), "x" * 100) # pre-existing video, skips cover lookup
      File.write(File.join(@episodes_dir, "#{b}_transcript.md"), "# Title\n\n## Transcript\n\nHello.")
    end

    yt_config = { privacy: "unlisted", category: "27", tags: [] }
    cmd = build_command(youtube_config: yt_config)
    cmd.instance_variable_get(:@options)[:max] = 1

    uploaded = []
    stub_uploader = Object.new
    stub_uploader.define_singleton_method(:authorize!) { nil }
    stub_uploader.define_singleton_method(:verify_playlist!) { |_| nil }
    stub_uploader.define_singleton_method(:upload_video) { |*args, **kw| uploaded << args.first; "vid_#{uploaded.length}" }
    stub_uploader.define_singleton_method(:upload_captions) { |*args, **kw| nil }
    stub_uploader.define_singleton_method(:add_to_playlist) { |*args| nil }

    cmd.define_singleton_method(:build_youtube_uploader) { stub_uploader }
    tmp_uploads = File.join(@tmpdir, "uploads.yml")
    cmd.define_singleton_method(:upload_tracker) { @ut ||= UploadTracker.new(tmp_uploads) }

    capture_io { cmd.send(:publish_to_youtube) }

    assert_equal 1, uploaded.length, "should upload at most --max episodes (got #{uploaded.length})"
  end

  def test_max_flag_parsed_from_cli
    cmd = PodgenCLI::PublishCommand.new(["testpod", "--youtube", "--max", "2"], {})
    assert_equal 2, cmd.instance_variable_get(:@options)[:max]
  end

  def test_publish_to_youtube_requires_youtube_uploader_before_building
    # Regression: build_youtube_uploader does YouTubeUploader.new — the
    # production code MUST require_relative "youtube_uploader" itself
    # before that call. We can't rely on `defined?(::YouTubeUploader)`
    # because other test files (test_youtube_uploader.rb) require it at
    # file-load time, so the constant is globally defined regardless.
    #
    # Instead: spy on require_relative via singleton-class prepend, record
    # call order, and assert the require precedes build_youtube_uploader.
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# Title\n\n## Transcript\n\nHello.")
    File.write(File.join(@episodes_dir, "ep-2026-01-15.mp4"), "x" * 100)

    yt_config = { privacy: "unlisted", category: "27", tags: [] }
    cmd = build_command(youtube_config: yt_config)

    required = []
    spy = Module.new
    spy.send(:define_method, :require_relative) do |path|
      required << path
      super(path)
    end
    cmd.singleton_class.prepend(spy)

    build_called_at = nil
    cmd.define_singleton_method(:build_youtube_uploader) do
      build_called_at = required.length
      stub = Object.new
      stub.define_singleton_method(:authorize!) { nil }
      stub.define_singleton_method(:verify_playlist!) { |_| nil }
      stub.define_singleton_method(:upload_video) { |*_, **_| "vid_x" }
      stub.define_singleton_method(:upload_captions) { |*_, **_| nil }
      stub.define_singleton_method(:add_to_playlist) { |*_| nil }
      stub
    end

    capture_io { cmd.send(:publish_to_youtube) }

    refute_nil build_called_at, "build_youtube_uploader was never called"
    assert required[0...build_called_at].any? { |r| r.end_with?("youtube_uploader") },
      "publish_to_youtube must require_relative 'youtube_uploader' BEFORE calling build_youtube_uploader; " \
      "saw requires before build: #{required[0...build_called_at].inspect}"
  end

  def test_publish_to_youtube_returns_2_when_youtube_not_configured
    cmd = build_command(youtube_config: nil)
    code = nil
    capture_io { code = cmd.send(:publish_to_youtube) }
    assert_equal 2, code
  end

  def test_publish_to_youtube_skips_verification_when_no_playlist
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# Title\n\n## Transcript\n\nHello.")

    yt_config = { privacy: "unlisted", category: "27", tags: [] }
    cmd = build_command(youtube_config: yt_config)

    verified = []

    stub_uploader = Object.new
    stub_uploader.define_singleton_method(:authorize!) { nil }
    stub_uploader.define_singleton_method(:verify_playlist!) { |id| verified << id }
    # Raise on upload to stop execution after we've confirmed verify was skipped
    stub_uploader.define_singleton_method(:upload_video) { |*args, **kw| raise "stop" }

    cmd.define_singleton_method(:build_youtube_uploader) { stub_uploader }

    capture_io { cmd.send(:publish_to_youtube) }

    assert_empty verified, "should NOT call verify_playlist! when no playlist configured"
  end

  # --- --date flag ---

  def test_date_flag_sets_episode_id
    cmd = PodgenCLI::PublishCommand.new(["testpod", "--date", "2026-03-10"], {})
    assert_equal "2026-03-10", cmd.instance_variable_get(:@episode_id)
  end

  def test_date_flag_with_positional_date_is_rejected
    # Passing both is ambiguous — fail loud rather than silently dropping one.
    err = assert_raises(OptionParser::ParseError) do
      PodgenCLI::PublishCommand.new(["testpod", "2026-01-01", "--date", "2026-03-10"], {})
    end
    assert_includes err.message, "2026-01-01"
  end

  # find_text_file moved to EpisodeScanner — see test_episode_scanner.rb.

  private

  StubPublishConfig = Struct.new(:episodes_dir, :name, :transcription_language,
    :target_language, :transcription_engines, :youtube_config_data, keyword_init: true) do
    def initialize(episodes_dir:, name: "test", transcription_language: nil,
                   target_language: nil, transcription_engines: %w[groq],
                   youtube_config_data: nil)
      super
    end

    def youtube_enabled?
      !youtube_config_data.nil?
    end

    def youtube_config
      youtube_config_data
    end
  end

  def create_mp3(name)
    File.write(File.join(@episodes_dir, name), "x" * 1000)
  end

  def write_transcript(content)
    path = File.join(@episodes_dir, "test_transcript.md")
    File.write(path, content)
    path
  end

  def build_command(transcription_language: nil, transcription_engines: %w[groq],
                    target_language: nil, episode_id: nil, youtube_config: nil)
    cmd = PodgenCLI::PublishCommand.allocate
    config = StubPublishConfig.new(
      episodes_dir: @episodes_dir,
      name: "test",
      transcription_language: transcription_language,
      target_language: target_language,
      transcription_engines: transcription_engines,
      youtube_config_data: youtube_config
    )
    cmd.instance_variable_set(:@config, config)
    cmd.instance_variable_set(:@options, {})
    cmd.instance_variable_set(:@episode_id, episode_id)
    cmd
  end
end
