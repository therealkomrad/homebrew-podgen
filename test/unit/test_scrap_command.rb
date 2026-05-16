# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/scrap_command"

class TestScrapCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_scrap_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- resolve_by_id ---

  def test_resolve_by_id_parses_date_only
    File.write(File.join(@episodes_dir, "test-2026-03-15.mp3"), "x")

    cmd = build_command_with_id("2026-03-15")
    base, date, idx = cmd.send(:resolve_by_id, @episodes_dir)

    assert_equal "test-2026-03-15", base
    assert_equal "2026-03-15", date
    assert_equal 0, idx
  end

  def test_resolve_by_id_parses_date_with_suffix
    File.write(File.join(@episodes_dir, "test-2026-03-15b.mp3"), "x")

    cmd = build_command_with_id("2026-03-15b")
    base, date, idx = cmd.send(:resolve_by_id, @episodes_dir)

    assert_equal "test-2026-03-15b", base
    assert_equal "2026-03-15", date
    assert_equal 2, idx # "" is 0, "a" is 1, "b" is 2
  end

  def test_resolve_by_id_does_not_match_longer_suffix
    # test-2026-03-15a.mp3 exists but we're looking for test-2026-03-15
    File.write(File.join(@episodes_dir, "test-2026-03-15a.mp3"), "x")

    cmd = build_command_with_id("2026-03-15")
    result = cmd.send(:resolve_by_id, @episodes_dir)
    assert_nil result
  end

  def test_resolve_by_id_returns_nil_for_invalid_format
    cmd = build_command_with_id("not-a-date")
    result = cmd.send(:resolve_by_id, @episodes_dir)
    assert_nil result
  end

  def test_resolve_by_id_returns_nil_when_no_files_match
    cmd = build_command_with_id("2026-03-15")
    result = cmd.send(:resolve_by_id, @episodes_dir)
    assert_nil result
  end

  # --- find_history_entry ---

  def test_find_history_entry_by_basename
    entries = [
      { "date" => "2026-03-01", "title" => "First", "basename" => "pod-2026-03-01" },
      { "date" => "2026-03-01", "title" => "Second", "basename" => "pod-2026-03-01a" }
    ]
    cmd = build_command(stub_config)

    assert_equal "First", cmd.send(:find_history_entry, entries, "pod-2026-03-01")["title"]
    assert_equal "Second", cmd.send(:find_history_entry, entries, "pod-2026-03-01a")["title"]
    assert_nil cmd.send(:find_history_entry, entries, "pod-2026-03-99")
  end

  def test_find_history_entry_by_date_fallback
    entries = [
      { "date" => "2026-03-01", "title" => "First" },
      { "date" => "2026-03-01", "title" => "Second" },
      { "date" => "2026-03-02", "title" => "Third" }
    ]
    cmd = build_command(stub_config)

    assert_equal "First", cmd.send(:find_history_entry_by_date, entries, "2026-03-01", 0)["title"]
    assert_equal "Second", cmd.send(:find_history_entry_by_date, entries, "2026-03-01", 1)["title"]
    assert_equal "Third", cmd.send(:find_history_entry_by_date, entries, "2026-03-02", 0)["title"]
    assert_nil cmd.send(:find_history_entry_by_date, entries, "2026-03-05", 0)
  end

  # --- remove_upload_tracking ---

  def test_remove_upload_tracking_deletes_entry
    tracking = { "lingq" => { "123" => { "ep-a" => 1, "ep-b" => 2 } } }
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, tracking.to_yaml)

    config = stub_config
    cmd = build_command(config)
    cmd.send(:remove_upload_tracking, config, "ep-a")

    data = YAML.load_file(tracking_path)
    refute data["lingq"]["123"].key?("ep-a")
    assert_equal 2, data["lingq"]["123"]["ep-b"]
  end

  def test_remove_upload_tracking_preserves_other_collections
    tracking = {
      "lingq" => { "123" => { "ep-a" => 1 }, "456" => { "ep-x" => 10 } }
    }
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, tracking.to_yaml)

    config = stub_config
    cmd = build_command(config)
    cmd.send(:remove_upload_tracking, config, "ep-a")

    data = YAML.load_file(tracking_path)
    assert_equal 10, data["lingq"]["456"]["ep-x"]
  end

  def test_remove_upload_tracking_missing_file_no_error
    config = stub_config
    cmd = build_command(config)
    # Should not raise
    cmd.send(:remove_upload_tracking, config, "ep-a")
  end

  def test_remove_upload_tracking_no_matching_entry_no_rewrite
    tracking = { "lingq" => { "123" => { "ep-other" => 1 } } }
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, tracking.to_yaml)
    original_mtime = File.mtime(tracking_path)

    config = stub_config
    cmd = build_command(config)
    sleep 0.01
    cmd.send(:remove_upload_tracking, config, "ep-missing")

    # File should not be rewritten since no entry was removed
    assert_equal original_mtime, File.mtime(tracking_path)
  end

  def test_remove_upload_tracking_non_hash_file
    File.write(File.join(@tmpdir, "uploads.yml"), "just a string")

    config = stub_config
    cmd = build_command(config)
    # Should not raise
    cmd.send(:remove_upload_tracking, config, "ep-a")
  end

  def test_remove_upload_tracking_removes_from_all_platforms
    tracking = {
      "lingq" => { "123" => { "ep-a" => 1 } },
      "youtube" => { "PLabc" => { "ep-a" => "vid123" } }
    }
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, tracking.to_yaml)

    config = stub_config
    cmd = build_command(config)
    cmd.send(:remove_upload_tracking, config, "ep-a")

    data = YAML.load_file(tracking_path)
    refute data["lingq"]["123"].key?("ep-a")
    refute data["youtube"]["PLabc"].key?("ep-a")
  end

  # --- resolve_from_path ---

  def test_resolve_from_path_mp3
    cmd = PodgenCLI::ScrapCommand.allocate
    name, id = cmd.send(:resolve_from_path, "/output/lahko_noc/episodes/lahko_noc-2026-02-23.mp3")

    assert_equal "lahko_noc", name
    assert_equal "2026-02-23", id
  end

  def test_resolve_from_path_mp3_with_suffix
    cmd = PodgenCLI::ScrapCommand.allocate
    name, id = cmd.send(:resolve_from_path, "/output/lahko_noc/episodes/lahko_noc-2026-02-23b.mp3")

    assert_equal "lahko_noc", name
    assert_equal "2026-02-23b", id
  end

  def test_resolve_from_path_transcript_md
    cmd = PodgenCLI::ScrapCommand.allocate
    name, id = cmd.send(:resolve_from_path, "/output/lahko_noc/episodes/lahko_noc-2026-02-23_transcript.md")

    assert_equal "lahko_noc", name
    assert_equal "2026-02-23", id
  end

  def test_resolve_from_path_script_html
    cmd = PodgenCLI::ScrapCommand.allocate
    name, id = cmd.send(:resolve_from_path, "/output/fulgur_news/episodes/fulgur_news-2026-03-15a_script.html")

    assert_equal "fulgur_news", name
    assert_equal "2026-03-15a", id
  end

  def test_resolve_from_path_language_suffix
    cmd = PodgenCLI::ScrapCommand.allocate
    name, id = cmd.send(:resolve_from_path, "/output/ruby_world/episodes/ruby_world-2026-01-10-es.mp3")

    assert_equal "ruby_world", name
    assert_equal "2026-01-10", id
  end

  def test_resolve_from_path_returns_nil_for_unrecognized
    cmd = PodgenCLI::ScrapCommand.allocate
    result = cmd.send(:resolve_from_path, "/some/random/file.txt")

    assert_nil result
  end

  def test_initialize_accepts_file_path
    path = File.join(@episodes_dir, "test-2026-03-15.mp3")
    File.write(path, "x")

    cmd = PodgenCLI::ScrapCommand.new([path], {})

    assert_equal "test", cmd.instance_variable_get(:@podcast_name)
    assert_equal "2026-03-15", cmd.normalized_episode_id
  end

  def test_initialize_accepts_file_path_with_suffix
    path = File.join(@episodes_dir, "test-2026-03-15b_transcript.md")
    File.write(path, "text")

    cmd = PodgenCLI::ScrapCommand.new([path], {})

    assert_equal "test", cmd.instance_variable_get(:@podcast_name)
    assert_equal "2026-03-15b", cmd.normalized_episode_id
  end

  def test_initialize_accepts_positional_date
    cmd = PodgenCLI::ScrapCommand.new(["mypod", "2026-03-15"], {})
    assert_equal "mypod", cmd.instance_variable_get(:@podcast_name)
    assert_equal "2026-03-15", cmd.normalized_episode_id
  end

  def test_initialize_accepts_positional_date_short_form
    cmd = PodgenCLI::ScrapCommand.new(["mypod", "0315b"], {})
    today = Date.today
    assert_equal "#{today.year}-03-15b", cmd.normalized_episode_id
  end

  def test_initialize_accepts_date_flag
    cmd = PodgenCLI::ScrapCommand.new(["mypod", "--date", "2026-03-15"], {})
    assert_equal "2026-03-15", cmd.normalized_episode_id
  end

  def test_initialize_rejects_date_flag_and_positional_together
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::ScrapCommand.new(["mypod", "2026-03-15", "--date", "2026-03-16"], {})
    end
  end

  private

  StubScrapConfig = Struct.new(:episodes_dir, keyword_init: true)

  def stub_config
    StubScrapConfig.new(episodes_dir: @episodes_dir)
  end

  def build_command(config)
    cmd = PodgenCLI::ScrapCommand.allocate
    cmd.instance_variable_set(:@podcast_name, "test")
    cmd.instance_variable_set(:@episode_id, nil)
    cmd
  end

  def build_command_with_id(episode_id)
    cmd = PodgenCLI::ScrapCommand.allocate
    cmd.instance_variable_set(:@podcast_name, "test")
    cmd.instance_variable_set(:@episode_id, episode_id)
    cmd
  end
end
