# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "fileutils"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "translation_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "voicer")
require_relative File.join(root, "lib", "rss_generator")
require_relative File.join(root, "lib", "script_artifact")
require_relative File.join(root, "lib", "script_renderer")
require_relative File.join(root, "lib", "legacy_script_parser")

module PodgenCLI
  class TranslateCommand
    include PodcastCommand
    include EpisodeSelector

    def initialize(args, options)
      @options = options
      @lang_filter = nil
      @force = false

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen translate <podcast> [<date>] [--date DATE | --last N] [--lang LANG] [--force]"
        add_episode_selection_options!(opts)
        opts.on("--lang LANG", "Only translate to this language (e.g. it)") { |l| @lang_filter = l.downcase }
        opts.on("--force", "Re-translate even if the language MP3 already exists") { @force = true }
        opts.on("--dry-run", "Show what would be translated") { @options[:dry_run] = true }
      end.parse!(args)

      @podcast_name = args.shift
      extract_positional_date!(args)
      reject_leftover_args!(args)
      validate_episode_selection!
    end

    def run
      code = require_podcast!("translate <podcast>")
      return code if code

      config = load_config!

      logger = PodcastAgent::Logger.new(log_path: config.log_path(Date.today), verbosity: @options[:verbosity])
      PodcastAgent.logger = logger
      logger.log("Translate started for '#{@podcast_name}'")

      # Resolve target languages (exclude English)
      languages = config.languages.reject { |l| l["code"] == "en" }

      if @lang_filter
        languages = languages.select { |l| l["code"] == @lang_filter }
        if languages.empty?
          $stderr.puts "Language '#{@lang_filter}' not found in config. Available: #{config.languages.map { |l| l['code'] }.join(', ')}"
          return 2
        end
      end

      if languages.empty?
        $stderr.puts "No non-English languages configured for '#{@podcast_name}'"
        return 2
      end

      # Discover English episodes with _script.md files
      episodes = discover_episodes(config.episodes_dir)
      if episodes.empty?
        logger.log("No English episodes found in #{config.episodes_dir}")
        return 0
      end

      # Apply --date / --last filtering
      episodes = filter_by_date(episodes, episode_date, episode_suffix) if episode_date
      episodes = episodes.last(last_n) if last_n

      # Find pending translations
      pending = pending_translations(episodes, languages, config.episodes_dir)

      if pending.empty?
        logger.log("All episodes already translated")
        return 0
      end

      if @options[:dry_run]
        logger.log("Pending translations for #{@podcast_name}:")
        pending.each { |p| logger.log("  #{p[:basename]} \u2192 #{p[:lang_code]}") }
        logger.log("#{pending.length} episode(s) to translate")
        return 0
      end

      # Run translation pipeline
      translated = 0
      failed = 0
      intro_path = File.join(config.podcast_dir, "intro.mp3")
      outro_path = File.join(config.podcast_dir, "outro.mp3")

      pending.each_with_index do |item, idx|
        logger.phase_start("Translate #{item[:basename]} → #{item[:lang_code]}")
        begin
          translate_episode(
            script_path: item[:script_path],
            basename: item[:basename],
            lang_code: item[:lang_code],
            voice_id: item[:voice_id],
            translator: item[:translator],
            translation_model: item[:translation_model],
            glossary: config.translation_glossary_for(item[:lang_code]),
            episodes_dir: config.episodes_dir,
            intro_path: intro_path,
            outro_path: outro_path,
            podcast_title: config.title,
            author: config.author,
            pronunciation_pls_path: config.pronunciation_pls_path,
            links_config: config.links_enabled? ? config.links_config : nil,
            logger: logger
          )
          translated += 1
          logger.phase_end("Translate #{item[:basename]} → #{item[:lang_code]}")
          logger.log("Done (#{idx + 1}/#{pending.length})")
        rescue => e
          failed += 1
          logger.error("Translation failed for #{item[:basename]} → #{item[:lang_code]}: #{e.message}")
          logger.error(e.backtrace.first) if @options[:verbosity] == :verbose
        end
      end

      logger.log("Translated #{translated} episode(s), #{failed} failed")

      # Regenerate RSS feeds
      regenerate_rss(config, logger)

      translated > 0 ? 0 : 1
    end

    private

    # Narrows the episode list to a specific date. With a suffix, narrows
    # to that exact basename; without, matches every basename on the day.
    def filter_by_date(episodes, date, suffix)
      date_str = date.strftime("%Y-%m-%d")
      if suffix
        episodes.select { |e| e[:basename].end_with?("-#{date_str}#{suffix}") }
      else
        episodes.select { |e| e[:basename].match?(/-#{Regexp.escape(date_str)}[a-z]?\z/) }
      end
    end

    # Finds English episodes that have both _script.md and .mp3 files.
    # Excludes language-suffixed scripts (e.g. *-it_script.md) and
    # orphaned scripts without a corresponding English MP3.
    def discover_episodes(episodes_dir)
      Dir.glob(File.join(episodes_dir, "*_script.md"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}_script\.md$/) }
        .select { |f| File.exist?(f.sub(/_script\.md$/, ".mp3")) }
        .sort
        .map do |path|
          basename = File.basename(path, "_script.md")
          { script_path: path, basename: basename }
        end
    end

    # Returns array of { script_path:, basename:, lang_code:, voice_id: }
    # for episodes that don't yet have a translated MP3.
    def pending_translations(episodes, languages, episodes_dir)
      pending = []
      episodes.each do |ep|
        languages.each do |lang|
          lang_code = lang["code"]
          mp3_path = File.join(episodes_dir, "#{ep[:basename]}-#{lang_code}.mp3")
          next if File.exist?(mp3_path) && !@force

          pending << {
            script_path: ep[:script_path],
            basename: ep[:basename],
            lang_code: lang_code,
            voice_id: lang["voice_id"],
            translator: lang["translator"],
            translation_model: lang["translation_model"]
          }
        end
      end
      pending
    end

    def translate_episode(script_path:, basename:, lang_code:, voice_id:, episodes_dir:, intro_path:, outro_path:, podcast_title:, author:, translator: nil, translation_model: nil, glossary: nil, pronunciation_pls_path: nil, links_config: nil, logger: nil)
      script = parse_script(script_path)

      # Translate
      translator_agent = TranslationAgent.new(
        target_language: lang_code,
        backend: translator || "claude",
        model_override: translation_model,
        glossary: glossary,
        logger: logger
      )
      lang_script = translator_agent.translate(script)

      # Save translated script
      lang_script_path = File.join(episodes_dir, "#{basename}-#{lang_code}_script.md")
      save_script(lang_script, lang_script_path, links_config: links_config)

      output_path = File.join(episodes_dir, "#{basename}-#{lang_code}.mp3")
      Voicer.new(logger: logger).voice(
        segments: lang_script[:segments],
        output_path: output_path,
        voice_id: voice_id,
        title: lang_script[:title],
        author: author,
        pronunciation_pls_path: pronunciation_pls_path,
        intro_path: intro_path,
        outro_path: outro_path,
        lang_code: lang_code
      )
    end

    def parse_script(path)
      script, _source = ScriptArtifact.read_with_fallback(path)
      script || raise("Could not read script at #{path} (or its .json sibling)")
    end

    def save_script(script, path, links_config: nil)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ScriptRenderer.render(script, links_config: links_config))
      ScriptArtifact.write(ScriptArtifact.json_path_for(path), script)
    end

    def regenerate_rss(config, logger)
      logger.log("Regenerating RSS feeds...")

      # Convert markdown transcripts to HTML for podcast apps
      RssGenerator.convert_transcripts(config.episodes_dir)

      base_url = config.base_url
      feed_paths = []

      config.languages.each do |lang|
        lang_code = lang["code"]
        feed_path = lang_code == "en" ? config.feed_path : config.feed_path.sub(/\.xml$/, "-#{lang_code}.xml")

        generator = RssGenerator.new(
          episodes_dir: config.episodes_dir,
          feed_path: feed_path,
          title: config.title,
          description: config.description,
          author: config.author,
          language: lang_code,
          base_url: base_url,
          image: config.image,
          history_path: config.history_path,
          logger: logger
        )
        generator.generate
        feed_paths << feed_path
      end

      feed_paths.each { |fp| logger.log("Feed: #{fp}") }
    end

  end
end
