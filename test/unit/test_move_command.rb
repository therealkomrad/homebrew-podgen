# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "json"
require "cli/move_command"

class TestMoveCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_move")
    ENV["PODGEN_ROOT"] = @tmpdir
    @config = setup_fake_podcast("mypod")
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ───── single-episode form ─────────────────────────────────────────

  def test_single_renames_all_artifacts_to_target_date
    write_episode("mypod-2026-05-16")
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }

    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20_transcript.md"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20_timestamps.json"))
  end

  def test_single_with_source_suffix_preserves_target_when_bare
    # source has suffix d → user wants it on target as bare
    write_episode("mypod-2026-05-16d")
    stub_rss { run_move("mypod", "2026-05-16d", "2026-05-20") }
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20.mp3"))
  end

  def test_single_auto_suffixes_on_target_collision
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20")          # bare on target taken
    stub_rss { @code = run_move("mypod", "2026-05-16", "2026-05-20") }

    assert_equal 0, @code
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20.mp3"))   # original untouched
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20a.mp3"))  # moved here
  end

  def test_single_auto_suffixes_to_next_free_letter
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20")
    write_episode("mypod-2026-05-20a")
    write_episode("mypod-2026-05-20b")
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20c.mp3"))
  end

  def test_single_with_explicit_target_suffix_errors_when_taken
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20c")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16", "2026-05-20c") }
    assert_equal 1, @code
    assert_match(/exists/i, err)
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3")), "source must remain untouched"
  end

  def test_single_with_explicit_target_suffix_succeeds_when_free
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20")
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20c") }
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20c.mp3"))
  end

  def test_single_errors_when_source_missing
    _, err = capture_io { @code = run_move("mypod", "2026-05-16", "2026-05-20") }
    assert_equal 1, @code
    assert_match(/no episode/i, err)
  end

  def test_single_errors_when_source_missing_lists_nearby
    write_episode("mypod-2026-05-16a")
    write_episode("mypod-2026-05-16d")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16", "2026-05-20") }
    assert_match(/did you mean/i, err)
    assert_match(/mypod-2026-05-16a/, err)
    assert_match(/mypod-2026-05-16d/, err)
  end

  def test_single_errors_when_from_equals_to
    write_episode("mypod-2026-05-16")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16", "2026-05-16") }
    assert_equal 1, @code
    assert_match(/same/i, err)
  end

  def test_single_updates_history_entry
    write_episode("mypod-2026-05-16", with_history: { date: "2026-05-16", title: "Old", basename: "mypod-2026-05-16" })
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }

    hist = YAML.load_file(@config.history_path)
    entry = hist.find { |e| e["basename"] == "mypod-2026-05-20" }
    refute_nil entry, "history must contain the renamed entry"
    assert_equal "2026-05-20", entry["date"]
    assert_nil hist.find { |e| e["basename"] == "mypod-2026-05-16" }
  end

  def test_single_updates_upload_tracker
    write_episode("mypod-2026-05-16")
    uploads_path = File.join(File.dirname(@config.episodes_dir), "uploads.yml")
    File.write(uploads_path, YAML.dump(
      "lingq" => { "1234" => { "mypod-2026-05-16" => 999 } },
      "youtube" => { "PLabc" => { "mypod-2026-05-16" => "vid1" } }
    ))
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }

    data = YAML.load_file(uploads_path)
    assert_equal 999, data["lingq"]["1234"]["mypod-2026-05-20"]
    assert_equal "vid1", data["youtube"]["PLabc"]["mypod-2026-05-20"]
    refute data["lingq"]["1234"].key?("mypod-2026-05-16")
    refute data["youtube"]["PLabc"].key?("mypod-2026-05-16")
  end

  def test_single_moves_language_variants_together
    write_episode("mypod-2026-05-16")
    File.write(File.join(@config.episodes_dir, "mypod-2026-05-16-jp.mp3"), "audio")
    File.write(File.join(@config.episodes_dir, "mypod-2026-05-16-jp_script.md"), "jp")
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }

    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20-jp.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20-jp_script.md"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16-jp.mp3"))
  end

  def test_single_skips_concat_files
    write_episode("mypod-2026-05-16")
    File.write(File.join(@config.episodes_dir, "mypod-2026-05-16_concat.txt"), "scratch")
    stub_rss { run_move("mypod", "2026-05-16", "2026-05-20") }

    # _concat is intermediate scratch — left untouched at source path.
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16_concat.txt"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20_concat.txt"))
  end

  # ───── wildcard form ───────────────────────────────────────────────

  def test_wildcard_renames_all_same_day_episodes_preserving_suffixes
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-16a")
    write_episode("mypod-2026-05-16d")
    stub_rss { run_move("mypod", "2026-05-16+", "2026-05-20") }

    %w[mypod-2026-05-20 mypod-2026-05-20a mypod-2026-05-20d].each do |base|
      assert File.exist?(File.join(@config.episodes_dir, "#{base}.mp3")), "expected #{base}.mp3 to exist"
    end
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16a.mp3"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16d.mp3"))
  end

  def test_wildcard_errors_on_any_target_collision
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-16a")
    write_episode("mypod-2026-05-20c")  # unrelated collision on target date
    _, err = capture_io { @code = run_move("mypod", "2026-05-16+", "2026-05-20") }

    assert_equal 1, @code
    assert_match(/conflict|exists|already/i, err)
    # source must remain untouched
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16a.mp3"))
  end

  def test_wildcard_lists_conflicting_basenames_in_error
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20")
    write_episode("mypod-2026-05-20b")
    _, err = capture_io { run_move("mypod", "2026-05-16+", "2026-05-20") }
    assert_match(/mypod-2026-05-20/, err)
    assert_match(/mypod-2026-05-20b/, err)
  end

  def test_wildcard_rejects_target_with_suffix
    write_episode("mypod-2026-05-16")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16+", "2026-05-20c") }
    assert_equal 2, @code
    assert_match(/suffix/i, err)
  end

  def test_wildcard_rejects_target_with_wildcard
    write_episode("mypod-2026-05-16")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16+", "2026-05-20+") }
    assert_equal 2, @code
    assert_match(/wildcard|target/i, err)
  end

  def test_wildcard_rejects_same_source_target_date
    write_episode("mypod-2026-05-16")
    _, err = capture_io { @code = run_move("mypod", "2026-05-16+", "2026-05-16") }
    assert_equal 1, @code
    assert_match(/same/i, err)
  end

  def test_wildcard_errors_when_no_episodes_on_source_date
    _, err = capture_io { @code = run_move("mypod", "2026-05-16+", "2026-05-20") }
    assert_equal 1, @code
    assert_match(/no episodes/i, err)
  end

  # ───── pre-flight: no partial state ────────────────────────────────

  def test_validation_failure_leaves_source_untouched
    write_episode("mypod-2026-05-16")
    write_episode("mypod-2026-05-20c")
    capture_io { run_move("mypod", "2026-05-16", "2026-05-20c") }  # explicit suffix, collision
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16_transcript.md"))
  end

  # Regression: a File.rename failure mid-move used to leave half-renamed
  # state on disk + propagate a raw Ruby exception. Now the partial moves
  # are rolled back and a clear error surfaces with a non-zero exit code.
  def test_rename_failure_rolls_back_partial_state
    write_episode("mypod-2026-05-16")
    rename_call_count = 0
    failed_yet = false
    real_rename = File.method(:rename)

    # Use Minitest::Mock-style stub via the canonical File.stub helper so
    # the global File.rename is restored after the block — monkey-patching
    # via define_singleton_method + remove_method strips the C built-in
    # and breaks subsequent tests.
    failing_rename = lambda do |src, dst|
      rename_call_count += 1
      if rename_call_count == 3 && !failed_yet
        failed_yet = true
        raise Errno::ENOSPC, "disk full"
      end
      real_rename.call(src, dst)
    end

    err_text = nil
    File.stub(:rename, failing_rename) do
      stub_rss do
        _, err = capture_io { @code = run_move("mypod", "2026-05-16", "2026-05-20") }
        err_text = err
      end
    end
    assert_equal 1, @code
    assert_match(/disk full/, err_text)
    assert_match(/[Rr]oll(ed|ing).back/, err_text)

    # Source files must all be back in place.
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16.mp3"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16_transcript.md"))
    assert File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-16_timestamps.json"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20.mp3"))
    refute File.exist?(File.join(@config.episodes_dir, "mypod-2026-05-20_transcript.md"))
  end

  # ───── RSS regeneration is invoked ─────────────────────────────────

  def test_rss_regen_is_invoked_on_success
    write_episode("mypod-2026-05-16")
    invoked = false
    fake_rss = Object.new
    fake_rss.define_singleton_method(:run) { invoked = true; 0 }
    PodgenCLI::RssCommand.stub(:new, fake_rss) do
      run_move("mypod", "2026-05-16", "2026-05-20")
    end
    assert invoked, "MoveCommand should trigger RSS regeneration after a successful move"
  end

  private

  def run_move(*args)
    PodgenCLI::MoveCommand.new(args, { verbosity: :quiet }).run
  end

  def stub_rss
    fake_rss = Object.new
    fake_rss.define_singleton_method(:run) { 0 }
    PodgenCLI::RssCommand.stub(:new, fake_rss) { yield }
  end

  def setup_fake_podcast(name)
    require "podcast_config"
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", name))
    File.write(File.join(@tmpdir, "podcasts", name, "guidelines.md"), "## Podcast\n- name: #{name}\n")
    config = PodcastConfig.new(name)
    FileUtils.mkdir_p(config.episodes_dir)
    config
  end

  def write_episode(base, with_history: nil)
    dir = @config.episodes_dir
    File.write(File.join(dir, "#{base}.mp3"), "audio")
    File.write(File.join(dir, "#{base}_transcript.md"), "# T\n\n## Transcript\n\nC.\n")
    File.write(File.join(dir, "#{base}_timestamps.json"), JSON.pretty_generate(
      "version" => 1, "engine" => "groq", "intro_duration" => 0.0,
      "segments" => [{ "start" => 0.0, "end" => 1.0, "text" => "x" }]
    ))
    return unless with_history

    require "yaml"
    history_path = @config.history_path
    existing = File.exist?(history_path) ? YAML.load_file(history_path) : []
    existing << {
      "date" => with_history[:date],
      "title" => with_history[:title],
      "basename" => with_history[:basename]
    }
    File.write(history_path, YAML.dump(existing))
  end
end
