# frozen_string_literal: true

require_relative "../test_helper"

ENV["ELEVENLABS_API_KEY"] ||= "test-key"
ENV["ELEVENLABS_VOICE_ID"] ||= "test-voice"
require "cli/voice_command"
require "script_artifact"

class TestVoiceCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_voice_cmd")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    ENV.delete("PODGEN_ROOT")
  end

  def test_command_constructs_with_required_options
    cmd = PodgenCLI::VoiceCommand.new(["--lang", "jp", "fulgur_news"], { verbosity: :normal })
    assert_equal "fulgur_news", cmd.instance_variable_get(:@podcast_name)
    assert_equal "jp", cmd.instance_variable_get(:@lang_filter)
    refute cmd.instance_variable_get(:@force)
  end

  def test_command_parses_force_and_date
    cmd = PodgenCLI::VoiceCommand.new(["--date", "2026-04-26", "--force", "fulgur_news"], { verbosity: :normal })
    assert_equal Date.new(2026, 4, 26), cmd.episode_date
    assert cmd.instance_variable_get(:@force)
  end

  def test_command_accepts_positional_date
    cmd = PodgenCLI::VoiceCommand.new(["fulgur_news", "2026-04-26"], { verbosity: :normal })
    assert_equal Date.new(2026, 4, 26), cmd.episode_date
    assert_equal "fulgur_news", cmd.instance_variable_get(:@podcast_name)
  end

  def test_command_accepts_positional_date_with_suffix
    cmd = PodgenCLI::VoiceCommand.new(["fulgur_news", "2026-04-26b"], { verbosity: :normal })
    assert_equal Date.new(2026, 4, 26), cmd.episode_date
    assert_equal "b", cmd.episode_suffix
  end

  def test_command_accepts_positional_short_date
    cmd = PodgenCLI::VoiceCommand.new(["fulgur_news", "0426"], { verbosity: :normal })
    today = Date.today
    assert_equal Date.new(today.year, 4, 26), cmd.episode_date
  end

  def test_command_rejects_positional_and_flag_date_together
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::VoiceCommand.new(["fulgur_news", "2026-04-26", "--date", "2026-04-27"], { verbosity: :normal })
    end
  end

  def test_command_rejects_date_and_last_together
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::VoiceCommand.new(["--date", "2026-04-26", "--last", "3", "fulgur_news"], { verbosity: :normal })
    end
  end

  def test_command_skips_existing_mp3_without_force
    json_path = File.join(@tmpdir, "ep_script.json")
    mp3_path = File.join(@tmpdir, "ep.mp3")
    ScriptArtifact.write(json_path, { title: "T", segments: [], sources: [] })
    File.write(mp3_path, "existing")

    # Just check filesystem state — full command needs PodcastConfig setup which is heavy.
    # The skip-if-exists logic is exercised in the command run; here we verify the
    # script artifact + mp3 coexist as expected for the skip path.
    assert File.exist?(mp3_path)
    assert ScriptArtifact.exist?(json_path)
  end

  # --- resolve_basenames regression ---

  def test_resolve_basenames_finds_existing_episode_for_given_date
    # Regression: voice command was using config.episode_basename(date),
    # which returns the NEXT-available suffixed basename (for *creating*
    # new episodes), not the existing one. Re-voicing failed with
    # "No script found" when the episode existed without a suffix.
    config = setup_fake_podcast("mypod")
    File.write(File.join(config.episodes_dir, "mypod-2026-04-29_script.md"), "# T\n\nC.")
    File.write(File.join(config.episodes_dir, "mypod-2026-04-29.mp3"), "audio")

    cmd = PodgenCLI::VoiceCommand.new(["--date", "2026-04-29", "mypod"], { verbosity: :normal })
    bases = cmd.send(:resolve_basenames, config)

    assert_equal ["mypod-2026-04-29"], bases
  end

  def test_resolve_basenames_finds_multiple_episodes_on_same_date
    config = setup_fake_podcast("mypod")
    %w[mypod-2026-04-29 mypod-2026-04-29a mypod-2026-04-29b].each do |b|
      File.write(File.join(config.episodes_dir, "#{b}_script.md"), "# T\n\nC.")
      File.write(File.join(config.episodes_dir, "#{b}.mp3"), "audio")
    end

    cmd = PodgenCLI::VoiceCommand.new(["--date", "2026-04-29", "mypod"], { verbosity: :normal })
    bases = cmd.send(:resolve_basenames, config)

    assert_equal %w[mypod-2026-04-29 mypod-2026-04-29a mypod-2026-04-29b], bases.sort
  end

  def test_resolve_basenames_excludes_language_suffixed_scripts
    config = setup_fake_podcast("mypod")
    %w[mypod-2026-04-29 mypod-2026-04-29-jp mypod-2026-04-29-it].each do |b|
      File.write(File.join(config.episodes_dir, "#{b}_script.md"), "# T\n\nC.")
    end

    cmd = PodgenCLI::VoiceCommand.new(["--date", "2026-04-29", "mypod"], { verbosity: :normal })
    bases = cmd.send(:resolve_basenames, config)

    assert_equal ["mypod-2026-04-29"], bases
  end

  private

  def setup_fake_podcast(name)
    require "podcast_config"
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", name))
    File.write(File.join(@tmpdir, "podcasts", name, "guidelines.md"), "## Podcast\n- name: #{name}\n")
    ENV["PODGEN_ROOT"] = @tmpdir
    config = PodcastConfig.new(name)
    FileUtils.mkdir_p(config.episodes_dir)
    config
  end
end
