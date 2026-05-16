# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "cli/cover_command"

class TestCoverCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cover_cmd_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    FileUtils.mkdir_p(@podcast_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: Test Pod\n## Format\nfoo\n## Tone\nbar\n## Image\n- base_image: base.png")
    File.write(File.join(@podcast_dir, "base.png"), "fake image")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_no_podcast_returns_usage
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new([], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_extra_non_date_positional_raises_parse_error
    # Positional dates are accepted now; only true junk should error.
    err = assert_raises(OptionParser::ParseError) do
      PodgenCLI::CoverCommand.new(["testpod", "random-junk"], {})
    end
    assert_includes err.message, "random-junk"
  end

  def test_missing_base_image_returns_error
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: Test Pod\n## Format\nfoo\n## Tone\nbar")

    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "--title", "My Title"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "base_image"
  end

  def test_option_parsing_base_image
    cmd = PodgenCLI::CoverCommand.new(
      ["--base-image", "/tmp/custom.png", "testpod"], {})
    assert_equal "/tmp/custom.png", cmd.instance_variable_get(:@overrides)[:base_image]
  end

  def test_option_parsing_font_overrides
    cmd = PodgenCLI::CoverCommand.new(
      ["--font", "Arial", "--font-color", "#FF0000", "--font-size", "80", "testpod"], {})
    overrides = cmd.instance_variable_get(:@overrides)
    assert_equal "Arial", overrides[:font]
    assert_equal "#FF0000", overrides[:font_color]
    assert_equal 80, overrides[:font_size]
  end

  def test_option_parsing_geometry_short_flags
    cmd = PodgenCLI::CoverCommand.new(
      ["--gravity", "South", "--x-offset", "50", "--y-offset", "100", "--width", "600", "testpod"], {})
    overrides = cmd.instance_variable_get(:@overrides)
    assert_equal "South", overrides[:gravity]
    assert_equal 50, overrides[:x_offset]
    assert_equal 100, overrides[:y_offset]
    assert_equal 600, overrides[:width]
  end

  def test_option_parsing_text_prefix_long_flags_are_aliases
    cmd = PodgenCLI::CoverCommand.new(
      ["--text-gravity", "North", "--text-x-offset", "25", "--text-y-offset", "-100", "--text-width", "500", "testpod"], {})
    overrides = cmd.instance_variable_get(:@overrides)
    assert_equal "North", overrides[:gravity], "--text-gravity should alias to :gravity"
    assert_equal 25, overrides[:x_offset]
    assert_equal(-100, overrides[:y_offset])
    assert_equal 500, overrides[:width]
  end

  def test_option_parsing_output
    cmd = PodgenCLI::CoverCommand.new(
      ["--output", "/tmp/out.jpg", "testpod"], {})
    assert_equal "/tmp/out.jpg", cmd.instance_variable_get(:@output_path)
  end

  # --- --date / --title flags ---

  def test_date_flag_sets_episode_id
    cmd = PodgenCLI::CoverCommand.new(["testpod", "--date", "2026-04-13"], {})
    assert_equal "2026-04-13", cmd.normalized_episode_id
    assert_nil cmd.instance_variable_get(:@title)
  end

  def test_title_flag_sets_title
    cmd = PodgenCLI::CoverCommand.new(["testpod", "--title", "My Custom Title"], {})
    assert_equal "My Custom Title", cmd.instance_variable_get(:@title)
  end

  def test_date_and_title_flags_together
    cmd = PodgenCLI::CoverCommand.new(["testpod", "--date", "2026-04-13", "--title", "My Title"], {})
    assert_equal "2026-04-13", cmd.normalized_episode_id
    assert_equal "My Title", cmd.instance_variable_get(:@title)
  end

  # --- episode resolution ---

  def test_episode_resolves_title_and_output_path
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Medved z Nanosa\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod", "--date", "2026-03-10"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Medved z Nanosa", episodes[0][:title]
    assert_includes episodes[0][:output], "testpod-2026-03-10_cover.jpg"
  end

  def test_episode_not_found_returns_error
    # Valid date that no episode exists for.
    cmd = PodgenCLI::CoverCommand.new(["testpod", "--date", "2099-01-01"], {})

    _, err = capture_io { code = cmd.run; assert_equal 1, code }
    assert_includes err, "No episodes found"
  end

  def test_positional_date_equivalent_to_flag
    cmd = PodgenCLI::CoverCommand.new(["testpod", "2026-04-13"], {})
    assert_equal "2026-04-13", cmd.normalized_episode_id
  end

  def test_positional_short_date_with_suffix
    cmd = PodgenCLI::CoverCommand.new(["testpod", "0413b"], {})
    today = Date.today
    assert_equal "#{today.year}-04-13b", cmd.normalized_episode_id
  end

  def test_positional_and_date_flag_together_is_error
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::CoverCommand.new(["testpod", "2026-04-13", "--date", "2026-04-14"], {})
    end
  end

  # --- batch mode ---

  def test_batch_mode_resolves_all_transcripts
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 2, episodes.length
  end

  def test_batch_mode_single_episode
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod", "--date", "2026-03-10"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Ep One", episodes[0][:title]
  end

  def test_missing_only_skips_episodes_with_covers
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"), "fake")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["--missing-only", "testpod"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Ep Two", episodes[0][:title]
  end

  def test_dry_run_does_not_create_covers
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod"], { dry_run: true }).run
      assert_equal 0, code
    end

    refute File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"))
    assert_includes out, "dry-run"
  end

  def test_episode_generates_cover
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Test Title\n\n## Transcript\n\nText.")

    # Create a real base image
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "--date", "2026-03-10"], {}).run
      assert_equal 0, code
    end

    cover = File.join(episodes_dir, "testpod-2026-03-10_cover.jpg")
    assert File.exist?(cover)
    assert File.size(cover) > 0
  end

  def test_generates_cover_with_agent
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    output = File.join(@tmpdir, "cover_out.jpg")

    # Create a real 100x100 base image
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["--output", output, "testpod", "--title", "Test Title"], {}).run
      assert_equal 0, code
    end

    assert File.exist?(output)
    assert File.size(output) > 0
    assert_includes out, output
  end

  # --- --image option ---

  def test_image_copies_file_to_episode_cover
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-04-13_transcript.md"), "# Test Title\n\nBody.")

    image_path = File.join(@tmpdir, "my_cover.jpg")
    File.write(image_path, "fake jpg data")

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--date", "2026-04-13", "--image", image_path], {}).run
      assert_equal 0, code
    end

    cover = File.join(episodes_dir, "testpod-2026-04-13_cover.jpg")
    assert File.exist?(cover), "should copy image as episode cover"
    assert_equal "fake jpg data", File.read(cover)
    assert_includes out, "testpod-2026-04-13"
  end

  def test_image_requires_episode_id
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--image", "/tmp/some.jpg"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "--image requires a specific episode ID"
  end

  def test_image_rejects_manual_title_mode
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--title", "My Title", "--image", "/tmp/some.jpg"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "--image requires a specific episode ID"
  end

  def test_image_rejects_nonexistent_file
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--date", "2026-04-13", "--image", "/tmp/nonexistent.jpg"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "image file not found"
  end

  # --- --title + --date dispatch and output paths ---

  def test_title_with_date_routes_to_episode_mode_with_override_title
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"),
               "# Original Episode Title\n\n## Transcript\n\nText.")

    captured = capture_cover_agent_call do
      PodgenCLI::CoverCommand.new(
        ["testpod", "--date", "2026-03-10", "--title", "Custom Override"], {}).run
    end

    assert_equal "Custom Override", captured[:title]
    assert_equal File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"), captured[:output_path]
  end

  def test_title_alone_writes_preview_into_podcast_dir
    captured = capture_cover_agent_call do
      PodgenCLI::CoverCommand.new(["testpod", "--title", "Preview Title"], {}).run
    end

    assert_equal "Preview Title", captured[:title]
    expected = File.expand_path(File.join(@podcast_dir, "cover_preview.jpg"))
    assert_equal expected, captured[:output_path]
  end

  def test_title_with_explicit_output_uses_output_path
    out_path = File.join(@tmpdir, "my_preview.jpg")
    captured = capture_cover_agent_call do
      PodgenCLI::CoverCommand.new(
        ["testpod", "--title", "X", "--output", out_path], {}).run
    end

    assert_equal File.expand_path(out_path), captured[:output_path]
  end

  # --- --clean -------------------------------------------------

  def test_clean_removes_numbered_covers_from_specific_podcast
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"), "main")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover1.jpg"), "c1")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover2.png"), "c2")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover3.webp"), "c3")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover_old.jpg"), "old")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# x\n\nbody")

    capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "--clean"], {}).run
      assert_equal 0, code
    end

    refute File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover1.jpg"))
    refute File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover2.png"))
    refute File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover3.webp"))
    assert File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg")),
           "main cover must not be removed"
    assert File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover_old.jpg")),
           "_cover_old must not be removed (no digit after _cover)"
    assert File.exist?(File.join(episodes_dir, "testpod-2026-03-10_transcript.md")),
           "transcript must not be touched"
  end

  def test_clean_without_podcast_cleans_all_podcasts
    pod_a_dir = File.join(@tmpdir, "podcasts", "podA")
    pod_b_dir = File.join(@tmpdir, "podcasts", "podB")
    FileUtils.mkdir_p(pod_a_dir)
    FileUtils.mkdir_p(pod_b_dir)
    File.write(File.join(pod_a_dir, "guidelines.md"), "# A\n## Podcast\nName: A\n## Format\nx\n## Tone\nx")
    File.write(File.join(pod_b_dir, "guidelines.md"), "# B\n## Podcast\nName: B\n## Format\nx\n## Tone\nx")

    a_eps = File.join(@tmpdir, "output", "podA", "episodes")
    b_eps = File.join(@tmpdir, "output", "podB", "episodes")
    FileUtils.mkdir_p(a_eps)
    FileUtils.mkdir_p(b_eps)
    File.write(File.join(a_eps, "podA-2026-01-01_cover1.jpg"), "ax")
    File.write(File.join(b_eps, "podB-2026-01-01_cover2.png"), "bx")
    File.write(File.join(b_eps, "podB-2026-01-01_cover.jpg"), "main")

    capture_io do
      code = PodgenCLI::CoverCommand.new(["--clean"], {}).run
      assert_equal 0, code
    end

    refute File.exist?(File.join(a_eps, "podA-2026-01-01_cover1.jpg"))
    refute File.exist?(File.join(b_eps, "podB-2026-01-01_cover2.png"))
    assert File.exist?(File.join(b_eps, "podB-2026-01-01_cover.jpg"))
  end

  def test_clean_dry_run_does_not_delete
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover1.jpg"), "c1")

    capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "--clean"], { dry_run: true }).run
      assert_equal 0, code
    end

    assert File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover1.jpg")),
           "dry-run must not delete files"
  end

  # --- install_winner_as_cover ---

  def test_install_winner_returns_dest_when_source_is_jpg
    src = File.join(@tmpdir, "src.jpg")
    File.binwrite(src, "jpg-bytes")
    dest = File.join(@tmpdir, "out.jpg")

    cmd = PodgenCLI::CoverCommand.new(["testpod"], {})
    actual = cmd.send(:install_winner_as_cover, src, dest)
    assert_equal dest, actual
    assert File.exist?(dest)
  end

  def test_install_winner_preserves_real_extension_when_magick_unavailable
    src = File.join(@tmpdir, "src.png")
    File.binwrite(src, "png-bytes")
    dest = File.join(@tmpdir, "out.jpg")

    cmd = PodgenCLI::CoverCommand.new(["testpod"], {})
    # Force the magick branch to fail by stubbing system to return false
    cmd.stub :system, false do
      actual = cmd.send(:install_winner_as_cover, src, dest)
      assert_equal File.join(@tmpdir, "out.png"), actual
      assert File.exist?(actual)
      refute File.exist?(dest), "should NOT write .jpg-named file containing png bytes"
    end
  end

  # --- --image auto -------------------------------------------------------

  def test_image_auto_with_title_returns_error
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--image", "auto", "--title", "X"], {}).run
      assert_equal 1, code
    end
    assert_match(/--image auto.*--title/, err)
  end

  def test_image_auto_uses_resolver_winner_per_episode
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"),
               "# Ep One\n\nDesc one.\n\n## Transcript\n\nx.")

    captured_calls = []
    fake_resolver = Object.new
    fake_resolver.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      captured_calls << { title: title, description: description, basename: basename }
      winner = File.join(episodes_dir, "#{basename}_cover1.jpg")
      File.binwrite(winner, "winner-bytes")
      { winner_path: winner, top_paths: [winner], candidates: [{ score: 18 }] }
    end

    fake_agent = Object.new
    fake_agent.define_singleton_method(:generate) { |**_kw| nil }

    PodgenCLI::CoverCommand.const_get(:AutoCoverResolver).stub(:new, fake_resolver) do
      PodgenCLI::CoverCommand.const_get(:CoverAgent).stub(:new, fake_agent) do
        capture_io do
          code = PodgenCLI::CoverCommand.new(
            ["testpod", "--date", "2026-03-10", "--image", "auto"], {}).run
          assert_equal 0, code
        end
      end
    end

    cover = File.join(episodes_dir, "testpod-2026-03-10_cover.jpg")
    assert File.exist?(cover), "winner should be copied to episode cover path"
    assert_equal 1, captured_calls.length
    assert_equal "Ep One", captured_calls.first[:title]
    assert_equal "Desc one.", captured_calls.first[:description]
  end

  def test_image_auto_falls_back_to_cover_agent_when_no_winner
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"),
               "# Ep One\n\nDesc one.\n\n## Transcript\n\nx.")

    fake_resolver = Object.new
    fake_resolver.define_singleton_method(:try) do |**_kw|
      { winner_path: nil, top_paths: [], candidates: [] }
    end

    captured_agent = nil
    fake_agent = Object.new
    fake_agent.define_singleton_method(:generate) do |title:, base_image:, output_path:, options: {}|
      captured_agent = { title: title, output_path: output_path }
      output_path
    end

    PodgenCLI::CoverCommand.const_get(:AutoCoverResolver).stub(:new, fake_resolver) do
      PodgenCLI::CoverCommand.const_get(:CoverAgent).stub(:new, fake_agent) do
        capture_io do
          code = PodgenCLI::CoverCommand.new(
            ["testpod", "--date", "2026-03-10", "--image", "auto"], {}).run
          assert_equal 0, code
        end
      end
    end

    refute_nil captured_agent, "CoverAgent should be invoked as fallback"
    assert_equal "Ep One", captured_agent[:title]
    assert_includes captured_agent[:output_path], "testpod-2026-03-10_cover.jpg"
  end

  def test_image_auto_batch_runs_resolver_for_each_episode
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep A\n\nDA.\n\n## Transcript\n\nx.")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep B\n\nDB.\n\n## Transcript\n\nx.")

    invocations = []
    fake_resolver = Object.new
    fake_resolver.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      invocations << basename
      { winner_path: nil, top_paths: [], candidates: [] }
    end

    fake_agent = Object.new
    fake_agent.define_singleton_method(:generate) { |**_kw| nil }

    PodgenCLI::CoverCommand.const_get(:AutoCoverResolver).stub(:new, fake_resolver) do
      PodgenCLI::CoverCommand.const_get(:CoverAgent).stub(:new, fake_agent) do
        capture_io do
          code = PodgenCLI::CoverCommand.new(["testpod", "--image", "auto"], {}).run
          assert_equal 0, code
        end
      end
    end

    assert_equal 2, invocations.length
    assert_includes invocations, "testpod-2026-03-10"
    assert_includes invocations, "testpod-2026-03-11"
  end

  def test_image_dry_run_does_not_copy
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-04-13_transcript.md"), "# Test Title\n\nBody.")

    image_path = File.join(@tmpdir, "my_cover.png")
    File.write(image_path, "fake png data")

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["testpod", "--date", "2026-04-13", "--image", image_path], { dry_run: true }).run
      assert_equal 0, code
    end

    cover = File.join(episodes_dir, "testpod-2026-04-13_cover.png")
    refute File.exist?(cover), "should not copy in dry-run mode"
    assert_includes out, "dry-run"
  end

  private

  # Stubs CoverAgent so generate(...) records its args without actually
  # invoking magick/rsvg-convert. Returns the captured hash.
  def capture_cover_agent_call
    captured = {}
    fake = Object.new
    fake.define_singleton_method(:generate) do |title:, base_image:, output_path:, options: {}|
      captured[:title] = title
      captured[:base_image] = base_image
      captured[:output_path] = output_path
      captured[:options] = options
      output_path
    end

    PodgenCLI::CoverCommand.const_get(:CoverAgent).stub(:new, fake) do
      capture_io { yield }
    end
    captured
  end
end
