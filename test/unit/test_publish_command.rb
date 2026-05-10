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

  # --- parse_transcript ---

  def test_parse_transcript_with_transcript_section
    path = write_transcript(<<~MD)
      # My Episode Title

      Some description text

      ## Transcript

      First paragraph of transcript.

      Second paragraph.

      ## Vocabulary

      Vocab entries here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "My Episode Title", title
    assert_equal "Some description text", description
    assert_includes transcript, "First paragraph of transcript."
    assert_includes transcript, "Second paragraph."
    refute_includes transcript, "Vocabulary"
    refute_includes transcript, "Vocab entries"
  end

  def test_parse_transcript_without_transcript_section
    path = write_transcript(<<~MD)
      # Simple Title

      Just body text here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "Simple Title", title
    assert_nil description
    assert_includes transcript, "Just body text here."
  end

  def test_parse_transcript_empty_description
    path = write_transcript(<<~MD)
      # Title

      ## Transcript

      Body here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "Title", title
    assert_nil description
    assert_includes transcript, "Body here."
  end

  def test_parse_transcript_minimal
    path = write_transcript("# Just Title\n")

    cmd = build_command
    title, description, _ = cmd.send(:parse_transcript, path)

    assert_equal "Just Title", title
    assert_nil description
  end

  # --- scan_episodes ---

  def test_scan_episodes_finds_mp3s_with_transcripts
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# Title\n\nText")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_equal 1, episodes.length
    assert_equal "ep-2026-01-15", episodes.first[:base_name]
  end

  def test_scan_episodes_skips_mp3_without_transcript
    create_mp3("ep-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_empty episodes
  end

  def test_scan_episodes_sorted_chronologically
    create_mp3("ep-2026-01-15.mp3")
    create_mp3("ep-2026-01-16.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# A")
    File.write(File.join(@episodes_dir, "ep-2026-01-16_transcript.md"), "# B")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_equal 2, episodes.length
    assert_equal "ep-2026-01-15", episodes.first[:base_name]
    assert_equal "ep-2026-01-16", episodes.last[:base_name]
  end

  def test_scan_episodes_empty_directory
    cmd = build_command
    assert_empty cmd.send(:scan_episodes)
  end

  def test_scan_episodes_filters_by_episode_id
    create_mp3("ep-2026-01-15.mp3")
    create_mp3("ep-2026-01-16.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# T1")
    File.write(File.join(@episodes_dir, "ep-2026-01-16_transcript.md"), "# T2")

    cmd = build_command(episode_id: "2026-01-16")
    episodes = cmd.send(:scan_episodes)

    assert_equal 1, episodes.length
    assert_equal "ep-2026-01-16", episodes.first[:base_name]
  end

  def test_scan_episodes_filters_with_suffix
    create_mp3("ep-2026-01-15.mp3")
    create_mp3("ep-2026-01-15a.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# T1")
    File.write(File.join(@episodes_dir, "ep-2026-01-15a_transcript.md"), "# T2")

    cmd = build_command(episode_id: "2026-01-15a")
    episodes = cmd.send(:scan_episodes)

    assert_equal 1, episodes.length
    assert_equal "ep-2026-01-15a", episodes.first[:base_name]
  end

  def test_scan_episodes_no_match_returns_empty_with_warning
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# T1")

    cmd = build_command(episode_id: "2026-99-99")
    matched = nil
    _, err = capture_io { matched = cmd.send(:scan_episodes) }

    assert_empty matched
    assert_includes err, "No episode found matching"
  end

  def test_scan_episodes_newest_reverses_order
    create_mp3("ep-2026-01-15.mp3")
    create_mp3("ep-2026-01-16.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# T1")
    File.write(File.join(@episodes_dir, "ep-2026-01-16_transcript.md"), "# T2")

    cmd = build_command
    cmd.instance_variable_get(:@options)[:newest] = true
    episodes = cmd.send(:scan_episodes)

    assert_equal "ep-2026-01-16", episodes.first[:base_name]
    assert_equal "ep-2026-01-15", episodes.last[:base_name]
  end

  # --- upload_tracker ---

  def test_upload_tracker_missing_file
    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal({}, tracker.load)
  end

  def test_upload_tracker_existing_file
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, { "lingq" => { "123" => { "ep-a" => 1 } } }.to_yaml)

    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal 1, tracker.entries_for(:lingq, "123")["ep-a"]
  end

  def test_upload_tracker_record_and_persist
    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    tracker.record(:lingq, "456", "ep-b", 2)

    tracking_path = File.join(@tmpdir, "uploads.yml")
    assert File.exist?(tracking_path)
    data = YAML.load_file(tracking_path)
    assert_equal 2, data["lingq"]["456"]["ep-b"]
  end

  def test_upload_tracker_handles_non_hash
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, "just a string")

    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal({}, tracker.load)
  end

  # --- cleanup_cover ---

  def test_cleanup_cover_deletes_tmpdir_file
    cover = File.join(Dir.tmpdir, "podgen_test_cover_#{Process.pid}.jpg")
    File.write(cover, "image")

    cmd = build_command
    cmd.send(:cleanup_cover, cover)

    refute File.exist?(cover)
  end

  def test_cleanup_cover_ignores_non_tmpdir_file
    # Use a path outside Dir.tmpdir
    cover = File.join(@episodes_dir, "cover.jpg")
    File.write(cover, "image")

    # Temporarily override Dir.tmpdir to be something else so this path won't match
    cmd = build_command
    # The check is image_path.start_with?(Dir.tmpdir), and @episodes_dir is under
    # Dir.tmpdir since mktmpdir creates there. Use absolute home dir instead.
    home_cover = File.expand_path("~/podgen_test_cleanup_cover.jpg")
    File.write(home_cover, "image")
    cmd.send(:cleanup_cover, home_cover)
    assert File.exist?(home_cover)
  ensure
    File.delete(home_cover) if home_cover && File.exist?(home_cover)
  end

  def test_cleanup_cover_ignores_nil
    cmd = build_command
    cmd.send(:cleanup_cover, nil) # should not raise
  end

  # --- reconcile_subtitles_if_needed ---

  def test_reconcile_subtitles_if_needed_loads_timestamp_persister
    ts_path = File.join(@episodes_dir, "ep-2026-01-15_timestamps.json")
    File.write(ts_path, JSON.generate({
      "version" => 1, "engine" => "groq", "intro_duration" => 0.0,
      "segments" => [{ "start" => 0.0, "end" => 1.0, "text" => "hello" }]
    }))
    transcript_path = write_transcript("# Title\n\n## Transcript\n\nHello world.\n")

    cmd = build_command
    old_key = ENV.delete("ANTHROPIC_API_KEY")
    begin
      _, err = capture_io { cmd.send(:reconcile_subtitles_if_needed, ts_path, transcript_path) }
      refute_match(/uninitialized constant/, err,
        "TimestampPersister should be loaded before use in reconcile_subtitles_if_needed")
    ensure
      ENV["ANTHROPIC_API_KEY"] = old_key if old_key
    end
  end

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

  # --- rclone_available? ---

  def test_rclone_available_when_installed
    cmd = build_command
    result = cmd.send(:rclone_available?)
    # Result depends on environment — just verify it returns boolean
    assert_includes [true, false], result
  end

  # --- pick_timestamp_engine ---

  def test_pick_timestamp_engine_prefers_groq
    cmd = build_command(transcription_engines: %w[open groq elab])
    assert_equal "groq", cmd.send(:pick_timestamp_engine)
  end

  def test_pick_timestamp_engine_falls_back_to_elab
    cmd = build_command(transcription_engines: %w[open elab])
    assert_equal "elab", cmd.send(:pick_timestamp_engine)
  end

  def test_pick_timestamp_engine_falls_back_to_open
    cmd = build_command(transcription_engines: %w[open])
    assert_equal "open", cmd.send(:pick_timestamp_engine)
  end

  def test_pick_timestamp_engine_uses_first_when_unknown
    cmd = build_command(transcription_engines: %w[custom])
    assert_equal "custom", cmd.send(:pick_timestamp_engine)
  end

  # --- retranscribe_for_timestamps ---

  def test_retranscribe_skips_when_no_language
    cmd = build_command(transcription_language: nil)
    ts_path = File.join(@episodes_dir, "ep_timestamps.json")

    capture_io { cmd.send(:retranscribe_for_timestamps, "/tmp/fake.mp3", ts_path, "ep") }

    refute File.exist?(ts_path)
  end

  def test_retranscribe_skips_when_no_engines
    cmd = build_command(transcription_language: "sl", transcription_engines: [])
    ts_path = File.join(@episodes_dir, "ep_timestamps.json")

    capture_io { cmd.send(:retranscribe_for_timestamps, "/tmp/fake.mp3", ts_path, "ep") }

    refute File.exist?(ts_path)
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

  # --- find_text_file ---

  def test_find_text_file_prefers_transcript
    File.write(File.join(@episodes_dir, "ep-2026-01-01_transcript.md"), "# T\n\n## Transcript\n\nBody")
    File.write(File.join(@episodes_dir, "ep-2026-01-01_script.md"), "# S\n\nScript body")

    cmd = build_command
    result = cmd.send(:find_text_file, @episodes_dir, "ep-2026-01-01")
    assert_equal File.join(@episodes_dir, "ep-2026-01-01_transcript.md"), result
  end

  def test_find_text_file_falls_back_to_script
    File.write(File.join(@episodes_dir, "ep-2026-01-01_script.md"), "# S\n\nScript body")

    cmd = build_command
    result = cmd.send(:find_text_file, @episodes_dir, "ep-2026-01-01")
    assert_equal File.join(@episodes_dir, "ep-2026-01-01_script.md"), result
  end

  def test_find_text_file_returns_nil_when_missing
    cmd = build_command
    result = cmd.send(:find_text_file, @episodes_dir, "ep-2026-01-01")
    assert_nil result
  end

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
