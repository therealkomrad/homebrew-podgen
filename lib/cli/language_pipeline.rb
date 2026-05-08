# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "uri"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "audio_trimmer")
require_relative File.join(root, "lib", "episode_source")
require_relative File.join(root, "lib", "transcription", "engine_manager")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "agents", "lingq_agent")
require_relative File.join(root, "lib", "agents", "cover_agent")
require_relative File.join(root, "lib", "agents", "description_agent")
require_relative File.join(root, "lib", "youtube_downloader")
require_relative File.join(root, "lib", "vocabulary_annotator")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "timestamp_persister")
require_relative File.join(root, "lib", "subtitle_generator")
require_relative File.join(root, "lib", "video_generator")
require_relative File.join(root, "lib", "url_cleaner")
require_relative File.join(root, "lib", "transcript_discovery")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "cover_resolver")
require_relative File.join(root, "lib", "auto_cover_resolver")

module PodgenCLI
  class LanguagePipeline
    def initialize(config:, options:, logger:, history:, today:)
      @config = config
      @options = options
      @dry_run = options[:dry_run] || false
      @local_file = options[:file]
      @youtube_url = options[:url]
      @rss_filter = options[:rss]
      @file_title = options[:title]
      @logger = logger
      @history = history
      @today = today
      @temp_files = []
      @warnings = []
      @youtube_captions = nil
      @episode_source = EpisodeSource.new(config: config, history: history, logger: logger)
      @staging_dir = File.join(File.dirname(config.episodes_dir), "episodes_staged")
    end

    def run
      @pipeline_start = Time.now
      logger.log("Language pipeline started#{@dry_run ? ' (DRY RUN)' : ''}")

      code = validate_image_options
      return code if code

      code = acquire_episode
      return code if code

      setup_staging
      return 0 if trim_source_audio == :excluded
      discover_transcript
      transcribe
      clean_or_generate_description(@episode, @reconciled_text || @transcription_result[:text])
      trim_outro
      assemble_episode
      persist_timestamps
      reconcile_subtitles
      save_transcript_and_cover
      annotate_vocabulary if @config.vocabulary_level
      commit_episode
      upload_to_lingq(@episode, @reconciled_text || @transcript, @output_path, @base_name) if @options[:lingq]
      upload_to_youtube if @options[:youtube]

      log_completion
      0
    rescue => e
      logger.error("#{e.class}: #{e.message}")
      logger.error(e.backtrace.first(5).join("\n"))
      $stderr.puts "\n\u2717 Language pipeline failed: #{e.message}" unless @options[:verbosity] == :quiet
      1
    ensure
      cleanup_temp_files
      cleanup_staging
    end

    private

    attr_reader :logger

    def setup_staging
      FileUtils.rm_rf(@staging_dir)
      FileUtils.mkdir_p(@staging_dir)
    end

    # Moves all staged files to episodes/ and writes history atomically.
    def commit_episode
      logger.phase_start("Commit")
      staged_files = Dir.glob(File.join(@staging_dir, "*"))
      staged_files.each do |src|
        dest = File.join(@config.episodes_dir, File.basename(src))
        FileUtils.mv(src, dest)
      end
      @output_path = File.join(@config.episodes_dir, "#{@base_name}.mp3")
      record_history
      logger.log("Committed #{staged_files.length} file(s) to #{@config.episodes_dir}")
      logger.phase_end("Commit")
    end

    # Removes staging dir if it still exists (on failure or after commit).
    def cleanup_staging
      FileUtils.rm_rf(@staging_dir) if @staging_dir && Dir.exist?(@staging_dir)
    end

    # Validates --image option early. Returns exit code on error, nil on success.
    def validate_image_options
      if @options[:image] == "thumb" && !@youtube_url
        $stderr.puts "Error: --image thumb is only valid with --url (YouTube)"
        return 1
      end

      if @options[:image] == "last"
        screenshot = Dir.glob(File.join(Dir.home, "Desktop", "Screenshot *.png")).max_by { |f| File.mtime(f) }
        unless screenshot
          $stderr.puts "Error: no screenshots found on ~/Desktop"
          return 1
        end
        @options[:image] = screenshot
        logger.log("Resolved --image last → #{screenshot}")
      end

      nil
    end

    # Acquires episode metadata + source audio from local file, YouTube, or RSS.
    # Sets @episode and @source_audio_path on success.
    # Returns exit code on early exit (dry-run, error, dedup), nil on success.
    def acquire_episode
      if @local_file
        acquire_local_file
      elsif @youtube_url
        acquire_youtube
      else
        acquire_rss
      end
    end

    def acquire_local_file
      logger.phase_start("Local File")
      @episode = @episode_source.build_local(@local_file, @file_title)
      logger.log("Local file: \"#{@episode[:title]}\" (#{@local_file})")
      logger.phase_end("Local File")

      return 1 if @episode_source.already_processed?(@episode, force: @options[:force], dry_run: @dry_run)

      if @dry_run
        log_dry_run("Config validated, local file \"#{@episode[:title]}\" — no API calls")
        return 0
      end

      @source_audio_path = File.expand_path(@local_file)
      nil
    end

    def acquire_youtube
      if @dry_run
        logger.log("[dry-run] YouTube URL: #{@youtube_url}")
        log_dry_run("Config validated, YouTube URL provided — no API calls")
        return 0
      end

      logger.phase_start("YouTube")
      downloader = YouTubeDownloader.new(logger: logger)
      metadata = downloader.fetch_metadata(@youtube_url)
      @episode = @episode_source.build_youtube(metadata, title_override: @file_title)
      logger.log("YouTube video: \"#{@episode[:title]}\" (#{metadata[:duration]}s)")
      logger.phase_end("YouTube")

      return 1 if @episode_source.already_processed?(@episode, force: @options[:force], dry_run: @dry_run)

      logger.phase_start("Download Audio")
      @source_audio_path = downloader.download_audio(@youtube_url)
      @temp_files << @source_audio_path
      logger.log("Downloaded YouTube audio: #{(File.size(@source_audio_path) / (1024.0 * 1024)).round(2)} MB")
      logger.phase_end("Download Audio")

      # Download thumbnail (always — used as fallback or via --image thumb)
      thumb_path = downloader.download_thumbnail(@youtube_url)
      if thumb_path
        @temp_files << thumb_path
        @youtube_thumbnail = thumb_path
      end

      # Fetch captions in target language (non-fatal)
      caption_lang = @config.transcription_language
      if caption_lang
        @youtube_captions = downloader.fetch_captions(@youtube_url, language: caption_lang)
      end

      nil
    end

    def acquire_rss
      logger.phase_start("Fetch Episode")
      @episode = @episode_source.fetch_next(force: @options[:force], rss_filter: @rss_filter)
      unless @episode
        logger.error("No new episodes found in RSS feeds")
        return 1
      end
      @episode[:title] = @file_title if @file_title
      ep_info = "\"#{@episode[:title]}\""
      ep_info += " (#{@episode[:duration]})" if @episode[:duration]
      ep_info += " [#{(@episode[:file_size] / (1024.0 * 1024)).round(1)} MB]" if @episode[:file_size]&.positive?
      logger.log("Selected episode: #{ep_info}")
      logger.log("  URL: #{@episode[:audio_url]}")
      # Stash per-feed image config for resolve_episode_cover
      @current_episode_feed_base_image = @episode.delete(:base_image)
      feed_image = @episode.delete(:image)
      @current_episode_image_none = (feed_image == "none")
      # Per-feed image: supports same values as --image (path, "last", "thumb", "none")
      @current_episode_feed_image = resolve_feed_image(feed_image) unless @current_episode_image_none
      episode_image_url = @episode.delete(:image_url)
      logger.phase_end("Fetch Episode")

      if @dry_run
        log_dry_run("Config validated, episode \"#{@episode[:title]}\" — no API calls")
        return 0
      end

      logger.phase_start("Download Audio")
      @source_audio_path = @episode_source.download_audio(@episode)
      @temp_files << @source_audio_path
      logger.log("Downloaded source audio: #{(File.size(@source_audio_path) / (1024.0 * 1024)).round(2)} MB")

      if episode_image_url
        @rss_episode_image = download_episode_image(episode_image_url)
      end
      logger.phase_end("Download Audio")

      verdict = enforce_length_post_download
      return verdict if verdict

      nil
    end

    # Probes the downloaded audio duration and rejects episodes outside the
    # configured min_length/max_length range. Returns nil to continue, or an
    # exit code to abort.
    def enforce_length_post_download
      duration = AudioAssembler.probe_duration(@source_audio_path)
      verdict = @episode_source.length_check(duration)
      return nil if verdict == :ok

      reason = verdict == :too_long ? "too long" : "too short"
      min_s = @config.min_length_seconds
      max_s = @config.max_length_seconds
      range = "#{format_length(min_s)}–#{format_length(max_s)}"
      actual = format_length(duration)
      logger.log("Warning: episode duration #{actual} is #{reason} (allowed range #{range})")

      if @options[:ask_trim]
        prompt = "Episode is #{reason} (#{actual}, allowed #{range}). [t]rim manually / e[x]clude / [a]bort? "
        $stdout.print(prompt)
        $stdout.flush
        choice = ($stdin.gets || "").strip.downcase
        case choice
        when "t", "trim"
          logger.log("Continuing with manual trim despite out-of-range duration")
          return nil
        when "x", "exclude"
          @episode_source.exclude_url!(@episode[:audio_url])
          logger.log("Excluded #{@episode[:audio_url]}")
          return 1
        else
          logger.log("Aborted by user")
          return 1
        end
      end

      logger.error("Episode duration #{actual} outside allowed range #{range}; aborting")
      1
    end

    def format_length(secs)
      return "?" unless secs
      m = (secs / 60).to_i
      s = (secs % 60).round
      "#{m}:#{s.to_s.rjust(2, '0')}"
    end

    def trim_source_audio
      assembler = AudioAssembler.new(logger: logger)
      @trimmer = AudioTrimmer.new(assembler: assembler, logger: logger)

      if @options[:ask_trim]
        result = ask_trim_interactive
        if result == :exclude
          exclude_current_episode!
          return :excluded
        end
        skip, cut = result
      else
        skip = @options[:no_skip] ? nil : (@options[:skip] || @episode[:skip] || @config.skip)
        cut = @options[:no_cut] ? nil : (@options[:cut] || @episode[:cut] || @config.cut)
      end
      snip = @options[:snip]
      @source_audio_path = @trimmer.apply_trim(@source_audio_path, skip: skip, cut: cut, snip: snip)
    end

    def exclude_current_episode!
      url = UrlCleaner.clean(@episode[:audio_url])
      @episode_source.exclude_url!(url)
      logger.log("Excluded episode: #{url}")
      $stderr.puts "Excluded: \"#{@episode[:title]}\""
    end

    def ask_trim_interactive
      duration = AudioAssembler.new(logger: logger).probe_duration(@source_audio_path)
      $stderr.puts "\nAudio downloaded: #{duration.round(1)}s (#{(duration / 60).to_i}:#{format('%04.1f', duration % 60)})"
      $stderr.puts "Opening audio for preview..."
      system("open", @source_audio_path)

      $stderr.print "Enter skip intro (seconds or min:sec), x to exclude, blank for none: "
      skip_input = $stdin.gets&.strip
      return :exclude if skip_input&.downcase == "x"
      skip = skip_input.nil? || skip_input.empty? ? nil : TimeValue.parse(skip_input)

      $stderr.print "Enter cut outro (seconds or min:sec), x to exclude, blank for none: "
      cut_input = $stdin.gets&.strip
      return :exclude if cut_input&.downcase == "x"
      cut = cut_input.nil? || cut_input.empty? ? nil : TimeValue.parse(cut_input)

      [skip, cut]
    end

    def discover_transcript
      result = TranscriptDiscovery.search(
        rss_item: @episode || {},
        youtube_captions: @youtube_captions,
        logger: logger
      )
      return unless result

      case result[:quality]
      when :high
        # High-quality transcript — use as primary reference alongside STT
        @youtube_captions = result[:text]
        logger.log("Discovered #{result[:source]} transcript (#{result[:quality]} quality, #{result[:text].split(/\s+/).length} words)")
      when :medium, :low
        # Lower quality — use as captions (tiebreaker in reconciliation)
        @youtube_captions ||= result[:text]
        logger.log("Discovered #{result[:source]} transcript (#{result[:quality]} quality, used as reference)")
      end
    end

    def transcribe
      logger.phase_start("Transcription")
      @base_name = @config.episode_basename(@today)
      @transcription_result = transcribe_audio(@source_audio_path, captions: @youtube_captions)
      logger.phase_end("Transcription")
    end

    def trim_outro
      autotrim = @options[:no_autotrim] ? false : (@options[:autotrim] || @episode[:autotrim] || @config.autotrim)
      if autotrim && @reconciled_text && @groq_words&.any?
        logger.phase_start("Trim Outro")
        tails_dir = File.join(File.dirname(@config.episodes_dir), "tails")
        @source_audio_path = @trimmer.trim_outro(
          @source_audio_path,
          reconciled_text: @reconciled_text,
          groq_words: @groq_words,
          base_name: @base_name,
          tails_dir: tails_dir
        )
        logger.phase_end("Trim Outro")
      elsif autotrim
        logger.log("Skipping outro trim (requires 2+ engines with groq)")
      else
        logger.log("Skipping outro trim (autotrim not enabled)")
      end
    end

    def assemble_episode
      @transcript = @reconciled_text || @transcription_result[:text]

      logger.phase_start("Assembly")
      @output_path = File.join(@staging_dir, "#{@base_name}.mp3")

      intro_music_path = File.join(@config.podcast_dir, "intro.mp3")
      outro_music_path = File.join(@config.podcast_dir, "outro.mp3")

      assembler = AudioAssembler.new(logger: logger)
      assembler.assemble([@source_audio_path], @output_path, intro_path: intro_music_path, outro_path: outro_music_path,
        metadata: { title: @episode[:title], artist: @config.author })
      logger.phase_end("Assembly")
    end

    def persist_timestamps
      segments, engine = TimestampPersister.extract_segments(
        @transcription_result,
        engine_codes: @config.transcription_engines,
        comparison_results: @comparison_results
      )

      unless segments
        logger.log("No segment timestamps available — skipping timestamp persistence")
        return
      end

      intro_path = File.join(@config.podcast_dir, "intro.mp3")
      intro_duration = File.exist?(intro_path) ? AudioAssembler.probe_duration(intro_path).to_f : 0.0
      source_duration = AudioAssembler.probe_duration(@source_audio_path)&.to_f

      ts_path = File.join(@staging_dir, "#{@base_name}_timestamps.json")
      TimestampPersister.persist(
        segments: segments,
        engine: engine,
        intro_duration: intro_duration,
        output_path: ts_path,
        audio_duration: source_duration
      )
      logger.log("Timestamps saved: #{ts_path} (#{segments.length} segments, engine: #{engine}, intro: #{intro_duration.round(1)}s)")
    end

    def reconcile_subtitles
      return unless @reconciled_text
      ts_path = File.join(@staging_dir, "#{@base_name}_timestamps.json")
      return unless File.exist?(ts_path)

      api_key = ENV["ANTHROPIC_API_KEY"]
      return unless api_key && !api_key.empty?

      logger.phase_start("Subtitle Reconciliation")
      require_relative "../subtitle_reconciler"
      data = TimestampPersister.load(ts_path)
      segments = SubtitleReconciler.reconcile(data["segments"], @reconciled_text, api_key: api_key)
      TimestampPersister.update_segments(ts_path, segments)
      logger.log("Subtitles reconciled (#{segments.length} segments)")
      logger.phase_end("Subtitle Reconciliation")
    rescue => e
      logger.log("Warning: Subtitle reconciliation failed: #{e.message} (non-fatal, keeping raw segments)")
      @warnings << "Subtitle reconciliation failed (#{e.message})"
      logger.phase_end("Subtitle Reconciliation") rescue nil
    end

    def save_transcript_and_cover
      save_transcript(@episode, @transcript, @base_name)

      @current_episode_description = @episode[:description]
      cover_source, cover_desc = resolve_episode_cover(@episode[:title])
      if cover_source
        ext = File.extname(cover_source).downcase
        if [".jpg", ".jpeg"].include?(ext)
          cover_dest = File.join(@staging_dir, "#{@base_name}_cover#{ext}")
          FileUtils.cp(cover_source, cover_dest)
        else
          cover_dest = File.join(@staging_dir, "#{@base_name}_cover.jpg")
          unless system("magick", cover_source, cover_dest) || system("convert", cover_source, cover_dest)
            cover_dest = File.join(@staging_dir, "#{@base_name}_cover#{ext}")
            FileUtils.cp(cover_source, cover_dest)
          end
        end
        logger.log("Episode cover: #{cover_desc} → #{cover_dest}")
      else
        logger.log("No episode cover (no image source resolved)")
      end
    end

    def annotate_vocabulary
      logger.phase_start("Vocabulary")
      transcript_path = File.join(@staging_dir, "#{@base_name}_transcript.md")
      parsed = TranscriptParser.parse(transcript_path)

      unless parsed.body && !parsed.body.empty?
        logger.log("No transcript body found, skipping vocabulary annotation")
        logger.phase_end("Vocabulary")
        return
      end

      unless ENV["ANTHROPIC_API_KEY"] && !ENV["ANTHROPIC_API_KEY"].empty?
        logger.log("ANTHROPIC_API_KEY not set, skipping vocabulary annotation")
        logger.phase_end("Vocabulary")
        return
      end

      require_relative "../known_vocabulary"
      known = KnownVocabulary.for_config(@config)
      known_lemmas = known.lemma_set(@config.transcription_language)

      annotator = VocabularyAnnotator.new(
        ENV["ANTHROPIC_API_KEY"],
        logger: logger
      )
      marked_body, vocabulary_md = annotator.annotate(
        parsed.body,
        language: @config.transcription_language,
        cutoff: @config.vocabulary_level,
        known_lemmas: known_lemmas,
        max: @config.vocabulary_max,
        filters: @config.vocabulary_filters,
        include_words: @options[:include_words] || Set.new,
        target_languages: @config.vocabulary_target_languages
      )

      # Rewrite transcript file with marked words + vocabulary appendix
      TranscriptParser.write(transcript_path,
        title: parsed.title,
        description: parsed.description,
        body: marked_body,
        vocabulary: vocabulary_md.empty? ? nil : vocabulary_md)

      logger.log("Vocabulary annotated (#{@config.vocabulary_level}+ cutoff)")
      logger.phase_end("Vocabulary")
    rescue => e
      logger.log("Warning: Vocabulary annotation failed: #{e.message} (non-fatal, continuing)")
      logger.log(e.backtrace.first(3).join("\n"))
      @warnings << "Vocabulary annotation failed (#{e.message})"
      logger.phase_end("Vocabulary") rescue nil
    end

    def record_history
      @history.record!(
        date: @today,
        title: @episode[:title],
        topics: [@episode[:title]],
        urls: [@episode[:audio_url]],
        duration: AudioAssembler.probe_duration(@output_path),
        timestamp: Time.now.iso8601,
        basename: @base_name
      )
      logger.log("Episode recorded in history: #{@config.history_path}")
    end

    def log_completion
      total_time = (Time.now - @pipeline_start).round(2)
      logger.log("Total pipeline time: #{total_time}s")

      if @warnings.any?
        msg = "\u26A0 Episode ready (with warnings): #{@output_path}"
        logger.log(msg)
        puts msg unless @options[:verbosity] == :quiet
        @warnings.each do |w|
          logger.log("  - #{w}")
          puts "  - #{w}" unless @options[:verbosity] == :quiet
        end
      else
        logger.log("\u2713 Episode ready: #{@output_path}")
        puts "\u2713 Episode ready: #{@output_path}" unless @options[:verbosity] == :quiet
      end
    end

    # --- Helpers ---

    def transcribe_audio(audio_path, captions: nil)
      language = @config.transcription_language
      raise "Language pipeline requires ## Transcription Language in guidelines.md" unless language

      engine_codes = @config.transcription_engines
      manager = Transcription::EngineManager.new(
        engine_codes: engine_codes,
        language: language,
        target_language: @config.target_language,
        logger: logger
      )
      result = manager.transcribe(audio_path, captions: captions)

      if engine_codes.length > 1
        # Comparison mode — stash per-engine results for save_transcript and outro trim
        @comparison_results = result[:all]
        @comparison_errors = result[:errors]
        @reconciled_text = result[:reconciled]
        @groq_words = result[:all]["groq"]&.dig(:words)
        raise "Transcript reconciliation failed — episode not committed" unless @reconciled_text
        result[:primary]
      else
        # Single engine — use cleaned text if available
        @reconciled_text = result[:cleaned]
        result
      end
    end

    def clean_or_generate_description(episode, transcript)
      agent = DescriptionAgent.new(logger: logger)
      lang = @config.transcription_language

      # Clean title (all sources)
      episode[:title] = agent.clean_title(title: episode[:title])

      # Detect generic or wrong-language title → regenerate from transcript
      if generic_title?(episode[:title])
        logger.log("Title is generic or wrong language, generating from transcript")
        generated = agent.generate_title(transcript: transcript, language: @config.target_language || lang)
        episode[:title] = generated if generated
      end

      # Clean or generate description
      if episode[:description].to_s.strip.empty?
        episode[:description] = agent.generate(title: episode[:title], transcript: transcript)
      else
        episode[:description] = agent.clean(title: episode[:title], description: episode[:description])

        # Detect wrong-language description → regenerate from transcript
        if wrong_language?(episode[:description], lang)
          logger.log("Description language doesn't match transcript (#{lang}), regenerating")
          episode[:description] = agent.generate(title: episode[:title], transcript: transcript)
        end
      end
    rescue => e
      logger.log("Warning: Description processing failed: #{e.message} (non-fatal, keeping original)")
      @warnings << "Description cleanup failed (#{e.message})"
    end

    # Title is generic if it matches the podcast name or is in the wrong language.
    def generic_title?(title)
      return false if title.to_s.strip.empty?

      # Matches podcast name (case-insensitive)
      podcast_name = @config.respond_to?(:name) ? @config.name : nil
      if podcast_name && title.strip.casecmp(podcast_name.strip).zero?
        return true
      end

      # Wrong language
      wrong_language?(title, @config.transcription_language)
    end

    # Checks if text language differs from expected language.
    # Returns false for short text where detection is unreliable.
    def wrong_language?(text, expected_lang)
      return false if text.to_s.strip.length < 15

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "tell", "detector")
      detected = Tell::Detector.detect(text)
      return false unless detected # detection failed, assume OK

      detected != expected_lang
    end

    def save_transcript(episode, transcript, base_name)
      # Use reconciled text as primary if available (multi-engine mode)
      primary_text = @reconciled_text || transcript
      transcript_path = File.join(@staging_dir, "#{base_name}_transcript.md")
      write_transcript_file(transcript_path, episode, primary_text)
      if @reconciled_text
        logger.log("Reconciled transcript saved to #{transcript_path}")
      else
        logger.log("Transcript saved to #{transcript_path}")
      end

      # Save per-engine transcripts only in verbose mode (for comparison/debugging)
      return unless @comparison_results&.any? && @options[:verbosity] == :verbose

      @comparison_results.each do |code, result|
        engine_path = File.join(@staging_dir, "#{base_name}_transcript_#{code}.md")
        write_transcript_file(engine_path, episode, result[:text])
        logger.log("Comparison transcript (#{code}) saved to #{engine_path}")
      end

      if @comparison_errors&.any?
        @comparison_errors.each do |code, error|
          logger.log("Comparison engine '#{code}' failed: #{error}")
        end
      end
    end

    def write_transcript_file(path, episode, transcript)
      TranscriptParser.write(path,
        title: episode[:title],
        description: episode[:description],
        body: transcript)
    end

    def upload_to_lingq(episode, transcript, audio_path, base_name)
      return unless @config.lingq_enabled?

      if @dry_run
        logger.log("[dry-run] Skipping LingQ upload")
        return
      end

      logger.phase_start("LingQ Upload")
      lc = @config.lingq_config
      language = @config.transcription_language

      image_path, = resolve_episode_cover(episode[:title])

      agent = LingQAgent.new(logger: logger, api_key: @config.lingq_config&.[](:token))
      lesson_id = agent.upload(
        title: episode[:title],
        text: transcript,
        audio_path: audio_path,
        language: language,
        collection: lc[:collection],
        level: lc[:level],
        tags: lc[:tags],
        image_path: image_path,
        accent: lc[:accent],
        status: lc[:status],
        description: episode[:description],
        original_url: episode[:link]
      )

      # Record in tracking so publish --lingq doesn't re-upload
      record_lingq_upload(lc[:collection], base_name, lesson_id)

      logger.phase_end("LingQ Upload")
    rescue => e
      logger.log("Warning: LingQ upload failed: #{e.message} (non-fatal, continuing)")
      logger.log(e.backtrace.first(3).join("\n"))
      @warnings << "LingQ upload failed (#{e.message})"
    end

    def record_lingq_upload(collection, base_name, lesson_id)
      UploadTracker.for_config(@config).record(:lingq, collection, base_name, lesson_id)
      logger.log("Recorded LingQ upload: #{base_name} → lesson #{lesson_id}")
    end

    def upload_to_youtube
      unless @config.youtube_enabled?
        logger.log("YouTube not configured — skipping upload")
        return
      end

      if @dry_run
        logger.log("[dry-run] Skipping YouTube upload")
        return
      end

      logger.phase_start("YouTube Upload")
      yt_config = @config.youtube_config
      language = @config.transcription_language || "en"

      # Generate SRT from timestamps
      ts_path = File.join(@config.episodes_dir, "#{@base_name}_timestamps.json")
      srt_path = File.join(@config.episodes_dir, "#{@base_name}.srt")
      SubtitleGenerator.generate_srt(ts_path, srt_path) if File.exist?(ts_path)

      # Generate video from cover + audio
      cover_path = resolve_committed_cover
      raise "No episode cover found for video generation" unless cover_path

      video_path = File.join(@config.episodes_dir, "#{@base_name}.mp4")
      VideoGenerator.new(logger: logger).generate(@output_path, cover_path, video_path)

      # Upload to YouTube (lazy require to avoid loading google-apis gems unless needed)
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "youtube_uploader")
      uploader = YouTubeUploader.new(logger: logger)
      uploader.authorize!

      # Verify playlist exists before uploading
      uploader.verify_playlist!(yt_config[:playlist]) if yt_config[:playlist]

      video_id = uploader.upload_video(
        video_path,
        title: @episode[:title],
        description: @episode[:description].to_s,
        language: language,
        privacy: yt_config[:privacy] || "unlisted",
        category: yt_config[:category] || "27",
        tags: yt_config[:tags] || []
      )

      # Upload captions if SRT exists
      uploader.upload_captions(video_id, srt_path, language: language) if File.exist?(srt_path)

      # Add to playlist if configured
      uploader.add_to_playlist(video_id, yt_config[:playlist]) if yt_config[:playlist]

      # Record upload
      playlist = yt_config[:playlist] || "default"
      UploadTracker.for_config(@config).record(:youtube, playlist, @base_name, video_id)
      logger.log("Recorded YouTube upload: #{@base_name} → #{video_id}")

      logger.phase_end("YouTube Upload")
    rescue => e
      logger.log("Warning: YouTube upload failed: #{e.message} (non-fatal, continuing)")
      logger.log(e.backtrace.first(3).join("\n"))
      @warnings << "YouTube upload failed (#{e.message})"
    end

    def resolve_committed_cover
      CoverResolver.find_episode_cover(@config.episodes_dir, @base_name)
    end

    # Resolves the episode cover image path using the priority chain:
    def resolve_feed_image(value)
      return nil if value.nil? || value == "none"

      if value == "last"
        screenshot = Dir.glob(File.join(Dir.home, "Desktop", "Screenshot *.png"))
                       .max_by { |f| File.mtime(f) }
        if screenshot
          logger.log("Resolved per-feed image: last → #{screenshot}")
          return screenshot
        end
        logger.log("Warning: per-feed image: last but no screenshots found on ~/Desktop")
        return nil
      end

      return value if value == "thumb"
      return value if value == "auto"

      path = File.expand_path(value)
      unless File.exist?(path)
        logger.log("Warning: per-feed image not found: #{path}")
        return nil
      end
      path
    end

    # Priority chain for episode cover:
    # 1.  --image PATH/last/thumb (CLI flag)
    # 2.  Per-feed image: PATH/last/thumb/none
    # 2a. Per-feed image: auto → AutoCoverResolver; falls through if no winner
    # 3.  --base-image PATH → title overlay
    # 4.  Per-feed base_image: PATH → title overlay
    # 5.  RSS episode image → downloaded from feed
    # 6.  ## Image base_image → title overlay
    # 7.  YouTube thumbnail → fallback
    # 8.  nil → no cover
    def resolve_episode_cover(title, skip_auto: false)
      # Auto path: --image auto (CLI) or feed image: auto. Try first, on
      # no-winner recurse with skip_auto=true so we fall through to the rest
      # of the chain (base_image, feed_image, thumbnail, …) instead of
      # treating the literal string "auto" as a path.
      cli_auto = @options[:image] == "auto"
      feed_auto = @current_episode_feed_image == "auto"
      if !skip_auto && (cli_auto || feed_auto)
        winner = try_auto_cover_for_feed(title)
        label = cli_auto ? "--image auto (winner)" : "feed image: auto (winner)"
        return [winner, label] if winner
        return resolve_episode_cover(title, skip_auto: true)
      end

      feed_image = feed_auto ? nil : @current_episode_feed_image
      cli_image = cli_auto ? nil : @options[:image]

      if cli_image
        if cli_image == "thumb"
          [@youtube_thumbnail, "--image thumb (YouTube thumbnail)"]
        else
          [File.expand_path(cli_image), "--image #{cli_image}"]
        end
      elsif @current_episode_image_none
        [@youtube_thumbnail, "feed image: none (YouTube thumbnail fallback)"]
      elsif feed_image
        if feed_image == "thumb"
          [@youtube_thumbnail, "feed image: thumb (YouTube thumbnail)"]
        else
          [feed_image, "feed image: #{File.basename(feed_image)}"]
        end
      elsif @options[:base_image]
        path = generate_cover_image(title, File.expand_path(@options[:base_image])) || @youtube_thumbnail
        [path, "--base-image title overlay"]
      elsif @current_episode_feed_base_image
        path = generate_cover_image(title, @current_episode_feed_base_image) || @youtube_thumbnail
        [path, "feed base_image title overlay"]
      elsif @rss_episode_image
        [@rss_episode_image, "RSS episode image"]
      elsif @config.cover_generation_enabled?
        path = generate_cover_image(title) || @youtube_thumbnail
        [path, "config base_image title overlay"]
      else
        bi = @config.cover_base_image
        if bi && !File.exist?(bi)
          logger.log("Warning: base_image configured but not found: #{bi}")
        end
        [@youtube_thumbnail, @youtube_thumbnail ? "YouTube thumbnail fallback" : nil]
      end
    end

    def download_episode_image(url)
      ext = File.extname(URI.parse(url).path)[0..4] rescue ".jpg"
      ext = ".jpg" if ext.empty?
      path = File.join(Dir.tmpdir, "podgen_rss_cover_#{Process.pid}#{ext}")
      HttpDownloader.new(logger: logger).download(url, path)
      @temp_files << path
      logger.log("Downloaded episode image: #{(File.size(path) / 1024.0).round(1)} KB")
      path
    rescue => e
      logger.log("Warning: Failed to download episode image: #{e.message}")
      nil
    end

    # Attempts an auto-cover search for a feed configured with `image: auto`.
    # Top candidates are persisted into @staging_dir (not episodes_dir) so
    # they participate in the pipeline's atomic commit: a crash before
    # commit_episode wipes them along with everything else in staging.
    # Returns the winner's path (in staging_dir) or nil — the caller falls
    # through to the normal cover chain.
    def try_auto_cover_for_feed(title)
      description = @episode.is_a?(Hash) ? @episode[:description].to_s : ""
      resolver = AutoCoverResolver.new(config: @config.auto_cover_config, logger: logger)
      result = resolver.try(
        title: title,
        description: description,
        episodes_dir: @staging_dir,
        basename: @base_name
      )
      result[:winner_path]
    rescue => e
      logger.log("Warning: auto cover search failed: #{e.message}")
      nil
    end

    # Generates a per-episode cover image with the title overlaid on the base image.
    # Returns the generated image path, or nil on failure.
    def generate_cover_image(title, base_image = nil)
      base_image ||= @config.cover_base_image
      unless base_image
        logger.log("Warning: No base_image configured for cover generation")
        return nil
      end

      path = CoverResolver.generate(
        title: title,
        base_image: base_image,
        options: @config.cover_options,
        logger: logger
      )
      @temp_files << path if path
      path
    rescue => e
      logger.log("Warning: Cover generation failed: #{e.message} (falling back)")
      @warnings << "Cover generation failed (#{e.message})"
      nil
    end

    def log_dry_run(summary)
      logger.log("[dry-run] Skipping download, transcription, assembly, and history")
      total_time = (Time.now - @pipeline_start).round(2)
      logger.log("Total pipeline time: #{total_time}s")
      logger.log("[dry-run] #{summary}")
      puts "[dry-run] #{summary}" unless @options[:verbosity] == :quiet
    end

    def cleanup_temp_files
      (@temp_files + (@trimmer&.temp_files || [])).each do |path|
        File.delete(path) if File.exist?(path)
      rescue => e
        logger.log("Warning: failed to cleanup #{path}: #{e.message}")
      end
    end
  end
end
