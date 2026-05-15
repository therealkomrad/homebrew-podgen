# frozen_string_literal: true

require "yaml"
require "date"
require "fileutils"
require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "time_value")
require_relative File.join(root, "lib", "snip_interval")
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "topic_agent")
require_relative File.join(root, "lib", "source_manager")
require_relative File.join(root, "lib", "agents", "script_agent")
require_relative File.join(root, "lib", "agents", "script_reviewer")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "agents", "translation_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "url_cleaner")
require_relative File.join(root, "lib", "priority_links")
require_relative File.join(root, "lib", "script_artifact")
require_relative File.join(root, "lib", "script_renderer")
require_relative File.join(root, "lib", "voicer")
require_relative File.join(root, "lib", "cli", "language_pipeline")

module PodgenCLI
  class GenerateCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options

      OptionParser.new do |opts|
        opts.on("--file PATH", "Local audio file (language pipeline)") { |f| @options[:file] = f }
        opts.on("--url URL", "YouTube video URL (language pipeline)") { |u| @options[:url] = u }
        opts.on("--rss URL", "RSS feed: URL or substring of configured feed") { |u| @options[:rss] = u }
        opts.on("--title TEXT", "Episode title (with --file or --url)") { |t| @options[:title] = t }
        opts.on("--skip-intro N", "--skip N", String, "Seconds or min:sec to skip from start") { |n| @options[:skip] = TimeValue.parse(n) }
        opts.on("--cut-outro N", "--cut N", String, "Seconds or min:sec to cut from end (min:sec = absolute)") { |n| @options[:cut] = TimeValue.parse(n) }
        opts.on("--snip INTERVALS", String, "Remove interior segments (e.g. 1:20-2:30,3:40+33)") { |s| @options[:snip] = SnipInterval.parse(s) }
        opts.on("--autotrim", "Enable outro auto-detection via word timestamps") { @options[:autotrim] = true }
        opts.on("--no-autotrim", "Disable autotrim even if configured") { @options[:no_autotrim] = true }
        opts.on("--no-skip", "Disable skip even if configured") { @options[:no_skip] = true }
        opts.on("--ask-trim", "--ask-skip", "Download audio, play it, then prompt for skip and cut values") { @options[:ask_trim] = true }
        opts.on("--no-cut", "Disable cut even if configured") { @options[:no_cut] = true }
        opts.on("--force", "Process even if already in history (skip dedup check)") { @options[:force] = true }
        opts.on("--image PATH", "Cover: file path, 'thumb' (YouTube), 'last' (~/Desktop screenshot), or 'auto' (DDG search)") { |p| @options[:image] = p }
        opts.on("--base-image PATH", "Base image for cover generation (with --file or --url)") { |p| @options[:base_image] = p }
        opts.on("--lingq", "Enable LingQ upload during generation") { @options[:lingq] = true }
        opts.on("--youtube", "Enable YouTube upload during generation") { @options[:youtube] = true }
        opts.on("--date DATE", "Episode date (YYYY-MM-DD, default: today)") { |d| @options[:date] = Date.parse(d) }
        opts.on("--include WORDS", "Force-include vocabulary lemmas (comma-separated)") { |v| @options[:include_words] = Set.new(v.split(",").map { |w| w.strip.downcase }) }
        opts.on("--from-script", "DEPRECATED: prefer 'podgen voice <pod> [--lang LANG]'. Resumes voicing from saved script JSON.") { @options[:from_script] = true; @options[:force] = true }
        opts.on("--dry-run", "Validate config, skip API calls") { @options[:dry_run] = true }
      end.parse!(args)

      @dry_run = @options[:dry_run] || false

      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = setup_pipeline
      return code if code

      begin
        @logger.log("Podcast Agent started for '#{@podcast_name}'#{@dry_run ? ' (DRY RUN)' : ''}")
        @pipeline_start = Time.now

        verify_ffmpeg!(@logger) unless @dry_run

        return run_language_pipeline if @config.type == "language"

        @logger.log("Pipeline type: news")

        if @options[:from_script]
          @logger.log("--from-script is deprecated. Prefer: podgen voice #{@podcast_name} [--lang LANG]")
          $stderr.puts "Note: --from-script is deprecated. Prefer: podgen voice #{@podcast_name} [--lang LANG]" unless @options[:verbosity] == :quiet
          script = load_script_for_resume
          research_data = []
          priority_urls = []
          @logger.log("--from-script: skipping topics/research/script/review/translation phases")
          output_paths = produce_episodes(script, research_data)
          finalize(output_paths, script, research_data, priority_urls)
        else
          topics = generate_topics
          research_data = research_topics(topics)
          research_data, priority_urls = inject_priority_links(research_data)
          script = generate_script(topics, research_data, priority_urls)
          script = review_script(script, research_data, priority_urls) unless @dry_run

          if @dry_run
            log_dry_run_summary(topics, research_data, script)
          else
            output_paths = produce_episodes(script, research_data)
            finalize(output_paths, script, research_data, priority_urls)
          end
        end

        0
      rescue => e
        @logger.error("#{e.class}: #{e.message}")
        @logger.error(e.backtrace.first(5).join("\n"))
        $stderr.puts "\n\u2717 Pipeline failed: #{e.message}" unless @options[:verbosity] == :quiet
        1
      ensure
        @lock_file.flock(File::LOCK_UN)
        @lock_file.close
      end
    end

    private

    # Returns exit code on failure, nil on success.
    def setup_pipeline
      code = require_podcast!("generate")
      return code if code

      @config = load_config!
      @config.ensure_directories!

      lock_path = File.join(File.dirname(@config.episodes_dir), "run.lock")
      @lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
      unless @lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        $stderr.puts "Another instance is already running for '#{@podcast_name}' (lockfile: #{lock_path})"
        @lock_file.close
        return 1
      end

      @today = @options[:date] || Date.today
      if @options[:date] && !@options[:force]
        date_str = @today.strftime("%Y-%m-%d")
        existing = Dir.glob(File.join(@config.episodes_dir, "#{@config.name}-#{date_str}*.mp3"))
          .reject { |f| File.basename(f).include?("_concat") }
        unless existing.empty?
          $stderr.puts "Error: episode already exists for #{date_str}: #{File.basename(existing.first)}"
          $stderr.puts "Use --force to generate anyway (will create a suffixed episode)"
          return 1
        end
      end
      @logger = PodcastAgent::Logger.new(log_path: @config.log_path(@today), verbosity: @options[:verbosity])
      PodcastAgent.logger = @logger
      @history = EpisodeHistory.new(@config.history_path, excluded_urls_path: @config.excluded_urls_path)
      @warnings = []

      unless File.exist?(@config.guidelines_path)
        @logger.error("Missing guidelines: #{@config.guidelines_path}")
        return 1
      end

      @guidelines = @config.guidelines
      @logger.log("Loaded guidelines (#{@guidelines.length} chars)")

      if @options[:file] && @config.type != "language"
        $stderr.puts "Error: --file is only supported for language pipeline podcasts (type: language)"
        return 1
      end
      if @options[:url] && @config.type != "language"
        $stderr.puts "Error: --url is only supported for language pipeline podcasts (type: language)"
        return 1
      end
      if @options[:rss] && @config.type != "language"
        $stderr.puts "Error: --rss is only supported for language pipeline podcasts (type: language)"
        return 1
      end
      if @options[:file] && @options[:url]
        $stderr.puts "Error: --file and --url are mutually exclusive"
        return 1
      end
      if @options[:rss] && (@options[:file] || @options[:url])
        $stderr.puts "Error: --rss is mutually exclusive with --file and --url"
        return 1
      end
      %w[skip cut autotrim].each do |flag|
        if @options[flag.to_sym] && @options[:"no_#{flag}"]
          $stderr.puts "Error: --#{flag} and --no-#{flag} are mutually exclusive"
          return 1
        end
      end
      if @options[:ask_trim] && (@options[:skip] || @options[:no_skip] || @options[:cut] || @options[:no_cut])
        $stderr.puts "Error: --ask-trim is mutually exclusive with --skip/--no-skip/--cut/--no-cut"
        return 1
      end
      nil
    end

    def run_language_pipeline
      @logger.log("Pipeline type: language")
      pipeline = LanguagePipeline.new(config: @config, options: @options, logger: @logger, history: @history, today: @today)
      pipeline.run
    end

    def generate_topics
      @logger.phase_start("Topics")
      topics = if @dry_run
        t = @config.queue_topics
        @logger.log("[dry-run] Using queue.yml topics: #{t.join(', ')}")
        t
      else
        begin
          topic_agent = TopicAgent.new(guidelines: @guidelines, recent_topics: @history.recent_topics_summary, logger: @logger)
          t = topic_agent.generate
          @logger.log("Generated #{t.length} topics from guidelines")
          t
        rescue => e
          @logger.log("Topic generation failed (#{e.message}), falling back to queue.yml")
          t = @config.queue_topics
          @logger.log("Loaded #{t.length} fallback topics: #{t.join(', ')}")
          t
        end
      end
      @logger.phase_end("Topics")
      topics
    end

    def research_topics(topics)
      @logger.phase_start("Research")
      research_data = if @dry_run
        topics.map do |topic|
          {
            topic: topic,
            findings: [
              { title: "Example article about #{topic}", url: "https://example.com/#{topic.downcase.gsub(/\s+/, '-')}", summary: "This is a stub finding for dry-run testing of '#{topic}'." }
            ]
          }
        end.tap { @logger.log("[dry-run] Generated #{topics.length} synthetic research topics") }
      else
        cache_dir = File.join(File.dirname(@config.episodes_dir), "research_cache")
        source_manager = SourceManager.new(
          source_config: @config.sources,
          exclude_urls: @history.recent_urls,
          logger: @logger,
          cache_dir: cache_dir
        )
        source_manager.research(topics)
      end
      total_findings = research_data.sum { |r| r[:findings].length }
      @logger.log("Research complete: #{total_findings} findings across #{research_data.length} topics")
      @logger.phase_end("Research")
      research_data
    end

    def inject_priority_links(research_data)
      priority_links = PriorityLinks.new(@config.links_path)
      priority_urls = []
      unless priority_links.empty? || @dry_run
        @logger.phase_start("Priority Links")
        @logger.log("Fetching #{priority_links.count} priority link(s)...")
        priority_findings = priority_links.fetch_all(logger: @logger)
        priority_urls = priority_findings.map { |f| f[:url] }
        research_data.unshift({ topic: "Priority links", findings: priority_findings })
        @logger.log("Injected #{priority_findings.length} priority link(s) into research data")
        @logger.phase_end("Priority Links")
      end
      [research_data, priority_urls]
    end

    def generate_script(topics, research_data, priority_urls)
      @logger.phase_start("Script")
      script = if @dry_run
        {
          title: "Dry Run Episode — #{@today}",
          segments: [
            { name: "Opening", text: "Welcome to this dry-run episode. Today we explore #{topics.first}." },
            { name: topics.first.to_s, text: "Here is segment one covering #{topics.first} in detail with synthetic content for testing purposes." },
            { name: topics.last.to_s, text: "Here is segment two covering #{topics.last} with more synthetic content." },
            { name: "Wrap-Up", text: "Thanks for listening to this dry-run episode. Until next time." }
          ],
          sources: [
            { title: "Example source for #{topics.first}", url: "https://example.com/#{topics.first.to_s.downcase.gsub(/\s+/, '-')}" }
          ]
        }.tap { |s| @logger.log("[dry-run] Synthetic script generated: \"#{s[:title]}\"") }
      else
        script_agent = ScriptAgent.new(
          guidelines: @guidelines,
          script_path: @config.script_path(@today),
          logger: @logger,
          priority_urls: priority_urls,
          links_config: @config.links_enabled? ? @config.links_config : nil
        )
        script_agent.generate(research_data)
      end
      @logger.log("Script generated: \"#{script[:title]}\" (#{script[:segments].length} segments)")
      @logger.phase_end("Script")
      script
    end

    MAX_REVIEW_RETRIES = 2

    def review_script(script, research_data, priority_urls)
      @logger.phase_start("Review")

      reviewer = ScriptReviewer.new(
        date: @today,
        research_data: research_data,
        priority_urls: priority_urls,
        guidelines: @guidelines,
        logger: @logger
      )

      attempt = 0

      loop do
        result = reviewer.review(script)

        # Log all issues
        result[:issues].each do |issue|
          fixed = issue[:auto_fixed] ? " [auto-fixed]" : ""
          @logger.log("  #{issue[:severity]}: [#{issue[:check]}] #{issue[:message]}#{fixed}")
        end

        # Use the corrected script (deterministic fixes applied)
        script = result[:script]

        # Check for unfixed blockers
        unfixed_blockers = result[:issues].select { |i| i[:severity] == ScriptReviewer::BLOCKER && !i[:auto_fixed] }

        if unfixed_blockers.empty?
          total = result[:issues].length
          @logger.log("Script review passed#{total > 0 ? " (#{total} issue(s), none blocking)" : ""}")
          break
        end

        attempt += 1
        if attempt > MAX_REVIEW_RETRIES
          @warnings << "Script review: #{unfixed_blockers.length} unresolved blocker(s) after #{MAX_REVIEW_RETRIES} retries"
          unfixed_blockers.each { |b| @warnings << "  - #{b[:message]}" }
          @logger.log("Script review: proceeding with #{unfixed_blockers.length} unresolved blocker(s)")
          break
        end

        @logger.log("Script review: #{unfixed_blockers.length} blocker(s) found, re-generating (attempt #{attempt}/#{MAX_REVIEW_RETRIES})")
        feedback = unfixed_blockers.map { |b| "- #{b[:message]}" }.join("\n")
        script = regenerate_script_with_feedback(research_data, priority_urls, feedback)
      end

      @logger.phase_end("Review")
      script
    end

    def regenerate_script_with_feedback(research_data, priority_urls, feedback)
      script_agent = ScriptAgent.new(
        guidelines: @guidelines,
        script_path: @config.script_path(@today),
        logger: @logger,
        priority_urls: priority_urls,
        links_config: @config.links_enabled? ? @config.links_config : nil
      )
      augmented_data = research_data + [{
        topic: "REVIEWER FEEDBACK — You MUST fix these issues in the new script",
        findings: [{ title: "Issues to fix", url: "n/a", summary: feedback }]
      }]
      script_agent.generate(augmented_data)
    end

    def produce_episodes(script, research_data)
      languages = @config.languages
      @logger.log("Target languages: #{languages.map { |l| l['code'] }.join(', ')}")

      # Compute basename ONCE before the loop — otherwise, after the English MP3
      # is written to disk, episode_basename would see it and increment the suffix.
      @base_name = @config.episode_basename(@today)
      intro_path = File.join(@config.podcast_dir, "intro.mp3")
      outro_path = File.join(@config.podcast_dir, "outro.mp3")
      output_paths = []

      languages.each do |lang|
        lang_code = lang["code"]
        begin
          output_path = produce_single_language(script, lang, @base_name, intro_path, outro_path)
          output_paths << output_path
          @logger.log("\u2713 Episode ready (#{lang_code}): #{output_path}")
          puts "\u2713 Episode ready (#{lang_code}): #{output_path}" unless @options[:verbosity] == :quiet
        rescue => e
          @logger.error("Language #{lang_code} failed: #{e.class}: #{e.message}")
          @logger.error(e.backtrace.first(5).join("\n"))
          msg = "Language #{lang_code} failed: #{e.message}"
          @warnings << msg
          $stderr.puts "\u2717 #{msg}" unless @options[:verbosity] == :quiet
        end
      end

      raise "All languages failed — no episodes produced" if output_paths.empty?
      output_paths
    end

    def produce_single_language(script, lang, base_name, intro_path, outro_path)
      lang_code = lang["code"]
      voice_id = lang["voice_id"]
      lang_basename = lang_code == "en" ? base_name : "#{base_name}-#{lang_code}"

      lang_script = if lang_code == "en"
        script
      else
        translated_path = File.join(@config.episodes_dir, "#{lang_basename}_script.md")
        translated_script, translated_source = ScriptArtifact.read_with_fallback(translated_path)
        if @options[:from_script] && translated_script
          @logger.log("--from-script: loaded translated script for #{lang_code} from #{translated_path} (#{translated_source == :json ? 'JSON' : 'legacy markdown'})")
          translated_script
        else
          @logger.log("--from-script: no saved #{lang_code} script, translating from English") if @options[:from_script]
          @logger.phase_start("Translation (#{lang_code})")
          translator = TranslationAgent.new(
            target_language: lang_code,
            backend: lang["translator"] || "claude",
            model_override: lang["translation_model"],
            glossary: @config.translation_glossary_for(lang_code),
            logger: @logger
          )
          translated = translator.translate(script)
          @logger.phase_end("Translation (#{lang_code})")
          translated
        end
      end

      # TranslationAgent#carry_over_sources already attaches English sources
      # (top-level + per-segment) to the translated script — they're URL+title
      # pairs that don't need translation.
      lang_script_path = File.join(@config.episodes_dir, "#{lang_basename}_script.md")
      save_script_debug(lang_script, lang_script_path, @logger,
                        links_config: @config.links_enabled? ? @config.links_config : nil)

      output_path = File.join(@config.episodes_dir, "#{lang_basename}.mp3")
      Voicer.new(logger: @logger).voice(
        segments: lang_script[:segments],
        output_path: output_path,
        voice_id: voice_id,
        title: lang_script[:title],
        author: @config.author,
        tts_model_id: @config.tts_model_id,
        pronunciation_pls_path: @config.pronunciation_pls_path,
        intro_path: intro_path,
        outro_path: outro_path,
        lang_code: lang_code
      )
      output_path
    end

    # Resumes from a previously-saved English script. Prefers the canonical
    # JSON artifact (preserves per-segment sources); falls back to the
    # markdown view (legacy, lossy) for older runs.
    def load_script_for_resume
      @base_name ||= @config.episode_basename(@today)
      md_path = File.join(@config.episodes_dir, "#{@base_name}_script.md")
      script, source = ScriptArtifact.read_with_fallback(md_path)

      unless script
        raise "--from-script: expected #{md_path} or its .json sibling but neither exists. " \
              "Run a full pipeline first, or pass --date YYYY-MM-DD to resume an older run."
      end

      @logger.log("--from-script: loaded English script from #{md_path} (#{source == :json ? 'JSON' : 'legacy markdown'})")
      script
    end

    def finalize(output_paths, script, research_data, priority_urls)
      languages_meta = output_paths.each_with_object({}) do |path, h|
        # Filename: <basename>.mp3 (en) or <basename>-<lang>.mp3
        match = File.basename(path, ".mp3").match(/-([a-z]{2})\z/)
        code = match ? match[1] : "en"
        h[code] = {
          "duration" => AudioAssembler.probe_duration(path),
          "voiced_at" => Time.now.iso8601
        }
      end

      @history.record!(
        date: @today,
        title: script[:title],
        topics: research_data.map { |r| r[:topic] },
        urls: research_data.flat_map { |r| r[:findings].map { |f| f[:url] } },
        duration: AudioAssembler.probe_duration(output_paths.first),
        timestamp: Time.now.iso8601,
        languages: languages_meta,
        basename: @base_name
      )
      @logger.log("Episode recorded in history: #{@config.history_path}")

      unless priority_urls.empty?
        priority_links = PriorityLinks.new(@config.links_path)
        priority_links.consume!(priority_urls)
        @logger.log("#{priority_urls.length} priority link(s) consumed")
      end

      total_time = (Time.now - @pipeline_start).round(2)
      @logger.log("Total pipeline time: #{total_time}s")

      if @warnings.any?
        msg = "\u26A0 #{output_paths.length} episode(s) produced (with warnings)"
        @logger.log(msg)
        puts msg unless @options[:verbosity] == :quiet
        @warnings.each do |w|
          @logger.log("  - #{w}")
          puts "  - #{w}" unless @options[:verbosity] == :quiet
        end
      else
        @logger.log("\u2713 #{output_paths.length} episode(s) produced")
      end
    end

    def log_dry_run_summary(topics, research_data, script)
      languages = @config.languages
      languages.each do |lang|
        @logger.log("[dry-run] Would synthesize + assemble for language: #{lang['code']}")
      end
      @logger.log("[dry-run] Skipping history.record!")

      total_findings = research_data.sum { |r| r[:findings].length }
      total_time = (Time.now - @pipeline_start).round(2)
      @logger.log("Total pipeline time: #{total_time}s")
      summary = "[dry-run] Config validated, #{topics.length} topics, #{total_findings} stub findings, #{script[:segments].length} segments, #{languages.length} language(s) — no API calls made"
      @logger.log(summary)
      puts summary unless @options[:verbosity] == :quiet
    end

    def verify_ffmpeg!(logger)
      require "open3"
      _out, _err, status = Open3.capture3("ffmpeg", "-version")
      unless status.success?
        logger.error("ffmpeg is not working correctly. Install with: brew install ffmpeg")
        raise "ffmpeg is not working correctly"
      end
    rescue Errno::ENOENT
      logger.error("ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg")
      raise "ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg"
    end

    def save_script_debug(script, path, logger, links_config: nil)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ScriptRenderer.render(script, links_config: links_config))
      ScriptArtifact.write(ScriptArtifact.json_path_for(path), script)
      logger.log("Script saved to #{path}")
    end
  end
end
