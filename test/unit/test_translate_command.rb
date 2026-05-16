# frozen_string_literal: true

require_relative "../test_helper"
require "cli/translate_command"

class TestTranslateCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_translate_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- discover_episodes ---

  def test_discover_episodes_finds_english_scripts_with_mp3
    create_script("mypod-2026-01-15_script.md", "# Title\n\n## Opening\n\nHello.")
    create_mp3("mypod-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal 1, episodes.length
    assert_equal "mypod-2026-01-15", episodes.first[:basename]
  end

  def test_discover_episodes_excludes_language_suffixed_scripts
    create_script("mypod-2026-01-15_script.md", "# English")
    create_script("mypod-2026-01-15-es_script.md", "# Spanish")
    create_mp3("mypod-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal 1, episodes.length
    assert_equal "mypod-2026-01-15", episodes.first[:basename]
  end

  def test_discover_episodes_excludes_orphaned_scripts
    create_script("mypod-2026-01-15_script.md", "# Title")
    # No matching MP3

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_empty episodes
  end

  def test_discover_episodes_sorted_chronologically
    create_script("mypod-2026-01-15_script.md", "# A")
    create_script("mypod-2026-01-16_script.md", "# B")
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-16.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal "mypod-2026-01-15", episodes.first[:basename]
    assert_equal "mypod-2026-01-16", episodes.last[:basename]
  end

  # --- pending_translations ---

  def test_pending_translations_finds_missing_mp3s
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [{ "code" => "es", "voice_id" => "voice1" }]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_equal 1, pending.length
    assert_equal "es", pending.first[:lang_code]
    assert_equal "voice1", pending.first[:voice_id]
  end

  def test_pending_translations_skips_existing_mp3s
    create_mp3("a-es.mp3")
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [{ "code" => "es", "voice_id" => nil }]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_empty pending
  end

  def test_pending_translations_includes_existing_mp3s_when_forced
    create_mp3("a-es.mp3")
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [{ "code" => "es", "voice_id" => "v1" }]

    cmd = build_command
    cmd.instance_variable_set(:@force, true)
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_equal 1, pending.length
    assert_equal "es", pending.first[:lang_code]
  end

  def test_pending_translations_multiple_languages
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [
      { "code" => "es", "voice_id" => nil },
      { "code" => "fr", "voice_id" => nil }
    ]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_equal 2, pending.length
    codes = pending.map { |p| p[:lang_code] }
    assert_includes codes, "es"
    assert_includes codes, "fr"
  end

  # --- parse_script / save_script roundtrip ---

  def test_parse_script_extracts_title_and_segments
    path = create_script("test_script.md", <<~MD)
      # My Title

      ## Opening

      Welcome to the show.

      ## Main Topic

      Here is the content.
    MD

    cmd = build_command
    script = cmd.send(:parse_script, path)

    assert_equal "My Title", script[:title]
    assert_equal 2, script[:segments].length
    assert_equal "Opening", script[:segments].first[:name]
    assert_equal "Welcome to the show.", script[:segments].first[:text]
  end

  def test_save_script_writes_markdown
    cmd = build_command
    script = {
      title: "Translated Title",
      segments: [
        { name: "Apertura", text: "Bienvenidos." },
        { name: "Tema", text: "Contenido aquí." }
      ]
    }
    path = File.join(@episodes_dir, "output_script.md")
    cmd.send(:save_script, script, path)

    content = File.read(path)
    assert_includes content, "# Translated Title"
    assert_includes content, "## Apertura"
    assert_includes content, "Bienvenidos."
  end

  def test_save_script_renders_links_when_config_provided
    # Regression: translate command was rendering markdown without links_config,
    # producing markdown inconsistent with generate command. Sources existed in
    # the JSON artifact but never made it into the rendered _script.md.
    cmd = build_command
    script = {
      title: "T",
      segments: [
        { name: "Open", text: "Hello.",
          sources: [{ url: "https://example.com/a", title: "Article A" }] }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "ep_script.md")
    links_config = { show: true, position: "inline", title: "Links", max: 5 }
    cmd.send(:save_script, script, path, links_config: links_config)

    content = File.read(path)
    assert_includes content, "https://example.com/a", "expected source URL when links_config given"
    assert_includes content, "Article A"
  end

  def test_save_script_omits_links_when_config_nil
    cmd = build_command
    script = {
      title: "T",
      segments: [
        { name: "Open", text: "Hello.",
          sources: [{ url: "https://example.com/a", title: "Article A" }] }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "ep2_script.md")
    cmd.send(:save_script, script, path, links_config: nil)

    refute_includes File.read(path), "https://example.com/a"
  end

  def test_save_script_creates_parent_directory
    cmd = build_command
    script = {
      title: "Test Title",
      segments: [{ name: "Intro", text: "Hello." }]
    }
    nested = File.join(@tmpdir, "new_subdir", "deep")
    path = File.join(nested, "output_script.md")

    cmd.send(:save_script, script, path)

    assert File.exist?(path)
    assert_includes File.read(path), "# Test Title"
  end

  def test_parse_save_roundtrip
    original = {
      title: "Round Trip",
      segments: [
        { name: "Section One", text: "First text." },
        { name: "Section Two", text: "Second text." }
      ]
    }

    path = File.join(@episodes_dir, "roundtrip.md")
    cmd = build_command
    cmd.send(:save_script, original, path)
    parsed = cmd.send(:parse_script, path)

    assert_equal original[:title], parsed[:title]
    assert_equal original[:segments].length, parsed[:segments].length
    assert_equal "Section One", parsed[:segments].first[:name]
    assert_equal "First text.", parsed[:segments].first[:text]
  end

  private

  def create_script(name, content)
    path = File.join(@episodes_dir, name)
    File.write(path, content)
    path
  end

  def create_mp3(name)
    File.write(File.join(@episodes_dir, name), "x" * 1000)
  end

  def build_command
    PodgenCLI::TranslateCommand.allocate
  end

  public

  # --- date selection ---

  def test_command_accepts_date_flag
    cmd = PodgenCLI::TranslateCommand.new(["--date", "2026-01-15", "mypod"], {})
    assert_equal Date.new(2026, 1, 15), cmd.episode_date
  end

  def test_command_accepts_positional_date
    cmd = PodgenCLI::TranslateCommand.new(["mypod", "2026-01-15"], {})
    assert_equal Date.new(2026, 1, 15), cmd.episode_date
  end

  def test_command_accepts_positional_short_date
    cmd = PodgenCLI::TranslateCommand.new(["mypod", "0115"], {})
    today = Date.today
    assert_equal Date.new(today.year, 1, 15), cmd.episode_date
  end

  def test_command_rejects_date_and_last_together
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::TranslateCommand.new(["--date", "2026-01-15", "--last", "3", "mypod"], {})
    end
  end

  def test_filter_by_date_matches_full_date
    cmd = build_command
    episodes = [
      { basename: "mypod-2026-01-15" },
      { basename: "mypod-2026-01-15b" },
      { basename: "mypod-2026-01-16" }
    ]
    result = cmd.send(:filter_by_date, episodes, Date.new(2026, 1, 15), nil)
    assert_equal 2, result.length
    refute(result.any? { |e| e[:basename].include?("01-16") })
  end

  def test_filter_by_date_narrows_to_suffix
    cmd = build_command
    episodes = [
      { basename: "mypod-2026-01-15" },
      { basename: "mypod-2026-01-15a" },
      { basename: "mypod-2026-01-15b" }
    ]
    result = cmd.send(:filter_by_date, episodes, Date.new(2026, 1, 15), "a")
    assert_equal [{ basename: "mypod-2026-01-15a" }], result
  end
end
