# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "transcription", "reconciler")
require_relative File.join(root, "lib", "site_generator")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "transcript_renderer")

module PodgenCLI
  class ReformatCommand
    include PodcastCommand
    include TranscriptRenderer

    def initialize(args, options)
      require "optparse"
      OptionParser.new do |opts|
        opts.on("--date DATE", "Episode date (YYYY-MM-DD)") { |v| @episode_id = v }
      end.parse!(args)

      @podcast_name = args.shift
      @episode_id ||= args.shift
      reject_leftover_args!(args)
      @options = options
      @dry_run = options[:dry_run] || false
    end

    def run
      code = require_podcast!("reformat")
      return code if code

      load_config!

      unless ENV["ANTHROPIC_API_KEY"] && !ENV["ANTHROPIC_API_KEY"].empty?
        $stderr.puts "Error: ANTHROPIC_API_KEY not set"
        return 2
      end

      transcripts = resolve_transcripts
      if transcripts.empty?
        $stderr.puts "No transcripts found#{@episode_id ? " matching '#{@episode_id}'" : ""}"
        return 1
      end

      language = @config.transcription_language
      logger = build_logger
      @reconciler ||= Transcription::Reconciler.new(language: language, logger: logger)

      puts "Reformatting #{transcripts.length} transcript(s) (#{language})"

      processed = 0
      transcripts.each do |path|
        basename = File.basename(path, "_transcript.md")

        if @dry_run
          puts "  [dry-run] #{basename}"
          next
        end

        puts "  #{basename}..."
        process_transcript(path, logger: logger)
        processed += 1
      end

      if !@dry_run && processed > 0
        puts "Regenerating site..."
        SiteGenerator.new(config: @config, clean: true).generate
      end

      0
    end

    private

    def build_logger
      quiet = @options[:verbosity] == :quiet
      logger = Object.new
      logger.define_singleton_method(:log) { |msg| puts msg unless quiet }
      logger.define_singleton_method(:error) { |msg| $stderr.puts msg }
      logger.define_singleton_method(:phase_start) { |_| }
      logger.define_singleton_method(:phase_end) { |_| }
      logger
    end

    def resolve_transcripts
      dir = @config.episodes_dir

      if @episode_id
        Dir.glob(File.join(dir, "*#{@episode_id}_transcript.md")).sort
      else
        Dir.glob(File.join(dir, "*_transcript.md")).sort
      end
    end

    def process_transcript(path, logger:)
      parsed = TranscriptParser.parse(path)
      unless parsed.transcript_section
        logger.log("Skipping #{File.basename(path)}: no ## Transcript section")
        return
      end

      # Parse vocab entries for re-marking after cleanup
      vocab_entries = parsed.vocabulary ? parse_vocab_for_marking(parsed.vocabulary) : []

      # Strip bold markers from previous vocabulary annotation
      body = strip_bold_markers(parsed.body)

      # Run through the formatting pipeline
      formatted = @reconciler.cleanup(body)

      # Re-apply bold markers from existing vocabulary
      formatted = remark_vocab_words(formatted, vocab_entries) unless vocab_entries.empty?

      # Reassemble
      TranscriptParser.write(path,
        title: parsed.title,
        description: parsed.description,
        body: formatted,
        vocabulary: parsed.vocabulary)

      logger.log("Reformatted: #{File.basename(path)}")
    rescue => e
      logger.error("Failed to reformat #{File.basename(path)}: #{e.message}")
    end

    # Parse vocabulary markdown lines into entries suitable for re-marking.
    def parse_vocab_for_marking(vocab_text)
      entries = []
      vocab_text.each_line do |line|
        entry = parse_vocab_line(line.strip)
        next unless entry

        forms = [entry[:lemma]]
        forms += entry[:original].split(/,\s*/) if entry[:original]
        entries << { lemma: entry[:lemma], words: forms }
      end
      entries
    end

    # Re-apply bold markers for vocabulary words in the formatted text.
    def remark_vocab_words(text, entries)
      marked = text.dup
      entries.each do |entry|
        forms = (entry[:words] + [entry[:lemma]]).compact.uniq(&:downcase)
        forms.each do |form|
          pattern = /(?<!\*)\b(#{Regexp.escape(form)})\b(?!\*)/i
          marked.gsub!(pattern, '**\1**')
        end
      end
      marked
    end
  end
end
