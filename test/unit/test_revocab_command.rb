# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "cli/revocab_command"

class TestRevocabCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_revocab_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    # Minimal guidelines
    File.write(File.join(@podcast_dir, "guidelines.md"), <<~MD)
      # Test Podcast

      ## Audio
      - language: sl

      ## Vocabulary
      - level: B2
    MD

    @original_env = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    ENV["ANTHROPIC_API_KEY"] = @original_env
  end

  # --- resolve_transcripts ---

  def test_resolve_transcripts_finds_all
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-11")

    cmd = build_command("testpod")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 2, transcripts.length
  end

  def test_resolve_transcripts_finds_by_episode_id
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-11")

    cmd = build_command("testpod", "2026-03-10")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 1, transcripts.length
    assert_includes transcripts.first, "2026-03-10"
  end

  def test_resolve_transcripts_finds_suffixed_episode
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-10a")

    cmd = build_command("testpod", "2026-03-10a")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 1, transcripts.length
    assert_includes transcripts.first, "2026-03-10a"
  end

  def test_resolve_transcripts_empty_when_no_match
    write_transcript("testpod-2026-03-10")

    cmd = build_command("testpod", "2026-03-99")
    transcripts = cmd.send(:resolve_transcripts)

    assert_empty transcripts
  end

  # --- process_transcript ---

  def test_process_transcript_strips_old_vocab_and_bold
    path = write_transcript("testpod-2026-03-10", body: "He **razglasil** it.", vocab: <<~VOCAB)
      **C1**
      - **razglasiti** (v.) — to announce _Original: razglasil_
    VOCAB

    stub_annotator("marked body", "## Vocabulary\n\n**B2**\n- **new** (n.) — new word") do |cmd, annotator, logger|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    content = File.read(path)
    # Old vocab stripped, new vocab present
    refute_includes content, "razglasiti"
    assert_includes content, "new word"
    # Old bold markers stripped (passed clean text to annotator)
    assert_includes content, "marked body"
  end

  def test_process_transcript_preserves_header
    path = write_transcript("testpod-2026-03-10",
      title: "My Title", description: "My description",
      body: "Some text.")

    stub_annotator("annotated text", "") do |cmd, annotator, logger|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    content = File.read(path)
    assert_includes content, "# My Title"
    assert_includes content, "My description"
    assert_includes content, "## Transcript"
  end

  def test_process_transcript_handles_no_transcript_section
    path = File.join(@episodes_dir, "bad_transcript.md")
    File.write(path, "Just plain text, no sections.")

    logger = stub_logger
    stub_annotator("x", "") do |cmd, annotator, _|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    # File unchanged
    assert_equal "Just plain text, no sections.", File.read(path)
  end

  # --- --date flag ---

  def test_date_flag_sets_episode_id
    cmd = PodgenCLI::RevocabCommand.new(["testpod", "--date", "2026-03-10"], {})
    assert_equal "2026-03-10", cmd.instance_variable_get(:@episode_id)
  end

  def test_date_flag_with_positional_date_is_rejected
    # Passing both is ambiguous — fail loud rather than silently dropping one.
    err = assert_raises(OptionParser::ParseError) do
      PodgenCLI::RevocabCommand.new(["testpod", "2026-01-01", "--date", "2026-03-10"], {})
    end
    assert_includes err.message, "2026-01-01"
  end

  # --- dry run ---

  def test_dry_run_does_not_modify_files
    path = write_transcript("testpod-2026-03-10", body: "Original text.")
    original = File.read(path)

    cmd = build_command("testpod", nil, dry_run: true)
    # Bypass podcast validation for test
    stub_run_setup(cmd) do
      cmd.run
    end

    assert_equal original, File.read(path)
  end

  # --- --missing-only ---

  def test_missing_only_skips_transcripts_with_vocabulary
    write_transcript("testpod-2026-03-10", body: "Has vocab.", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-03-11", body: "No vocab here.")

    cmd = build_command_verbose("testpod", nil, dry_run: true, missing_only: true)

    output = capture_io { stub_run_setup(cmd) { cmd.run } }.first
    refute_includes output, "2026-03-10"
    assert_includes output, "2026-03-11"
  end

  def test_missing_only_false_processes_all
    write_transcript("testpod-2026-03-10", body: "Has vocab.", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-03-11", body: "No vocab here.")

    cmd = build_command_verbose("testpod", nil, dry_run: true)

    output = capture_io { stub_run_setup(cmd) { cmd.run } }.first
    assert_includes output, "2026-03-10"
    assert_includes output, "2026-03-11"
  end

  # --- missing config ---

  def test_run_fails_without_vocabulary_level
    cmd = build_command("testpod")
    config = build_stub_config
    config_no_vocab = Struct.new(*config.members, keyword_init: true)
      .new(**config.to_h.merge(vocabulary_level: nil))
    cmd.instance_variable_set(:@config, config_no_vocab)

    stub_run_setup(cmd) do
      result = cmd.run
      assert_equal 2, result
    end
  end

  def test_run_fails_without_api_key
    ENV.delete("ANTHROPIC_API_KEY")

    cmd = build_command("testpod")
    stub_run_setup(cmd) do
      result = cmd.run
      assert_equal 2, result
    end
  end

  private

  def write_transcript(basename, title: "Test Episode", description: "", body: "Some text.", vocab: nil)
    path = File.join(@episodes_dir, "#{basename}_transcript.md")
    content = "# #{title}\n\n"
    content += "#{description}\n\n" unless description.empty?
    content += "## Transcript\n\n#{body}"
    if vocab
      content += "\n\n## Vocabulary\n\n#{vocab}"
    end
    File.write(path, content)
    path
  end

  def build_command(podcast = "testpod", episode_id = nil, dry_run: false, missing_only: false)
    args = []
    args << "--missing-only" if missing_only
    args << podcast
    args << episode_id if episode_id
    opts = { dry_run: dry_run, verbosity: :quiet }
    cmd = PodgenCLI::RevocabCommand.new(args, opts)
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def build_command_verbose(podcast = "testpod", episode_id = nil, dry_run: false, missing_only: false)
    args = []
    args << "--missing-only" if missing_only
    args << podcast
    args << episode_id if episode_id
    opts = { dry_run: dry_run, verbosity: :normal }
    cmd = PodgenCLI::RevocabCommand.new(args, opts)
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def build_stub_config
    Struct.new(:podcast_dir, :episodes_dir, :transcription_language,
               :vocabulary_level, :vocabulary_max, :vocabulary_filters,
               :vocabulary_target_language, :vocabulary_target_languages,
               :history_path, :title, :description,
               :author, :languages, :base_url, :site_config, :type,
               keyword_init: true)
      .new(
        podcast_dir: @podcast_dir,
        episodes_dir: @episodes_dir,
        transcription_language: "sl",
        vocabulary_level: "B2",
        vocabulary_max: nil,
        vocabulary_filters: {},
        vocabulary_target_language: "English",
        vocabulary_target_languages: ["English"],
        history_path: File.join(@tmpdir, "history.yml"),
        title: "Test", description: nil, author: "Test",
        languages: ["sl"], base_url: nil, site_config: {},
        type: "language"
      )
  end

  def stub_logger
    logger = Object.new
    logger.define_singleton_method(:log) { |_| }
    logger.define_singleton_method(:error) { |_| }
    logger.define_singleton_method(:phase_start) { |_| }
    logger.define_singleton_method(:phase_end) { |_| }
    logger
  end

  def stub_run_setup(cmd)
    # Bypass require_podcast! and load_config! for unit tests
    cmd.define_singleton_method(:require_podcast!) { |_| nil }
    cmd.define_singleton_method(:load_config!) { @config }
    yield
  end

  def stub_annotator(marked_result, vocab_result)
    cmd = build_command("testpod")

    annotator = Object.new
    annotator.define_singleton_method(:annotate) { |text, **_| [marked_result, vocab_result] }

    logger = stub_logger
    yield cmd, annotator, logger
  end
end
