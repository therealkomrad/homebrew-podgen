# frozen_string_literal: true

require "open3"
require "date"
require_relative "regen_cache"
require_relative "upload_tracker"
require_relative "transcript_parser"
require_relative "episode_filtering"
require_relative "episode_scanner"

# Syncs a podcast's public-facing files (mp3s, feed, site) to Cloudflare R2
# and posts tweets for newly-uploaded episodes (when Twitter is configured).
#
# Extracted from PublishCommand#publish_to_r2 + #tweet_new_episodes so that
# UploadsCommand can drive R2/LingQ/YT through a uniform Result-returning
# interface and so RegenCache memoization works across them in-process.
class R2Publisher
  REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze
  INCLUDE_GLOBS = [
    "episodes/*.mp3",
    "episodes/*.html",
    # Persist the transcript/script markdown too. The feed generator reads these
    # .md files to build each item's title and content:encoded transcript; if they
    # aren't synced to R2, every prior episode loses its .md on the next run's pull
    # and collapses to a stub (generic title, no transcript). See RssGenerator.
    "episodes/*.md",
    "feed.xml",
    "feed-*.xml",
    "site/*.html",
    "site/**/*.html",
    "site/**/*_cover.*",
    "site/style.css",
    "site/custom.css",
    "site/favicon.*"
  ].freeze

  Result = Struct.new(:synced, :tweets_posted, :errors, keyword_init: true) do
    def success? = errors.empty?
    def failed? = !success?
  end

  # `runner:` invoked as `runner.call(env: Hash, args: Array)` returning truthy on success;
  #   defaults to a real `system(env, *args)` call.
  # `twitter_agent:` injectable for tests; in production lazy-loaded from agents/twitter_agent.
  # `rclone_available:` injectable boolean; nil means "actually probe via Open3".
  def initialize(config:, options: {}, runner: nil, twitter_agent: nil, tracker_path: nil, rclone_available: nil, episode_id: nil)
    @config = config
    @options = options
    @runner = runner
    @twitter_agent = twitter_agent
    @tracker_path = tracker_path
    @rclone_available_override = rclone_available
    @episode_id = episode_id
  end

  def run
    unless rclone_available?
      msg = "rclone is not installed. Install with: brew install rclone"
      $stderr.puts msg
      return Result.new(synced: false, tweets_posted: 0,
                        errors: [{ type: :rclone_missing, message: msg }])
    end

    missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
    unless missing.empty?
      msg = "Missing required environment variables: #{missing.join(', ')}"
      $stderr.puts msg
      $stderr.puts "Set them in .env or podcasts/#{@config.name}/.env"
      return Result.new(synced: false, tweets_posted: 0,
                        errors: [{ type: :missing_env, message: msg }])
    end

    RegenCache.ensure_regen(@config) { regenerate! }

    success = run_rclone_sync
    unless success
      $stderr.puts "rclone failed."
      return Result.new(synced: false, tweets_posted: 0,
                        errors: [{ type: :rclone_failed, message: "rclone sync exited non-zero" }])
    end

    print_urls

    tweets_posted = @options[:dry_run] ? 0 : tweet_new_episodes

    Result.new(synced: true, tweets_posted: tweets_posted, errors: [])
  end

  private

  def regenerate!
    require_relative "cli/rss_command"
    require_relative "site_generator"
    PodgenCLI::RssCommand.new([@config.name], { verbosity: @options[:verbosity] }).run
    SiteGenerator.new(config: @config, clean: true).generate
  rescue => e
    $stderr.puts "Warning: site/feed regen failed: #{e.message}" if @options[:verbosity] == :verbose
  end

  def rclone_available?
    return @rclone_available_override unless @rclone_available_override.nil?
    _out, _err, status = Open3.capture3("rclone", "--version")
    status.success?
  rescue Errno::ENOENT
    false
  end

  def run_rclone_sync
    source_dir = File.dirname(@config.episodes_dir) # output/<podcast>/
    dest = "r2:#{ENV['R2_BUCKET']}/#{@config.name}/"

    includes = INCLUDE_GLOBS.dup
    includes << @config.image if @config.respond_to?(:image) && @config.image

    args = ["rclone", "sync", source_dir, dest]
    includes.each { |f| args.push("--include", f) }
    args.push("--dry-run") if @options[:dry_run]
    args.push("-v") if @options[:verbosity] == :verbose
    args.push("--progress") unless @options[:verbosity] == :quiet

    env = {
      "RCLONE_CONFIG_R2_TYPE" => "s3",
      "RCLONE_CONFIG_R2_PROVIDER" => "Cloudflare",
      "RCLONE_CONFIG_R2_ACCESS_KEY_ID" => ENV["R2_ACCESS_KEY_ID"],
      "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY" => ENV["R2_SECRET_ACCESS_KEY"],
      "RCLONE_CONFIG_R2_ENDPOINT" => ENV["R2_ENDPOINT"],
      "RCLONE_CONFIG_R2_ACL" => "private"
    }

    puts "Syncing #{source_dir} → #{dest}" unless quiet?
    puts "(dry run)" if @options[:dry_run] && !quiet?

    if @runner
      @runner.call(env: env, args: args)
    else
      system(env, *args)
    end
  end

  def print_urls
    return if quiet?
    if @config.respond_to?(:base_url) && @config.base_url
      puts "Feed URL: #{@config.base_url}/feed.xml"
      puts "Site URL: #{@config.base_url}/site/index.html"
    else
      puts "Done. Set base_url in guidelines.md to see feed URL."
    end
  end

  def tweet_new_episodes
    return 0 unless @config.twitter_enabled?

    tc = @config.twitter_config
    cutoff = Date.today - (tc[:since] || 7)
    template = tc[:template]

    eligible = scan_eligible_episodes(cutoff, tc[:languages])
    return 0 if eligible.empty?

    agent = active_twitter_agent
    posted = 0
    eligible.each do |ep|
      title, description, = parse_transcript(ep[:transcript_path])
      mp3_url = @config.base_url ? "#{@config.base_url}/episodes/#{File.basename(ep[:mp3_path])}" : ""
      site_url = @config.site_episode_url(ep[:base_name]) || ""

      tweet_id = agent.post_episode(title: title, description: description, site_url: site_url, mp3_url: mp3_url, template: template)
      tracker.record(:twitter, "posts", ep[:base_name], tweet_id) if tweet_id
      posted += 1
      puts "Tweeted: #{title}" unless quiet?
    end
    posted
  rescue => e
    $stderr.puts "Warning: Twitter posting failed: #{e.message} (non-fatal)"
    0
  end

  def scan_eligible_episodes(cutoff, allowed_langs)
    episodes = scan_episodes
    tweeted = tracker.entries_for(:twitter, "posts")
    episodes = episodes.reject { |ep| tweeted.key?(ep[:base_name]) }

    episodes.select! do |ep|
      date = EpisodeFiltering.parse_date(ep[:base_name])
      date && date >= cutoff
    end

    unless allowed_langs == :all
      allowed = Array(allowed_langs).empty? ? [@config.primary_language] : allowed_langs
      episodes.select! { |ep| allowed.include?(@config.language_for_episode(ep[:base_name])) }
    end
    episodes
  end

  def active_twitter_agent
    return @twitter_agent if @twitter_agent
    require_relative "agents/twitter_agent"
    TwitterAgent.new(logger: nil)
  end

  # Used only by tweet_new_episodes — the rclone sync above runs against
  # the include-globs wholesale and is intentionally not episode-scoped.
  def scan_episodes
    EpisodeScanner.scan(@config.episodes_dir, episode_id: @episode_id)
  end

  def parse_transcript(path)
    parsed = TranscriptParser.parse(path)
    [parsed.title, parsed.description, parsed.body]
  end

  def tracker
    @tracker ||= @tracker_path ? UploadTracker.new(@tracker_path) : UploadTracker.for_config(@config)
  end

  def quiet?
    @options[:verbosity] == :quiet
  end
end
