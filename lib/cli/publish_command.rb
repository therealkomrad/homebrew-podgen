# frozen_string_literal: true

require "open3"
require "optparse"
require "yaml"
require "fileutils"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "rss_command")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "episode_filtering")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "cover_resolver")
require_relative File.join(root, "lib", "regen_cache")
require_relative File.join(root, "lib", "r2_publisher")
require_relative File.join(root, "lib", "lingq_publisher")
require_relative File.join(root, "lib", "youtube_publisher")

module PodgenCLI
  class PublishCommand
    include PodcastCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

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
      result = R2Publisher.new(config: @config, options: @options).run
      return 2 if result.errors.any? { |e| %i[rclone_missing missing_env].include?(e[:type]) }
      return 1 if result.errors.any? { |e| e[:type] == :rclone_failed }
      0
    end

    def publish_to_lingq
      result = LingQPublisher.new(config: @config, options: @options).run
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
        uploader: build_youtube_uploader
      )
      result = publisher.run
      return 2 if result.errors.any? { |e| e[:type] == :not_configured }
      return 1 if result.errors.any? { |e| e[:type] == :playlist_verification }
      0
    end

    # Scans episodes dir for mp3 files that have matching transcripts.
    # Returns array of { base_name:, mp3_path:, transcript_path: } sorted chronologically.
    # When @episode_id is set, filters to matching episodes only.
    def scan_episodes
      episodes_dir = @config.episodes_dir
      return [] unless Dir.exist?(episodes_dir)

      all = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .sort
        .filter_map do |mp3_path|
          base_name = File.basename(mp3_path, ".mp3")
          text_path = find_text_file(episodes_dir, base_name)
          next unless text_path

          { base_name: base_name, mp3_path: mp3_path, transcript_path: text_path }
        end

      all.reverse! if @options[:newest]

      return all unless @episode_id

      matched = all.select { |ep| ep[:base_name].end_with?(@episode_id) }
      if matched.empty?
        $stderr.puts "No episode found matching '#{@episode_id}'"
      end
      matched
    end

    def find_text_file(dir, base_name)
      %w[_transcript.md _script.md].each do |suffix|
        path = File.join(dir, "#{base_name}#{suffix}")
        return path if File.exist?(path)
      end
      nil
    end

    def build_youtube_uploader
      YouTubeUploader.new
    end

    def reconcile_subtitles_if_needed(ts_path, transcript_path)
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "timestamp_persister")
      data = TimestampPersister.load(ts_path)
      return if data.nil? || data["reconciled"]

      api_key = ENV["ANTHROPIC_API_KEY"]
      return unless api_key && !api_key.empty?

      _, _, transcript_text = parse_transcript(transcript_path)
      return if transcript_text.nil? || transcript_text.strip.empty?

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "subtitle_reconciler")
      print "  reconciling subtitles: #{File.basename(ts_path)}..." unless @options[:verbosity] == :quiet
      segments = SubtitleReconciler.reconcile(data["segments"], transcript_text, api_key: api_key)
      TimestampPersister.update_segments(ts_path, segments)
      puts " done" unless @options[:verbosity] == :quiet
    rescue => e
      $stderr.puts "  Warning: subtitle reconciliation failed: #{e.message} (using raw segments)"
    end

    # Parses a transcript markdown file.
    # Returns [title, description, transcript_text]
    def parse_transcript(path)
      parsed = TranscriptParser.parse(path)
      [parsed.title, parsed.description, parsed.body]
    end

    # Check for a per-episode cover saved by generate --image
    def find_episode_cover(base_name)
      CoverResolver.find_episode_cover(@config.episodes_dir, base_name)
    end

    def generate_cover_image(title, description: nil)
      return @config.cover_static_image unless @config.cover_generation_enabled?

      result = CoverResolver.generate(
        title: title,
        base_image: @config.cover_base_image,
        options: @config.cover_options
      )
      unless result
        $stderr.puts "  Warning: cover generation failed (using static image)" if @options[:verbosity] == :verbose
      end
      result || @config.cover_static_image
    end

    def cleanup_cover(image_path)
      CoverResolver.cleanup(image_path)
    end

    # Retranscribe a final MP3 to generate timestamps for old episodes
    # that were created before timestamp persistence was added.
    def retranscribe_for_timestamps(mp3_path, ts_path, base_name)
      language = @config.transcription_language
      unless language
        puts "  ⚠ #{base_name}: no transcription language configured, skipping subtitles" unless @options[:verbosity] == :quiet
        return
      end

      engine_code = pick_timestamp_engine
      unless engine_code
        puts "  ⚠ #{base_name}: no transcription engine configured, skipping subtitles" unless @options[:verbosity] == :quiet
        return
      end

      puts "  transcribing #{base_name} for subtitles (#{engine_code})..." unless @options[:verbosity] == :quiet

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "transcription", "engine_manager")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "timestamp_persister")

      manager = Transcription::EngineManager.new(
        engine_codes: [engine_code],
        language: language,
        target_language: @config.target_language
      )
      result = manager.transcribe(mp3_path)
      segments, engine_code = TimestampPersister.extract_segments(result, engine_codes: [engine_code])

      if segments && !segments.empty?
        TimestampPersister.persist(
          segments: segments,
          engine: engine_code,
          intro_duration: 0.0,
          output_path: ts_path
        )
      else
        puts "  ⚠ #{base_name}: transcription returned no segments" unless @options[:verbosity] == :quiet
      end
    rescue => e
      # Non-fatal: video uploads proceed without subtitles
      $stderr.puts "  ⚠ #{base_name}: retranscription failed (#{e.message}), uploading without subtitles"
    end

    # Pick the best transcription engine for timestamps.
    # Groq has word-level, ElevenLabs has word-level, OpenAI has segment-level.
    TIMESTAMP_ENGINE_PRIORITY = %w[groq elab open].freeze

    def pick_timestamp_engine
      configured = @config.transcription_engines
      TIMESTAMP_ENGINE_PRIORITY.find { |e| configured.include?(e) } || configured.first
    end

    def upload_tracker
      @upload_tracker ||= UploadTracker.for_config(@config)
    end

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
