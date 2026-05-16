# frozen_string_literal: true

require_relative "../test_helper"
require "video_builder"

class TestVideoBuilder < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("video_builder")
    @mp3   = File.join(@tmpdir, "ep.mp3")
    @cover = File.join(@tmpdir, "ep_cover.jpg")
    @mp4   = File.join(@tmpdir, "ep.mp4")
    File.write(@mp3, "audio")
    File.write(@cover, "image")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── status: :exists ────────────────────────────────────────────────

  def test_build_returns_exists_when_mp4_already_present_and_no_force
    File.write(@mp4, "video")
    result = VideoBuilder.build(mp3_path: @mp3, cover_path: @cover, video_path: @mp4)
    assert_equal :exists, result.status
    assert_equal @mp4, result.video_path
  end

  # ── status: :no_cover ──────────────────────────────────────────────

  def test_build_returns_no_cover_when_cover_missing
    result = VideoBuilder.build(mp3_path: @mp3, cover_path: nil, video_path: @mp4)
    assert_equal :no_cover, result.status
  end

  def test_build_returns_no_cover_when_cover_path_does_not_exist
    result = VideoBuilder.build(mp3_path: @mp3, cover_path: "/nonexistent.jpg", video_path: @mp4)
    assert_equal :no_cover, result.status
  end

  # ── status: :no_audio ──────────────────────────────────────────────

  def test_build_returns_no_audio_when_mp3_missing
    result = VideoBuilder.build(mp3_path: "/nonexistent.mp3", cover_path: @cover, video_path: @mp4)
    assert_equal :no_audio, result.status
  end

  # ── status: :built (happy path) ────────────────────────────────────

  def test_build_calls_video_generator_and_returns_built
    captured = []
    fake_gen = Object.new
    fake_gen.define_singleton_method(:generate) do |audio, image, output|
      captured = [audio, image, output]
      File.write(output, "fake mp4")
      output
    end

    result = VideoGenerator.stub(:new, fake_gen) do
      VideoBuilder.build(mp3_path: @mp3, cover_path: @cover, video_path: @mp4)
    end

    assert_equal :built, result.status
    assert_equal @mp4, result.video_path
    assert_equal [@mp3, @cover, @mp4], captured
  end

  # ── --force regenerates even when existing ─────────────────────────

  def test_build_with_force_regenerates_existing_mp4
    File.write(@mp4, "stale")

    fake_gen = Object.new
    fake_gen.define_singleton_method(:generate) { |_a, _i, output| File.write(output, "new"); output }

    result = VideoGenerator.stub(:new, fake_gen) do
      VideoBuilder.build(mp3_path: @mp3, cover_path: @cover, video_path: @mp4, force: true)
    end

    assert_equal :built, result.status
    assert_equal "new", File.read(@mp4)
  end

  # ── status: :failed ────────────────────────────────────────────────

  def test_build_returns_failed_when_generator_raises
    fake_gen = Object.new
    fake_gen.define_singleton_method(:generate) { |*| raise "ffmpeg explode" }

    result = VideoGenerator.stub(:new, fake_gen) do
      VideoBuilder.build(mp3_path: @mp3, cover_path: @cover, video_path: @mp4)
    end

    assert_equal :failed, result.status
    assert_match(/ffmpeg explode/, result.message)
  end
end
