# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "optparse"

# Load CLI dispatcher + all commands
require "cli"
require "cli/generate_command"
require "cli/publish_command"
require "cli/translate_command"
require "cli/stats_command"
require "cli/validate_command"
require "cli/scrap_command"
require "cli/rss_command"

class TestCLIOptions < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cli_test")
    build_test_podcast(@tmpdir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Invalid options should fail with exit 2 ──────────────────────

  def test_generate_rejects_unknown_option
    code, _, err = run_cli("generate", "test_pod", "--bogus")
    assert_equal 2, code
    assert_includes err, "invalid option: --bogus"
  end

  def test_publish_rejects_unknown_option
    code, _, err = run_cli("publish", "test_pod", "--lingk")
    assert_equal 2, code
    assert_includes err, "invalid option: --lingk"
  end

  def test_translate_rejects_unknown_option
    code, _, err = run_cli("translate", "test_pod", "--langs")
    assert_equal 2, code
    assert_includes err, "invalid option: --langs"
  end

  def test_stats_rejects_unknown_option
    code, _, err = run_cli("stats", "test_pod", "--everything")
    assert_equal 2, code
    assert_includes err, "invalid option: --everything"
  end

  def test_validate_rejects_unknown_option
    code, _, err = run_cli("validate", "test_pod", "--verbose-all")
    assert_equal 2, code
    assert_includes err, "invalid option: --verbose-all"
  end

  def test_rss_rejects_unknown_option
    code, _, err = run_cli("rss", "test_pod", "--format")
    assert_equal 2, code
    assert_includes err, "invalid option: --format"
  end

  def test_rss_rejects_missing_argument
    code, _, err = run_cli("rss", "test_pod", "--base-url")
    assert_equal 2, code
    assert_includes err, "missing argument: --base-url"
  end

  def test_global_rejects_unknown_option
    code, _, err = run_cli("--bogus", "generate", "test_pod")
    assert_equal 2, code
    assert_includes err, "invalid option: --bogus"
  end

  # ── Malformed long options / unexpected positional args ─────────
  # OptionParser does unique-prefix matching from short-option syntax to
  # long options: `-rss babi` becomes `--rss=ss` with `babi` left over as
  # a positional. Without a leftover-args check, that residue is silently
  # dropped. These tests pin the loud-fail behavior.

  def test_generate_rejects_single_dash_long_option
    code, _, err = run_cli("generate", "test_pod", "-rss", "babi")
    assert_equal 2, code
    assert_includes err, "babi"
  end

  def test_generate_rejects_unexpected_positional_arg
    code, _, err = run_cli("generate", "test_pod", "extra_arg")
    assert_equal 2, code
    assert_includes err, "extra_arg"
  end

  def test_publish_rejects_third_positional_arg
    # publish accepts <podcast> [episode_id] — a 3rd positional is leftover.
    code, _, err = run_cli("publish", "test_pod", "2026-01-15", "extra_arg")
    assert_equal 2, code
    assert_includes err, "extra_arg"
  end

  def test_rss_rejects_unexpected_positional_arg
    code, _, err = run_cli("rss", "test_pod", "extra_arg")
    assert_equal 2, code
    assert_includes err, "extra_arg"
  end

  # ── Typos near valid options should fail ─────────────────────────

  def test_publish_lingq_typo
    code, _, err = run_cli("publish", "test_pod", "--lingk")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end

  def test_generate_dry_run_typo
    code, _, err = run_cli("generate", "test_pod", "--dryrun")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end

  # ── Mutual exclusivity guards ───────────────────────────────────

  def test_generate_rejects_ask_trim_with_skip
    code, _, err = run_cli("generate", "test_pod", "--ask-trim", "--skip", "10")
    assert_equal 1, code
    assert_includes err, "--ask-trim is mutually exclusive"
  end

  def test_generate_rejects_ask_trim_with_no_skip
    code, _, err = run_cli("generate", "test_pod", "--ask-trim", "--no-skip")
    assert_equal 1, code
    assert_includes err, "--ask-trim is mutually exclusive"
  end

  def test_generate_rejects_ask_trim_with_cut
    code, _, err = run_cli("generate", "test_pod", "--ask-trim", "--cut", "30")
    assert_equal 1, code
    assert_includes err, "--ask-trim is mutually exclusive"
  end

  def test_generate_rejects_ask_trim_with_no_cut
    code, _, err = run_cli("generate", "test_pod", "--ask-trim", "--no-cut")
    assert_equal 1, code
    assert_includes err, "--ask-trim is mutually exclusive"
  end

  def test_generate_rejects_ask_skip_alias_with_skip
    # --ask-skip is an alias for --ask-trim
    code, _, err = run_cli("generate", "test_pod", "--ask-skip", "--skip", "10")
    assert_equal 1, code
    assert_includes err, "--ask-trim is mutually exclusive"
  end

  # ── --date duplicate episode guard ─────────────────────────────

  def test_generate_date_rejects_existing_episode
    # Create a fake episode mp3 for the target date
    episodes_dir = File.join(@tmpdir, "output", "test_pod", "episodes")
    File.write(File.join(episodes_dir, "test_pod-2026-01-15.mp3"), "fake")

    code, _, err = run_cli("generate", "test_pod", "--date", "2026-01-15")
    assert_equal 1, code
    assert_includes err, "episode already exists for 2026-01-15"
  end

  def test_generate_date_allows_with_force
    episodes_dir = File.join(@tmpdir, "output", "test_pod", "episodes")
    File.write(File.join(episodes_dir, "test_pod-2026-01-15.mp3"), "fake")

    # --force + --dry-run so it doesn't actually run the pipeline
    code, _, err = run_cli("generate", "test_pod", "--date", "2026-01-15", "--force", "--dry-run")
    refute_includes err, "episode already exists"
  end

  # ── Valid options should be accepted ─────────────────────────────

  def test_generate_accepts_dry_run
    code, _, _ = run_cli("--dry-run", "generate", "test_pod")
    assert_equal 0, code
  end

  def test_generate_accepts_skip_and_cut
    cmd = PodgenCLI::GenerateCommand.new(
      ["--skip", "5", "--cut", "10", "test_pod"],
      { dry_run: true }
    )
    assert_in_delta 5.0, cmd.instance_variable_get(:@options)[:skip]
    assert_in_delta 10.0, cmd.instance_variable_get(:@options)[:cut]
  end

  def test_generate_accepts_long_form_skip_and_cut
    cmd = PodgenCLI::GenerateCommand.new(
      ["--skip-intro", "3", "--cut-outro", "7", "test_pod"],
      { dry_run: true }
    )
    assert_in_delta 3.0, cmd.instance_variable_get(:@options)[:skip]
    assert_in_delta 7.0, cmd.instance_variable_get(:@options)[:cut]
  end

  def test_generate_accepts_minsec_skip
    cmd = PodgenCLI::GenerateCommand.new(
      ["--skip", "1:20", "test_pod"],
      { dry_run: true }
    )
    skip_val = cmd.instance_variable_get(:@options)[:skip]
    assert_in_delta 80.0, skip_val
    assert skip_val.absolute?
  end

  def test_generate_accepts_minsec_cut
    cmd = PodgenCLI::GenerateCommand.new(
      ["--cut", "11:20", "test_pod"],
      { dry_run: true }
    )
    cut_val = cmd.instance_variable_get(:@options)[:cut]
    assert_in_delta 680.0, cut_val
    assert cut_val.absolute?
  end

  def test_publish_accepts_lingq
    cmd = PodgenCLI::PublishCommand.new(["--lingq", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:lingq]
  end

  def test_publish_accepts_dry_run
    cmd = PodgenCLI::PublishCommand.new(["--dry-run", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:dry_run]
  end

  def test_translate_accepts_last_and_lang
    cmd = PodgenCLI::TranslateCommand.new(
      ["--last", "3", "--lang", "it", "test_pod"], {}
    )
    assert_equal 3, cmd.instance_variable_get(:@last_n)
    assert_equal "it", cmd.instance_variable_get(:@lang_filter)
  end

  def test_translate_accepts_dry_run
    cmd = PodgenCLI::TranslateCommand.new(["--dry-run", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:dry_run]
  end

  def test_stats_accepts_all
    cmd = PodgenCLI::StatsCommand.new(["--all"], {})
    assert_equal true, cmd.instance_variable_get(:@all)
  end

  def test_stats_today_sets_days_1
    cmd = PodgenCLI::StatsCommand.new(["--today", "test_pod"], {})
    assert_equal 1, cmd.instance_variable_get(:@days)
    assert_equal true, cmd.instance_variable_get(:@downloads)
  end

  def test_stats_week_sets_days_7
    cmd = PodgenCLI::StatsCommand.new(["--week", "test_pod"], {})
    assert_equal 7, cmd.instance_variable_get(:@days)
    assert_equal true, cmd.instance_variable_get(:@downloads)
  end

  def test_stats_month_sets_days_30
    cmd = PodgenCLI::StatsCommand.new(["--month", "test_pod"], {})
    assert_equal 30, cmd.instance_variable_get(:@days)
    assert_equal true, cmd.instance_variable_get(:@downloads)
  end

  def test_validate_accepts_all
    cmd = PodgenCLI::ValidateCommand.new(["--all"], {})
    assert_equal true, cmd.instance_variable_get(:@all)
  end

  def test_rss_accepts_base_url
    cmd = PodgenCLI::RssCommand.new(["--base-url", "https://example.com", "test_pod"], {})
    assert_equal "https://example.com", cmd.instance_variable_get(:@options)[:base_url]
  end

  # ── Generate language pipeline flags ─────────────────────────────

  def test_generate_accepts_file_flag
    cmd = PodgenCLI::GenerateCommand.new(["--file", "/tmp/test.mp3", "test_pod"], {})
    assert_equal "/tmp/test.mp3", cmd.instance_variable_get(:@options)[:file]
  end

  def test_generate_accepts_url_flag
    cmd = PodgenCLI::GenerateCommand.new(["--url", "https://youtube.com/watch?v=abc", "test_pod"], {})
    assert_equal "https://youtube.com/watch?v=abc", cmd.instance_variable_get(:@options)[:url]
  end

  def test_generate_accepts_title_flag
    cmd = PodgenCLI::GenerateCommand.new(["--title", "My Episode", "test_pod"], {})
    assert_equal "My Episode", cmd.instance_variable_get(:@options)[:title]
  end

  def test_generate_accepts_image_flags
    cmd = PodgenCLI::GenerateCommand.new(
      ["--image", "/tmp/cover.jpg", "--base-image", "/tmp/base.jpg", "test_pod"], {}
    )
    assert_equal "/tmp/cover.jpg", cmd.instance_variable_get(:@options)[:image]
    assert_equal "/tmp/base.jpg", cmd.instance_variable_get(:@options)[:base_image]
  end

  def test_generate_accepts_lingq_flag
    cmd = PodgenCLI::GenerateCommand.new(["--lingq", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:lingq]
  end

  def test_generate_accepts_autotrim_flag
    cmd = PodgenCLI::GenerateCommand.new(["--autotrim", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:autotrim]
  end

  def test_generate_accepts_force_flag
    cmd = PodgenCLI::GenerateCommand.new(["--force", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:force]
  end

  def test_generate_accepts_snip
    cmd = PodgenCLI::GenerateCommand.new(["--snip", "1:20-2:30", "test_pod"], {})
    snip = cmd.instance_variable_get(:@options)[:snip]
    assert_instance_of SnipInterval, snip
    assert_equal 1, snip.intervals.length
    assert_in_delta 80.0, snip.intervals[0].from
    assert_in_delta 150.0, snip.intervals[0].to
  end

  def test_generate_accepts_multi_snip
    cmd = PodgenCLI::GenerateCommand.new(["--snip", "10-20,1:00+30", "test_pod"], {})
    snip = cmd.instance_variable_get(:@options)[:snip]
    assert_instance_of SnipInterval, snip
    assert_equal 2, snip.intervals.length
    assert_in_delta 10.0, snip.intervals[0].from
    assert_in_delta 20.0, snip.intervals[0].to
    assert_in_delta 60.0, snip.intervals[1].from
    assert_in_delta 90.0, snip.intervals[1].to
  end

  # ── Unknown command should fail ──────────────────────────────────

  def test_unknown_command_fails
    code, _, err = run_cli("frobnicate", "test_pod")
    assert_equal 2, code
    assert_includes err, "Unknown command: frobnicate"
  end

  def test_no_command_shows_help
    code, out, _ = run_cli
    assert_equal 2, code
    assert_includes out, "Usage:"
  end

  private

  def run_cli(*args)
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    code = PodgenCLI.run(args.flatten)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def build_language_podcast(dir)
    pod = File.join(dir, "podcasts", "lang_pod")
    out = File.join(dir, "output", "lang_pod", "episodes")
    FileUtils.mkdir_p([pod, out])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Lang Pod
      - type: language

      ## Audio
      - language: it
      - engine:
        - open
    MD
  end

  def build_test_podcast(dir)
    pod = File.join(dir, "podcasts", "test_pod")
    out = File.join(dir, "output", "test_pod", "episodes")
    FileUtils.mkdir_p([pod, out])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Test Pod

      ## Format
      - Short episodes

      ## Tone
      Casual.

      ## Topics
      - Testing
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => ["testing"]))
  end
end
