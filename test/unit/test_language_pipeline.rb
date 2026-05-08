# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "date"
require "fileutils"
require "episode_history"
require "agents/description_agent"
require "cli/language_pipeline"
require "time_value"

# Minimal logger that captures messages without file I/O
class StubLogger
  attr_reader :messages, :errors

  def initialize
    @messages = []
    @errors = []
  end

  def log(msg) = @messages << msg
  def error(msg) = @errors << msg
  def phase_start(_name) = nil
  def phase_end(_name) = nil
end

# Minimal config double exposing only the fields private methods need
StubConfig = Struct.new(
  :podcast_dir, :episodes_dir, :history_path, :excluded_urls_path, :author,
  :cover_base_image, :cover_options, :cover_generation_enabled,
  :lingq_config, :lingq_enabled, :transcription_language,
  :transcription_engines, :target_language,
  :skip, :cut, :autotrim, :name,
  keyword_init: true
) do
  def cover_generation_enabled? = cover_generation_enabled
  def lingq_enabled? = lingq_enabled
  def episode_basename(_date) = "test-2026-03-10"
  def auto_cover_config = {}
  def min_length_seconds; nil; end
  def max_length_seconds; nil; end
end

# Stub DescriptionAgent for testing clean_or_generate_description
class StubDescriptionAgent
  def initialize(clean_title: nil, clean: nil, generate: nil, generate_title: nil)
    @clean_title_result = clean_title
    @clean_result = clean
    @generate_result = generate
    @generate_title_result = generate_title
  end

  def clean_title(title:) = @clean_title_result || title
  def clean(title:, description:) = @clean_result || description
  def generate(title:, transcript:) = @generate_result || ""
  def generate_title(transcript:, language:) = @generate_title_result
end

class TestLanguagePipeline < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lp_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    @logger = StubLogger.new
    @history = EpisodeHistory.new(File.join(@tmpdir, "history.yml"))

    @config = StubConfig.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl"
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- write_transcript_file ---

  def test_write_transcript_file_creates_markdown
    pipeline = build_pipeline
    episode = { title: "My Episode", description: "Episode desc" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Hello world transcript.")

    content = File.read(path)
    assert_includes content, "# My Episode"
    assert_includes content, "Episode desc"
    assert_includes content, "## Transcript"
    assert_includes content, "Hello world transcript."
  end

  def test_write_transcript_file_omits_empty_description
    pipeline = build_pipeline
    episode = { title: "No Desc", description: "" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Text.")

    content = File.read(path)
    assert_includes content, "# No Desc"
    assert_includes content, "## Transcript"
    refute_includes content, "Episode desc"
  end

  def test_write_transcript_file_creates_directory
    pipeline = build_pipeline
    episode = { title: "Test", description: nil }
    nested_path = File.join(@episodes_dir, "sub", "transcript.md")

    pipeline.send(:write_transcript_file, nested_path, episode, "Content")

    assert File.exist?(nested_path)
  end

  # --- record_lingq_upload ---

  def test_record_lingq_upload_creates_tracking_file
    pipeline = build_pipeline
    tracking_path = File.join(@tmpdir, "uploads.yml")

    pipeline.send(:record_lingq_upload, 12345, "test-2026-03-10", 999)

    assert File.exist?(tracking_path)
    data = YAML.load_file(tracking_path)
    assert_equal 999, data["lingq"]["12345"]["test-2026-03-10"]
  end

  def test_record_lingq_upload_appends_to_existing
    pipeline = build_pipeline
    tracking_path = File.join(@tmpdir, "uploads.yml")

    # Pre-populate with unified format
    File.write(tracking_path, { "lingq" => { "12345" => { "old-ep" => 100 } } }.to_yaml)

    pipeline.send(:record_lingq_upload, 12345, "new-ep", 200)

    data = YAML.load_file(tracking_path)
    assert_equal 100, data["lingq"]["12345"]["old-ep"]
    assert_equal 200, data["lingq"]["12345"]["new-ep"]
  end

  def test_record_lingq_upload_handles_separate_collections
    pipeline = build_pipeline

    pipeline.send(:record_lingq_upload, 111, "ep-a", 1)
    pipeline.send(:record_lingq_upload, 222, "ep-b", 2)

    tracking_path = File.join(@tmpdir, "uploads.yml")
    data = YAML.load_file(tracking_path)
    assert_equal 1, data["lingq"]["111"]["ep-a"]
    assert_equal 2, data["lingq"]["222"]["ep-b"]
  end

  # --- resolve_episode_cover ---

  def test_resolve_cover_with_image_path_option
    image_path = File.join(@tmpdir, "custom.png")
    FileUtils.touch(image_path)

    pipeline = build_pipeline(options: { image: image_path })
    result = pipeline.send(:resolve_episode_cover, "Title")

    path, desc = result
    assert_equal File.expand_path(image_path), path
    assert_includes desc, "--image"
  end

  def test_resolve_cover_with_thumb_option
    pipeline = build_pipeline(options: { image: "thumb" })
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/thumb.jpg")
    path, desc = pipeline.send(:resolve_episode_cover, "Title")

    assert_equal "/tmp/thumb.jpg", path
    assert_includes desc, "thumb"
  end

  def test_resolve_cover_image_none_falls_to_thumbnail
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_image_none, true)
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/thumb.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/thumb.jpg", path
    assert_includes desc, "none"
  end

  def test_resolve_cover_returns_nil_when_no_options
    pipeline = build_pipeline
    path, = pipeline.send(:resolve_episode_cover, "Title")
    assert_nil path
  end

  def test_resolve_cover_uses_rss_episode_image
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  def test_resolve_cover_feed_base_image_beats_rss_image
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")
    pipeline.instance_variable_set(:@current_episode_feed_base_image, "/tmp/base.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    # feed base_image triggers generate_cover_image which fails on fake path,
    # but the point is it did NOT return the RSS image
    refute_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "feed base_image"
  end

  # --- --image auto regression ---

  def test_resolve_cover_with_image_auto_returns_winner_path
    # Regression: --image auto used to be misread as a literal file path
    # (File.expand_path("auto") → /Users/.../auto), crashing ImageMagick.
    pipeline = build_pipeline(options: { image: "auto" })
    winner = "/tmp/podgen_auto_winner.jpg"
    pipeline.define_singleton_method(:try_auto_cover_for_feed) { |_title| winner }

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal winner, path
    assert_includes desc, "--image auto"
    refute_match(%r{/auto\z}, path.to_s, "must not treat 'auto' as a relative path")
  end

  def test_resolve_cover_with_image_auto_falls_through_when_no_winner
    pipeline = build_pipeline(options: { image: "auto" })
    pipeline.define_singleton_method(:try_auto_cover_for_feed) { |_title| nil }
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/thumb.jpg")

    path, = pipeline.send(:resolve_episode_cover, "Title")
    # No winner → falls through to next chain step (here: youtube thumbnail)
    assert_equal "/tmp/thumb.jpg", path
  end

  def test_resolve_cover_with_image_auto_falls_through_to_rss_image_when_no_winner
    pipeline = build_pipeline(options: { image: "auto" })
    pipeline.define_singleton_method(:try_auto_cover_for_feed) { |_title| nil }
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  # --- enforce_length_post_download ---

  def test_enforce_length_returns_nil_when_in_range
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :ok }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    AudioAssembler.stub :probe_duration, 300.0 do
      result = pipeline.send(:enforce_length_post_download)
      assert_nil result
    end
  end

  def test_enforce_length_aborts_on_too_long_without_ask_trim
    pipeline = build_pipeline(options: {})
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    AudioAssembler.stub :probe_duration, 700.0 do
      result = pipeline.send(:enforce_length_post_download)
      assert_equal 1, result
    end
  end

  def test_enforce_length_with_ask_trim_excludes_on_x
    # `x` is the project-wide exclude key (matches other prompts in this file
    # at lines ~321,326 — "x to exclude" — and scrap_command).
    pipeline = build_pipeline(options: { ask_trim: true })
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    pipeline.instance_variable_set(:@episode, { audio_url: "https://ex.com/ep.mp3" })

    excluded_url = nil
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    fake_source.define_singleton_method(:exclude_url!) { |url| excluded_url = url }
    pipeline.instance_variable_set(:@episode_source, fake_source)

    out = nil
    $stdin.stub :gets, "x\n" do
      AudioAssembler.stub :probe_duration, 700.0 do
        out, _ = capture_io do
          result = pipeline.send(:enforce_length_post_download)
          assert_equal 1, result
        end
      end
    end
    assert_equal "https://ex.com/ep.mp3", excluded_url
    assert_match(/\[x\](?:clude|.*exclude)/i, out,
      "prompt must offer [x] for exclude (project-wide convention)")
  end

  def test_enforce_length_with_ask_trim_continues_on_t
    pipeline = build_pipeline(options: { ask_trim: true })
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    pipeline.instance_variable_set(:@episode, { audio_url: "https://ex.com/ep.mp3" })

    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    pipeline.instance_variable_set(:@episode_source, fake_source)

    $stdin.stub :gets, "t\n" do
      AudioAssembler.stub :probe_duration, 700.0 do
        capture_io do
          result = pipeline.send(:enforce_length_post_download)
          assert_nil result
        end
      end
    end
  end

  def test_resolve_cover_per_feed_image_auto_uses_resolver_winner
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "Episode about a king." })

    fake = Object.new
    fake.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      { winner_path: "/tmp/winner.jpg", top_paths: ["/tmp/winner.jpg"], candidates: [{ score: 18 }] }
    end

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      path, desc = pipeline.send(:resolve_episode_cover, "King Title")
      assert_equal "/tmp/winner.jpg", path
      assert_includes desc, "auto"
    end
  end

  def test_resolve_cover_per_feed_image_auto_persists_into_staging_dir
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "x" })
    staging = pipeline.instance_variable_get(:@staging_dir)

    captured_dir = nil
    fake = Object.new
    fake.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      captured_dir = episodes_dir
      { winner_path: nil, top_paths: [], candidates: [] }
    end

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      pipeline.send(:resolve_episode_cover, "Title")
    end
    assert_equal staging, captured_dir,
                 "candidates must be persisted into @staging_dir so they participate in commit_episode's atomic move"
  end

  def test_resolve_cover_per_feed_image_auto_falls_through_when_no_winner
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "x" })
    # Set RSS image so the chain has something to fall through TO
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_fallback.jpg")

    fake = Object.new
    fake.define_singleton_method(:try) { |**_kw| { winner_path: nil, top_paths: [], candidates: [] } }

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      path, desc = pipeline.send(:resolve_episode_cover, "Title")
      assert_equal "/tmp/rss_fallback.jpg", path, "should fall through to RSS image when auto returns no winner"
      assert_includes desc, "RSS"
    end
  end

  def test_resolve_cover_base_image_option_beats_rss_image
    base_path = File.join(@tmpdir, "base.png")
    FileUtils.touch(base_path)

    config = build_config(cover_base_image: base_path, cover_generation_enabled: true)
    pipeline = build_pipeline(options: { base_image: base_path }, config: config)
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, = pipeline.send(:resolve_episode_cover, "Title")
    refute_equal "/tmp/rss_cover.jpg", path
  end

  def test_resolve_cover_image_option_beats_rss_image
    image_path = File.join(@tmpdir, "explicit.png")
    FileUtils.touch(image_path)

    pipeline = build_pipeline(options: { image: image_path })
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal File.expand_path(image_path), path
  end

  def test_resolve_cover_falls_through_to_youtube_thumbnail
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/yt.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/yt.jpg", path
    assert_includes desc, "thumbnail"
  end

  # --- cleanup_temp_files ---

  def test_cleanup_temp_files_removes_files
    f1 = File.join(@tmpdir, "temp1.mp3")
    f2 = File.join(@tmpdir, "temp2.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1, f2])
    pipeline.instance_variable_set(:@trimmer, nil)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  def test_cleanup_temp_files_ignores_missing
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, ["/nonexistent/file.mp3"])
    pipeline.instance_variable_set(:@trimmer, nil)

    # Should not raise
    pipeline.send(:cleanup_temp_files)
  end

  def test_cleanup_includes_trimmer_temp_files
    f1 = File.join(@tmpdir, "pipeline.mp3")
    f2 = File.join(@tmpdir, "trimmer.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1])

    trimmer_stub = Struct.new(:temp_files).new([f2])
    pipeline.instance_variable_set(:@trimmer, trimmer_stub)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  # --- clean_or_generate_description ---

  def test_clean_or_generate_description_cleans_existing
    pipeline = build_pipeline
    episode = { title: "Test", description: "Original desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", clean: "Cleaned desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Cleaned desc", episode[:description]
  end

  def test_clean_or_generate_description_generates_when_empty
    pipeline = build_pipeline
    episode = { title: "Test", description: "" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", generate: "Generated desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Generated desc", episode[:description]
  end

  def test_clean_or_generate_description_cleans_title
    pipeline = build_pipeline
    episode = { title: "CATEGORY: Real Title", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Real Title", clean: "Desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    assert_equal "Real Title", episode[:title]
  end

  def test_clean_or_generate_description_non_fatal
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    # Raise during agent construction
    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      # Should not raise
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    # Original description preserved on error
    assert_equal "Keep me", episode[:description]
  end

  def test_generic_title_matching_podcast_name_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Basnie", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Basnie", clean: "Desc", generate_title: "Szczepan i smok")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył Szczepan...")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  def test_non_generic_title_not_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Szczepan i smok", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Szczepan i smok", clean: "Desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  def test_wrong_language_description_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Story Title", description: "Audiobook fairy tales with stories and morals for children and families" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Story Title",
      clean: "Audiobook fairy tales with stories and morals for children and families",
      generate: "Opowieść o chłopcu i smoku."
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył sobie chłopiec")
    end

    assert_equal "Opowieść o chłopcu i smoku.", episode[:description]
  end

  def test_correct_language_description_not_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Title", description: "Opowieść o chłopcu który spotkał smoka w lesie" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Title",
      clean: "Opowieść o chłopcu który spotkał smoka w lesie"
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript")
    end

    assert_equal "Opowieść o chłopcu który spotkał smoka w lesie", episode[:description]
  end

  def test_wrong_language_title_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Audio fairy tales for children and families to enjoy", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Audio fairy tales for children and families to enjoy",
      clean: "Desc",
      generate_title: "Szczepan i smok"
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył Szczepan...")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  # --- warnings tracking ---

  def test_description_failure_adds_warning
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    warnings = pipeline.instance_variable_get(:@warnings)
    assert_equal 1, warnings.size
    assert_includes warnings.first, "Description cleanup failed (API error)"
  end

  def test_reconciliation_failure_raises_error
    config = StubConfig.new(
      podcast_dir: @tmpdir, episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      author: "Test", cover_base_image: nil, cover_options: {},
      cover_generation_enabled: false, lingq_config: nil, lingq_enabled: false,
      transcription_language: "sl",
      transcription_engines: %w[open groq], target_language: "en"
    )
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@config, config)

    fake_manager = Object.new
    fake_manager.define_singleton_method(:transcribe) do |*, **|
      { all: { "open" => { text: "raw" }, "groq" => { text: "raw" } },
        errors: {}, reconciled: nil, primary: { text: "raw" } }
    end

    err = assert_raises(RuntimeError) do
      Transcription::EngineManager.stub(:new, fake_manager) do
        pipeline.send(:transcribe_audio, "/fake/audio.mp3")
      end
    end
    assert_includes err.message, "reconciliation failed"
  end

  def test_log_completion_with_warnings_shows_warning_marker
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    pipeline.instance_variable_get(:@warnings) << "Test warning"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u26A0") }
    assert @logger.messages.any? { |m| m.include?("with warnings") }
    assert @logger.messages.any? { |m| m.include?("Test warning") }
  end

  def test_log_completion_without_warnings_shows_checkmark
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u2713") }
    refute @logger.messages.any? { |m| m.include?("warning") }
  end

  def test_log_completion_lists_multiple_warnings
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    warnings = pipeline.instance_variable_get(:@warnings)
    warnings << "Warning one"
    warnings << "Warning two"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("Warning one") }
    assert @logger.messages.any? { |m| m.include?("Warning two") }
  end

  # --- log_dry_run ---

  def test_log_dry_run_logs_summary
    pipeline = build_pipeline(options: { verbosity: :quiet })
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.send(:log_dry_run, "Config validated")

    assert @logger.messages.any? { |m| m.include?("dry-run") }
    assert @logger.messages.any? { |m| m.include?("Config validated") }
  end

  # --- validate_image_options ---

  def test_validate_image_options_thumb_without_url_returns_error
    pipeline = build_pipeline(options: { image: "thumb" })
    # No @youtube_url set
    result = pipeline.send(:validate_image_options)
    assert_equal 1, result
  end

  def test_validate_image_options_thumb_with_url_returns_nil
    pipeline = build_pipeline(options: { image: "thumb", url: "https://youtube.com/watch?v=abc" })
    pipeline.instance_variable_set(:@youtube_url, "https://youtube.com/watch?v=abc")
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_nil_returns_nil
    pipeline = build_pipeline
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_last_with_no_screenshots
    pipeline = build_pipeline(options: { image: "last" })
    # Stub Dir.glob to return empty
    Dir.stub(:glob, []) do
      result = pipeline.send(:validate_image_options)
      assert_equal 1, result
    end
  end

  # --- --no-skip / --no-cut / --no-autotrim ---

  def test_no_skip_overrides_config_skip
    config = build_config(skip: 38.0)
    pipeline = build_pipeline(options: { no_skip: true }, config: config)
    pipeline.instance_variable_set(:@episode, { skip: 10.0 })
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_nil called_with[:skip]
  end

  def test_no_cut_overrides_config_cut
    config = build_config(cut: 10.0)
    pipeline = build_pipeline(options: { no_cut: true }, config: config)
    pipeline.instance_variable_set(:@episode, { cut: 5.0 })
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_nil called_with[:cut]
  end

  def test_no_autotrim_overrides_config_autotrim
    config = build_config(autotrim: true)
    pipeline = build_pipeline(options: { no_autotrim: true }, config: config)
    pipeline.instance_variable_set(:@episode, { autotrim: true })
    pipeline.instance_variable_set(:@reconciled_text, "some text")
    pipeline.instance_variable_set(:@groq_words, [{ word: "text", end: 10.0 }])

    pipeline.send(:trim_outro)

    assert @logger.messages.any? { |m| m.include?("autotrim not enabled") }
  end

  def test_skip_applies_without_no_skip_flag
    config = build_config(skip: 38.0)
    pipeline = build_pipeline(config: config)
    pipeline.instance_variable_set(:@episode, {})
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_equal 38.0, called_with[:skip]
  end

  # --- ask_trim exclude ---

  def test_ask_trim_x_at_skip_prompt_excludes_episode
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Unwanted Episode", audio_url: "https://example.com/ep1.mp3?utm_source=rss&fbclid=abc" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    # Stub probe_duration and system("open", ...) to avoid real calls
    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    $stdin.stub(:gets, "x\n") do
      AudioAssembler.stub(:new, fake_assembler) do
        pipeline.stub(:system, nil) do
          result = pipeline.send(:trim_source_audio)
          assert_equal :excluded, result
        end
      end
    end

    excluded_path = config.excluded_urls_path
    assert File.exist?(excluded_path), "excluded_urls.yml should be created"
    excluded = YAML.load_file(excluded_path)
    assert_includes excluded, "https://example.com/ep1.mp3"
    refute excluded.any? { |u| u.include?("utm_source") }, "tracking params should be cleaned"
    assert @logger.messages.any? { |m| m.include?("Excluded episode") }
  end

  def test_ask_trim_x_at_cut_prompt_excludes_episode
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Unwanted Episode", audio_url: "https://example.com/ep2.mp3" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    # First gets returns "10" (skip value), second returns "x" (exclude at cut prompt)
    inputs = ["10\n", "x\n"]
    call_count = 0
    fake_gets = -> { r = inputs[call_count]; call_count += 1; r }

    AudioAssembler.stub(:new, fake_assembler) do
      pipeline.stub(:system, nil) do
        $stdin.stub(:gets, fake_gets) do
          result = pipeline.send(:trim_source_audio)
          assert_equal :excluded, result
        end
      end
    end

    excluded = YAML.load_file(config.excluded_urls_path)
    assert_includes excluded, "https://example.com/ep2.mp3"
  end

  def test_ask_trim_normal_input_does_not_exclude
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Good Episode", audio_url: "https://example.com/ep3.mp3" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    inputs = ["5\n", "10\n"]
    call_count = 0
    fake_gets = -> { r = inputs[call_count]; call_count += 1; r }

    called_with = {}
    fake_trimmer = Object.new
    fake_trimmer.define_singleton_method(:apply_trim) do |path, skip:, cut:, snip:|
      called_with[:skip] = skip
      called_with[:cut] = cut
      path
    end

    AudioAssembler.stub(:new, fake_assembler) do
      AudioTrimmer.stub(:new, fake_trimmer) do
        pipeline.stub(:system, nil) do
          $stdin.stub(:gets, fake_gets) do
            result = pipeline.send(:trim_source_audio)
            refute_equal :excluded, result
          end
        end
      end
    end

    refute File.exist?(config.excluded_urls_path)
    assert_equal 5.0, called_with[:skip]
    assert_equal 10.0, called_with[:cut]
  end

  # --- staged output lifecycle ---

  def test_setup_staging_creates_directory
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)

    pipeline.send(:setup_staging)
    assert Dir.exist?(staging)
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_setup_staging_clears_prior_contents
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    File.write(File.join(staging, "leftover.mp3"), "old")

    pipeline.send(:setup_staging)
    assert Dir.exist?(staging)
    assert_empty Dir.glob(File.join(staging, "*"))
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_commit_episode_moves_files_to_episodes
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    pipeline.instance_variable_set(:@base_name, "test-2026-03-10")
    pipeline.instance_variable_set(:@episode, { title: "Test", audio_url: "http://test.mp3" })
    pipeline.instance_variable_set(:@today, Date.new(2026, 3, 10))
    pipeline.instance_variable_set(:@history, EpisodeHistory.new(File.join(@tmpdir, "history.yml")))

    # Create staged files
    File.write(File.join(staging, "test-2026-03-10.mp3"), "audio")
    File.write(File.join(staging, "test-2026-03-10_transcript.md"), "text")

    pipeline.send(:commit_episode)

    assert File.exist?(File.join(@episodes_dir, "test-2026-03-10.mp3"))
    assert File.exist?(File.join(@episodes_dir, "test-2026-03-10_transcript.md"))
    assert_equal File.join(@episodes_dir, "test-2026-03-10.mp3"), pipeline.instance_variable_get(:@output_path)
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_cleanup_staging_removes_directory
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    File.write(File.join(staging, "orphan.mp3"), "data")

    pipeline.send(:cleanup_staging)
    refute Dir.exist?(staging)
  end

  private

  def build_config(**overrides)
    StubConfig.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl",
      **overrides
    )
  end

  def build_config_with_length(min:, max:)
    klass = Class.new(StubConfig) do
      attr_accessor :min_length_override, :max_length_override
      def min_length_seconds; @min_length_override; end
      def max_length_seconds; @max_length_override; end
    end
    cfg = klass.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl"
    )
    cfg.min_length_override = min
    cfg.max_length_override = max
    cfg
  end

  def stub_trimmer(called_with)
    fake_trimmer = Object.new
    fake_trimmer.define_singleton_method(:apply_trim) do |path, skip:, cut:, snip:|
      called_with[:skip] = skip
      called_with[:cut] = cut
      called_with[:snip] = snip
      path
    end
    AudioTrimmer.stub(:new, fake_trimmer) do
      yield
    end
  end

  def build_pipeline(options: {}, config: nil, name: nil, transcription_language: nil)
    cfg = config || @config
    if name || transcription_language
      cfg = StubConfig.new(**cfg.to_h.merge(
        **(name ? { name: name } : {}),
        **(transcription_language ? { transcription_language: transcription_language } : {})
      ))
    end
    opts = { verbosity: :quiet }.merge(options)
    PodgenCLI::LanguagePipeline.new(
      config: cfg,
      options: opts,
      logger: @logger,
      history: @history,
      today: Date.new(2026, 3, 10)
    )
  end
end
