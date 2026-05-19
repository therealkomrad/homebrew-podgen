# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "rss_command")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "regen_cache")
require_relative File.join(root, "lib", "r2_publisher")
require_relative File.join(root, "lib", "lingq_publisher")
require_relative File.join(root, "lib", "youtube_publisher")

module PodgenCLI
  # Thin dispatcher over R2Publisher / LingQPublisher / YouTubePublisher.
  # All the per-target logic (rclone sync, LingQ upload, YouTube upload,
  # subtitle reconciliation, retranscription, cover generation, upload
  # tracking) lives in the publisher classes — this command only:
  #   - parses CLI flags
  #   - regenerates RSS + site once before dispatch (memoized via RegenCache)
  #   - threads @episode_id into each publisher
  #   - maps publisher errors to exit codes
  class PublishCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--lingq", "Publish to LingQ instead of R2") { @options[:lingq] = true }
        opts.on("--youtube", "Publish to YouTube") { @options[:youtube] = true }
        opts.on("--force", "Re-upload even if already tracked") { @options[:force] = true }
        opts.on("--newest", "Publish newest episodes first") { @options[:newest] = true }
        opts.on("--max N", Integer, "Cap number of YouTube uploads per invocation") { |n| @options[:max] = n }
        opts.on("--dry-run", "Show what would be published") { @options[:dry_run] = true }
        opts.on("--date DATE", "Episode date (YYYY-MM-DD)") { |v| @episode_id = v }
      end.parse!(args)
      @podcast_name = args.shift
      @episode_id ||= args.shift # optional: e.g. "2026-03-31" or "2026-03-31b"
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("publish")
      return code if code

      load_config!

      # Regenerate RSS feed and static site before publishing.
      # Memoized per-podcast in-process so batch flows (e.g. yt-batch) skip
      # repeated regen when the same publisher runs against the same pod.
      RegenCache.ensure_regen(@config) do
        regenerate_rss
        regenerate_site
      end

      if @options[:lingq] || @options[:youtube]
        code = publish_to_lingq if @options[:lingq]
        yt_code = publish_to_youtube if @options[:youtube]
        code || yt_code || 0
      else
        publish_to_r2
      end
    end

    private

    def regenerate_rss
      rss_opts = { verbosity: @options[:verbosity] }
      rss = RssCommand.new([@podcast_name], rss_opts)
      rss.run
    end

    def regenerate_site
      generator = SiteGenerator.new(config: @config, clean: true)
      generator.generate
    rescue => e
      $stderr.puts "Warning: site generation failed: #{e.message}" if @options[:verbosity] == :verbose
    end

    def publish_to_r2
      result = R2Publisher.new(config: @config, options: @options, episode_id: @episode_id).run
      return 2 if result.errors.any? { |e| %i[rclone_missing missing_env].include?(e[:type]) }
      return 1 if result.errors.any? { |e| e[:type] == :rclone_failed }
      0
    end

    def publish_to_lingq
      result = LingQPublisher.new(config: @config, options: @options, episode_id: @episode_id).run
      return 2 if result.errors.any? { |e| %i[not_configured no_language].include?(e[:type]) }
      0
    end

    def publish_to_youtube
      # Lazy-load the google-apis gems before constructing the uploader.
      # build_youtube_uploader instantiates YouTubeUploader; the constant must
      # exist at that call site, not deferred to YouTubePublisher#run.
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "youtube_uploader")

      publisher = YouTubePublisher.new(
        config: @config,
        options: @options,
        uploader: build_youtube_uploader,
        episode_id: @episode_id
      )
      result = publisher.run
      return 2 if result.errors.any? { |e| e[:type] == :not_configured }
      return 1 if result.errors.any? { |e| e[:type] == :playlist_verification }
      0
    end

    def build_youtube_uploader
      YouTubeUploader.new
    end
  end
end
