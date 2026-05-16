# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "cli/regen_command"

class TestRegenCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_regen")
    ENV["PODGEN_ROOT"] = @tmpdir
    @config = setup_fake_podcast("mypod")
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Option parsing ─────────────────────────────────────────────────

  def test_parses_video_flag
    cmd = PodgenCLI::RegenCommand.new(["mypod", "--video"], { verbosity: :quiet })
    assert cmd.instance_variable_get(:@video)
    refute cmd.instance_variable_get(:@subtitles)
    refute cmd.instance_variable_get(:@reconcile)
  end

  def test_parses_subtitles_flag
    cmd = PodgenCLI::RegenCommand.new(["mypod", "--subtitles"], { verbosity: :quiet })
    assert cmd.instance_variable_get(:@subtitles)
  end

  def test_parses_reconcile_flag
    cmd = PodgenCLI::RegenCommand.new(["mypod", "--reconcile"], { verbosity: :quiet })
    assert cmd.instance_variable_get(:@reconcile)
  end

  def test_all_flag_enables_everything
    cmd = PodgenCLI::RegenCommand.new(["mypod", "--all"], { verbosity: :quiet })
    assert cmd.instance_variable_get(:@video)
    assert cmd.instance_variable_get(:@subtitles)
    assert cmd.instance_variable_get(:@reconcile)
  end

  def test_accepts_positional_date
    cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--all"], { verbosity: :quiet })
    assert_equal Date.new(2026, 5, 16), cmd.episode_date
  end

  def test_accepts_short_positional_date
    cmd = PodgenCLI::RegenCommand.new(["mypod", "0516d", "--all"], { verbosity: :quiet })
    today = Date.today
    assert_equal Date.new(today.year, 5, 16), cmd.episode_date
    assert_equal "d", cmd.episode_suffix
  end

  # ── Error: no artifact flag ────────────────────────────────────────

  def test_run_errors_when_no_artifact_flag_given
    cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16"], { verbosity: :quiet })
    _, err = capture_io { @code = cmd.run }
    assert_equal 2, @code
    assert_match(/--video|--subtitles|--reconcile|--all/, err)
  end

  # ── --reconcile path ───────────────────────────────────────────────

  def test_reconcile_invokes_runner_with_force
    write_episode_files("mypod-2026-05-16")
    captured = {}
    fake_result = SubtitleReconciliationRunner::Result.new(status: :reconciled, message: "ok")
    SubtitleReconciliationRunner.stub(:run, ->(**kw) { captured = kw; fake_result }) do
      # --reconcile implies SRT regen too; stub the SRT generator so we don't
      # touch the real implementation in this test.
      SubtitleGenerator.stub(:generate_srt, ->(_, _) { true }) do
        cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--reconcile"], { verbosity: :quiet })
        cmd.run
      end
    end
    assert captured[:force], "regen should always force reconcile"
    assert_match(/_timestamps\.json\z/, captured[:ts_path])
  end

  def test_reconcile_alone_also_regenerates_srt
    write_episode_files("mypod-2026-05-16")
    srt_calls = []
    fake_result = SubtitleReconciliationRunner::Result.new(status: :reconciled, message: "ok")
    SubtitleReconciliationRunner.stub(:run, ->(**) { fake_result }) do
      SubtitleGenerator.stub(:generate_srt, ->(ts, srt) { srt_calls << [ts, srt]; true }) do
        cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--reconcile"], { verbosity: :quiet })
        cmd.run
      end
    end
    assert_equal 1, srt_calls.length
    assert_match(/\.srt\z/, srt_calls.first[1])
  end

  # ── --subtitles path ───────────────────────────────────────────────

  def test_subtitles_regenerates_srt_from_existing_timestamps
    write_episode_files("mypod-2026-05-16")
    srt_calls = []
    SubtitleGenerator.stub(:generate_srt, ->(ts, srt) { srt_calls << [ts, srt]; true }) do
      cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--subtitles"], { verbosity: :quiet })
      cmd.run
    end
    assert_equal 1, srt_calls.length
  end

  def test_subtitles_errors_when_timestamps_missing
    write_episode_files("mypod-2026-05-16", timestamps: false)
    _, err = capture_io do
      cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--subtitles"], { verbosity: :normal })
      @code = cmd.run
    end
    assert_equal 1, @code
    assert_match(/no timestamps|missing/i, err)
  end

  # ── --video path ───────────────────────────────────────────────────

  def test_video_calls_video_builder_with_force
    write_episode_files("mypod-2026-05-16", with_cover: true, with_mp4: true)
    captured = {}
    fake_result = VideoBuilder::Result.new(status: :built, video_path: "/x.mp4", message: "ok")
    VideoBuilder.stub(:build, ->(**kw) { captured = kw; fake_result }) do
      cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--video"], { verbosity: :quiet })
      cmd.run
    end
    assert captured[:force], "regen --video should force rebuild"
    assert_match(/\.mp4\z/, captured[:video_path])
  end

  def test_video_errors_when_cover_missing
    write_episode_files("mypod-2026-05-16", with_cover: false)
    fake_result = VideoBuilder::Result.new(status: :no_cover, message: "no cover")
    VideoBuilder.stub(:build, ->(**) { fake_result }) do
      _, err = capture_io do
        cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--video"], { verbosity: :normal })
        @code = cmd.run
      end
      assert_equal 1, @code
      assert_match(/cover/i, err)
    end
  end

  # ── --all path ─────────────────────────────────────────────────────

  def test_all_runs_three_steps_in_order
    write_episode_files("mypod-2026-05-16", with_cover: true)
    sequence = []
    fake_recon = SubtitleReconciliationRunner::Result.new(status: :reconciled, message: "ok")
    fake_video = VideoBuilder::Result.new(status: :built, video_path: "/x.mp4", message: "ok")

    SubtitleReconciliationRunner.stub(:run, ->(**) { sequence << :reconcile; fake_recon }) do
      SubtitleGenerator.stub(:generate_srt, ->(_, _) { sequence << :srt; true }) do
        VideoBuilder.stub(:build, ->(**) { sequence << :video; fake_video }) do
          cmd = PodgenCLI::RegenCommand.new(["mypod", "2026-05-16", "--all"], { verbosity: :quiet })
          cmd.run
        end
      end
    end

    assert_equal [:reconcile, :srt, :video], sequence
  end

  # ── default episode resolution: latest ─────────────────────────────

  def test_default_targets_latest_episode_when_no_date_given
    write_episode_files("mypod-2026-05-14", with_cover: true)
    write_episode_files("mypod-2026-05-16", with_cover: true)

    targeted = []
    fake_result = VideoBuilder::Result.new(status: :built, video_path: "/x.mp4", message: "ok")
    VideoBuilder.stub(:build, ->(**kw) { targeted << kw[:video_path]; fake_result }) do
      cmd = PodgenCLI::RegenCommand.new(["mypod", "--video"], { verbosity: :quiet })
      cmd.run
    end

    assert_equal 1, targeted.length
    assert_match(/2026-05-16/, targeted.first)
  end

  private

  def setup_fake_podcast(name)
    require "podcast_config"
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", name))
    File.write(File.join(@tmpdir, "podcasts", name, "guidelines.md"), "## Podcast\n- name: #{name}\n")
    config = PodcastConfig.new(name)
    FileUtils.mkdir_p(config.episodes_dir)
    config
  end

  def write_episode_files(base, timestamps: true, with_cover: false, with_mp4: false)
    dir = @config.episodes_dir
    File.write(File.join(dir, "#{base}_script.md"), "# T\n\n## Opening\n\nC.\n")
    File.write(File.join(dir, "#{base}_transcript.md"), "# T\n\n## Transcript\n\nC.\n")
    File.write(File.join(dir, "#{base}.mp3"), "audio")
    if timestamps
      File.write(File.join(dir, "#{base}_timestamps.json"), JSON.pretty_generate(
        "version" => 1, "engine" => "groq", "intro_duration" => 0.0,
        "segments" => [{ "start" => 0.0, "end" => 1.0, "text" => "x" }]
      ))
    end
    File.write(File.join(dir, "#{base}_cover.jpg"), "img") if with_cover
    File.write(File.join(dir, "#{base}.mp4"), "video") if with_mp4
  end
end
