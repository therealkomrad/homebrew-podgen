# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "upload_tracker")

module PodgenCLI
  class TweetCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--force", "Tweet even if already tweeted") { @options[:force] = true }
        opts.on("--dry-run", "Show tweet text without posting") { @options[:dry_run] = true }
        opts.on("--template TEXT", "Override tweet template") { |t| @options[:template] = t }
      end.parse!(args)

      @podcast_name = args.shift
      @episode_id = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("tweet")
      return code if code

      load_config!

      unless @config.twitter_config
        $stderr.puts "Twitter not configured. Add ## Twitter section to guidelines.md."
        return 2
      end

      unless @episode_id
        $stderr.puts "Usage: podgen tweet <podcast> <episode-id> [--force] [--dry-run]"
        $stderr.puts "  episode-id: date (2026-03-15) or date+suffix (2026-03-15b)"
        return 2
      end

      episode = find_episode
      return 1 unless episode

      tc = @config.twitter_config
      template = @options[:template] || tc[:template]
      title, description, = parse_transcript(episode[:transcript_path])
      mp3_url = @config.base_url ? "#{@config.base_url}/episodes/#{File.basename(episode[:mp3_path])}" : ""
      site_url = @config.site_episode_url(episode[:base_name]) || ""

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "agents", "twitter_agent")
      text = TwitterAgent.new(skip_auth: true).expand_template(
        template || TwitterAgent::DEFAULT_TEMPLATE, title: title, description: description.to_s, site_url: site_url, mp3_url: mp3_url
      )

      if @options[:dry_run]
        puts "[dry-run] Would tweet (#{text.length} chars):"
        puts text
        return 0
      end

      unless @config.twitter_enabled?
        $stderr.puts "TWITTER_* env vars not set. Set TWITTER_CONSUMER_KEY, TWITTER_CONSUMER_SECRET, TWITTER_ACCESS_TOKEN, TWITTER_ACCESS_SECRET in .env."
        return 2
      end

      tracker = UploadTracker.for_config(@config)
      already = tracker.entries_for(:twitter, "posts")
      if already.key?(episode[:base_name]) && !@options[:force]
        $stderr.puts "Already tweeted: \"#{title}\" — use --force to re-tweet"
        return 1
      end

      agent = TwitterAgent.new
      tweet_id = agent.post_episode(title: title, description: description.to_s, site_url: site_url, mp3_url: mp3_url, template: template)
      tracker.record(:twitter, "posts", episode[:base_name], tweet_id) if tweet_id
      puts "Tweeted: \"#{title}\" (#{tweet_id})"
      0
    rescue => e
      $stderr.puts "Error: #{e.message}"
      1
    end

    private

    def find_episode
      episodes_dir = @config.episodes_dir
      unless Dir.exist?(episodes_dir)
        $stderr.puts "No episodes directory: #{episodes_dir}"
        return nil
      end

      mp3s = Dir.glob(File.join(episodes_dir, "*.mp3")).sort
      matched = mp3s.select { |f| File.basename(f, ".mp3").end_with?(@episode_id) }

      if matched.empty?
        $stderr.puts "No episode found matching '#{@episode_id}'"
        return nil
      end

      mp3_path = matched.last
      base_name = File.basename(mp3_path, ".mp3")
      text_path = find_text_file(episodes_dir, base_name)

      unless text_path
        $stderr.puts "No transcript or script found for: #{base_name}"
        return nil
      end

      { base_name: base_name, mp3_path: mp3_path, transcript_path: text_path }
    end

    def find_text_file(dir, base_name)
      %w[_transcript.md _script.md].each do |suffix|
        path = File.join(dir, "#{base_name}#{suffix}")
        return path if File.exist?(path)
      end
      nil
    end

    def parse_transcript(path)
      content = File.read(path)
      lines = content.lines
      title = lines.first&.strip&.sub(/^#\s+/, "") || "Untitled"
      transcript_idx = lines.index { |l| l.strip.match?(/^## (Transcript|Script)/) }

      if transcript_idx
        desc_lines = lines[1...transcript_idx].map(&:strip).reject(&:empty?)
        description = desc_lines.join("\n")
        description = nil if description.empty?
      end

      [title, description]
    end
  end
end
