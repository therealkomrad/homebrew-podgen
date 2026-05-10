# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "date"
require "fileutils"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "script_artifact")
require_relative File.join(root, "lib", "voicer")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "audio_assembler")

module PodgenCLI
  # Voice (or re-voice) one or more languages of an existing episode from
  # its script artifact (JSON preferred, legacy markdown accepted). Use to
  # recover from a TTS failure without re-running script generation or
  # translation, or to batch-re-voice older episodes after a voice change.
  #
  # Examples:
  #   podgen voice fulgur_news --lang jp
  #   podgen voice fulgur_news --date 2026-04-26 --lang jp --force
  #   podgen voice fulgur_news --last 5 --lang jp        # 5 most recent episodes
  class VoiceCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @date = nil
      @last_n = nil
      @lang_filter = nil
      @force = false

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen voice <podcast> [--date YYYY-MM-DD | --last N] [--lang LANG] [--force]"
        opts.on("--date DATE", "Episode date (default: today)") { |d| @date = Date.parse(d) }
        opts.on("--last N", Integer, "Voice the N most recent episodes (mutually exclusive with --date)") { |n| @last_n = n }
        opts.on("--lang LANG", "Only voice this language") { |l| @lang_filter = l.downcase }
        opts.on("--force", "Re-voice even if MP3 already exists") { @force = true }
      end.parse!(args)

      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("voice <podcast>")
      return code if code

      if @date && @last_n
        $stderr.puts "Error: --date and --last are mutually exclusive"
        return 2
      end

      config = load_config!
      logger = PodcastAgent::Logger.new(log_path: config.log_path(@date || Date.today), verbosity: @options[:verbosity])

      basenames = resolve_basenames(config)
      if basenames.empty?
        msg = @last_n ? "No episodes found in #{config.episodes_dir}" : "No script found for #{(@date || Date.today)} in #{config.episodes_dir}"
        $stderr.puts msg unless @options[:verbosity] == :quiet
        logger.log(msg)
        return 1
      end

      languages = config.languages
      languages = languages.select { |l| l["code"] == @lang_filter } if @lang_filter

      if languages.empty?
        msg = @lang_filter ? "Language '#{@lang_filter}' not configured for #{@podcast_name}" : "No languages configured"
        $stderr.puts msg
        return 2
      end

      intro_path = File.join(config.podcast_dir, "intro.mp3")
      outro_path = File.join(config.podcast_dir, "outro.mp3")
      history = EpisodeHistory.new(config.history_path, excluded_urls_path: config.excluded_urls_path)
      voiced = 0
      skipped = 0
      failed = 0

      basenames.each do |base_name|
        languages.each do |lang|
          lang_code = lang["code"]
          lang_basename = lang_code == "en" ? base_name : "#{base_name}-#{lang_code}"
          md_path = File.join(config.episodes_dir, "#{lang_basename}_script.md")
          output_path = File.join(config.episodes_dir, "#{lang_basename}.mp3")

          if File.exist?(output_path) && !@force
            logger.log("Skipping #{base_name}/#{lang_code}: MP3 exists (use --force to overwrite)")
            skipped += 1
            next
          end

          script, source = ScriptArtifact.read_with_fallback(md_path)
          unless script
            logger.error("Skipping #{base_name}/#{lang_code}: no script artifact at #{md_path} or its .json")
            failed += 1
            next
          end
          logger.log("Loaded #{base_name}/#{lang_code} from #{source == :json ? 'JSON' : 'legacy markdown'}")

          begin
            Voicer.new(logger: logger).voice(
              segments: script[:segments],
              output_path: output_path,
              voice_id: lang["voice_id"],
              title: script[:title],
              author: config.author,
              tts_model_id: config.tts_model_id,
              pronunciation_pls_path: config.pronunciation_pls_path,
              intro_path: intro_path,
              outro_path: outro_path,
              lang_code: lang_code
            )
            begin
              history.record_language!(
                basename: base_name,
                language_code: lang_code,
                duration: AudioAssembler.probe_duration(output_path),
                voiced_at: Time.now.iso8601
              )
            rescue => e
              logger.log("Note: history not updated (#{e.message})")
            end
            logger.log("✓ Voiced (#{base_name}/#{lang_code}): #{output_path}")
            puts "✓ Voiced (#{base_name}/#{lang_code}): #{output_path}" unless @options[:verbosity] == :quiet
            voiced += 1
          rescue => e
            logger.error("Voicing failed (#{base_name}/#{lang_code}): #{e.class}: #{e.message}")
            $stderr.puts "✗ Voicing failed (#{base_name}/#{lang_code}): #{e.message}" unless @options[:verbosity] == :quiet
            failed += 1
          end
        end
      end

      logger.log("Voiced #{voiced}, skipped #{skipped}, failed #{failed}")
      failed == 0 && voiced > 0 ? 0 : (voiced > 0 ? 1 : 2)
    end

    private

    # Resolves which episode basenames to operate on:
    # --date Y-M-D → that date's basename (if a script exists)
    # --last N     → N most recent English script files in episodes_dir
    # neither      → today's basename
    def resolve_basenames(config)
      if @last_n
        english_script_basenames(config).sort.last(@last_n)
      elsif @date
        # Find ALL existing English script basenames matching the date.
        # Don't use config.episode_basename(date) — that returns the
        # NEXT-available suffix for creating new episodes, not the
        # existing ones we want to re-voice.
        date_str = @date.strftime("%Y-%m-%d")
        english_script_basenames(config).select { |b| b.include?(date_str) }
      else
        # Default: today's basename if its script exists.
        base = config.episode_basename(Date.today)
        md_path = File.join(config.episodes_dir, "#{base}_script.md")
        File.exist?(md_path) || ScriptArtifact.exist?(ScriptArtifact.json_path_for(md_path)) ? [base] : []
      end
    end

    def english_script_basenames(config)
      Dir.glob(File.join(config.episodes_dir, "*_script.md"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}_script\.md\z/) }
        .sort
        .map { |f| File.basename(f, "_script.md") }
    end
  end
end
