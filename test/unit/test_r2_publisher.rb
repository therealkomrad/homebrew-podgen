# frozen_string_literal: true

require_relative "../test_helper"
require "r2_publisher"
require "regen_cache"

class TestR2Publisher < Minitest::Test
  ENV_KEYS = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

  def setup
    @tmpdir = Dir.mktmpdir("podgen_r2_pub")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @uploads_path = File.join(@tmpdir, "uploads.yml")
    RegenCache.reset!

    @saved_env = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    ENV_KEYS.each { |k| ENV[k] = "test_value_for_#{k}" }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def test_success_returns_synced_true_and_no_errors
    seed_ep("ep-2026-01-15")
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true })

    result = nil
    capture_io { result = publisher.run }

    assert result.success?
    assert result.synced
    assert_empty result.errors
  end

  def test_rclone_failure_sets_rclone_failed_error
    seed_ep("ep-2026-01-15")
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { false })

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    refute result.synced
    assert_equal :rclone_failed, result.errors.first[:type]
  end

  def test_missing_env_returns_missing_env_error
    ENV["R2_BUCKET"] = nil
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true })

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    refute result.synced
    assert_equal :missing_env, result.errors.first[:type]
    assert_includes result.errors.first[:message], "R2_BUCKET"
  end

  def test_rclone_missing_returns_rclone_missing_error
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true }, rclone_available: false)

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    assert_equal :rclone_missing, result.errors.first[:type]
  end

  def test_dry_run_does_not_tweet
    seed_ep("ep-2026-01-15")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets),
      options: { dry_run: true }
    )

    capture_io { publisher.run }

    assert_empty tweets
  end

  def test_tweets_new_episodes_on_success_when_twitter_enabled
    seed_ep("ep-2026-05-01")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_equal 1, tweets.length, "should tweet the one new ep"
  end

  def test_does_not_tweet_when_twitter_disabled
    seed_ep("ep-2026-05-01")
    config = stub_config(twitter_enabled: false)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_empty tweets
  end

  def test_does_not_tweet_when_rclone_failed
    seed_ep("ep-2026-05-01")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { false },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_empty tweets, "no tweets when sync failed"
  end

  # Regression: --date used to be ignored on the R2 path (same bug as
  # YouTube and LingQ). The rclone sync itself stays wholesale by design,
  # but the Twitter side-effect must respect the filter — otherwise
  # `publish <pod> --date X` would tweet about every untweeted episode.
  def test_episode_id_filters_tweets_to_matching_episode
    seed_ep("ep-2026-05-01")
    seed_ep("ep-2026-05-02")
    seed_ep("ep-2026-05-03")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets),
      episode_id: "2026-05-02"
    )

    capture_io { publisher.run }

    assert_equal 1, tweets.length
    assert_match(/ep-2026-05-02/, tweets.first)
  end

  def test_calls_regen_cache_once_per_pod
    seed_ep("ep-2026-01-15")
    config = stub_config
    regen_calls = 0
    publisher = build_publisher(config: config, runner: ->(*) { true })
    publisher.define_singleton_method(:regenerate!) { regen_calls += 1 }

    capture_io { publisher.run }
    capture_io { build_publisher(config: config, runner: ->(*) { true }).tap { |p| p.define_singleton_method(:regenerate!) { regen_calls += 1 } }.run }

    assert_equal 1, regen_calls, "RegenCache memo must skip regen on second call for same pod"
  end

  private

  StubR2Config = Struct.new(:episodes_dir, :name, :base_url, :image,
    :transcription_language, :_twitter, keyword_init: true) do
    def initialize(episodes_dir:, name: "test_pod", base_url: "https://example.com",
                   image: nil, transcription_language: "en", _twitter: nil)
      super
    end
    def twitter_enabled? = !_twitter.nil?
    def twitter_config = _twitter
    def primary_language = transcription_language
    def language_for_episode(_) = transcription_language
    def site_episode_url(b) = "#{base_url}/site/episodes/#{b}.html"
  end

  def stub_config(twitter_enabled: false)
    tw = twitter_enabled ? { since: 30, template: "{title}", languages: :all } : nil
    StubR2Config.new(
      episodes_dir: @episodes_dir,
      name: "test_pod",
      base_url: "https://example.com",
      transcription_language: "en",
      _twitter: tw
    )
  end

  def seed_ep(base)
    File.write(File.join(@episodes_dir, "#{base}.mp3"), "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_transcript.md"), "# Title #{base}\n\nDescription text\n\n## Transcript\n\nBody.\n")
  end

  def build_publisher(config:, runner:, twitter_agent: nil, options: {}, rclone_available: true, episode_id: nil)
    R2Publisher.new(
      config: config,
      options: options,
      runner: runner,
      twitter_agent: twitter_agent,
      tracker_path: @uploads_path,
      rclone_available: rclone_available,
      episode_id: episode_id
    )
  end

  def stub_twitter_agent(tweets)
    agent = Object.new
    agent.define_singleton_method(:post_episode) do |title:, **_|
      tweets << title
      "tw_#{tweets.length}"
    end
    agent
  end
end
