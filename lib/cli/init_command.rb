# frozen_string_literal: true

require "fileutils"
require "optparse"
require "yaml"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")

module PodgenCLI
  class InitCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options

      if args.length == 2
        @source_name = args[0]
        @new_name = args[1]
      elsif args.length == 1
        @source_name = nil
        @new_name = args[0]
      elsif args.empty?
        @new_name = nil
      else
        raise OptionParser::ParseError, "unexpected argument(s): #{args[2..].join(' ')}"
      end
    end

    def run
      unless @new_name
        $stderr.puts "Usage: podgen init <new_podcast>"
        $stderr.puts "       podgen init <source_podcast> <new_podcast>"
        return 2
      end

      new_podcast_dir = File.join(PodcastConfig.root, "podcasts", @new_name)
      if Dir.exist?(new_podcast_dir)
        $stderr.puts "Podcast '#{@new_name}' already exists at #{new_podcast_dir}"
        return 1
      end

      if @source_name
        init_from_existing(new_podcast_dir)
      else
        init_skeleton(new_podcast_dir)
      end
    end

    private

    def init_from_existing(new_podcast_dir)
      @podcast_name = @source_name
      code = require_podcast!("init")
      return code if code

      source_config = PodcastConfig.new(@source_name)

      # Copy config directory only (no episodes, history, or uploads)
      FileUtils.cp_r(source_config.podcast_dir, new_podcast_dir)
      puts "Config: #{source_config.podcast_dir} → #{new_podcast_dir}"

      # Warn if .env was copied (may contain secrets)
      env_path = File.join(new_podcast_dir, ".env")
      if File.exist?(env_path)
        puts "  Warning: .env copied — review and update credentials for the new podcast"
      end

      # Create empty output structure
      create_output_dir

      puts
      puts "Initialized '#{@new_name}' from '#{@source_name}' (config only, no episodes)"
      print_next_steps
      0
    end

    def init_skeleton(new_podcast_dir)
      FileUtils.mkdir_p(new_podcast_dir)

      # Generate template guidelines.md
      File.write(File.join(new_podcast_dir, "guidelines.md"), guidelines_template)
      puts "Created #{new_podcast_dir}/guidelines.md"

      # Generate starter queue.yml
      File.write(File.join(new_podcast_dir, "queue.yml"), starter_queue)
      puts "Created #{new_podcast_dir}/queue.yml"

      # Create empty output structure
      create_output_dir

      puts
      puts "Initialized '#{@new_name}'"
      print_next_steps
      0
    end

    def create_output_dir
      episodes_dir = File.join(PodcastConfig.root, "output", @new_name, "episodes")
      FileUtils.mkdir_p(episodes_dir)
    end

    def print_next_steps
      puts
      puts "Next steps:"
      puts "  1. Edit podcasts/#{@new_name}/guidelines.md"
      puts "  2. podgen validate #{@new_name}  — check configuration"
      puts "  3. podgen generate #{@new_name}   — run the pipeline"
    end

    def guidelines_template
      <<~MD
        # Podcast Guidelines

        ## Podcast
        - name: #{@new_name}
        <!-- - type: news              # news (default) or language -->
        <!-- - author: Your Name -->
        <!-- - description: A short description of your podcast -->
        <!-- - base_url: https://example.com/podcast  # URL prefix for published files -->
        <!-- - image: cover.jpg        # cover image file in this directory -->

        ## Format
        <!-- Describe the structure of each episode: segments, length, style -->
        - Target length: 8–10 minutes
        - Open with a brief intro
        - 3–4 main segments
        - Close with a takeaway

        ## Tone
        <!-- Describe the voice and style: conversational, formal, educational, etc. -->
        Conversational and informative. Clear, direct language.

        ## Sources
        <!-- Research sources for the news pipeline. Remove if using language pipeline. -->
        <!-- Available: exa, hackernews, bluesky, x, claude_web, rss -->
        - exa

        ## Audio
        <!-- Transcription and TTS settings for the language pipeline -->
        <!-- - engine:              # Transcription engines: open, elab, groq -->
        <!--   - open -->
        <!-- - language: en          # ISO 639-1 code for transcription language -->
        <!-- - target_language: English  # Full language name for prompts -->
        <!-- - skip: 0               # Seconds to skip from start of source audio -->
        <!-- - cut: 0                # Seconds to cut from end of source audio -->
        <!-- - autotrim              # Auto-detect and trim silence/music -->

        ## Topics
        <!-- Default topic rotation (override per-run with queue.yml) -->
        - Topic 1
        - Topic 2
        - Topic 3

        <!-- ============================================================ -->
        <!-- Optional sections below — uncomment and configure as needed  -->
        <!-- ============================================================ -->

        <!-- ## Vocabulary -->
        <!-- Language learning: annotate transcripts with vocabulary -->
        <!-- - level: B2             # CEFR level: A1, A2, B1, B2, C1, C2 -->
        <!-- - target: English       # Language for definitions/translations (default: English) -->
        <!-- - max: 30               # Max vocabulary entries per episode -->
        <!-- - frequency: uncommon   # common, uncommon, rare, literary, archaic -->
        <!-- - similar: English      # Languages for cognate filtering -->

        <!-- ## Image -->
        <!-- Episode cover generation (requires ImageMagick + librsvg) -->
        <!-- - base_image: basis.jpg # Background image for title overlay -->
        <!-- - font: Patrick Hand    # Font name for title text -->
        <!-- - font_color: #333333 -->
        <!-- - font_size: 120 -->
        <!-- - text_width: 980 -->

        <!-- ## LingQ -->
        <!-- Auto-upload to LingQ language learning platform -->
        <!-- - collection: 1234567   # LingQ collection/course ID -->
        <!-- - level: 3              # Difficulty level (1-6) -->
        <!-- - tags: podcast, learning -->

        <!-- ## YouTube -->
        <!-- Auto-upload to YouTube with generated video + subtitles -->
        <!-- - playlist: PLxxxxxxx   # YouTube playlist ID -->
        <!-- - privacy: unlisted     # public, unlisted, or private -->
        <!-- - category: 27          # YouTube category ID (27 = Education) -->
        <!-- - tags: podcast, learning -->

        <!-- ## Site -->
        <!-- Static HTML site generation (podgen site) -->
        <!-- - accent: #0066cc       # Theme accent color -->
        <!-- - footer: My Podcast    # Footer text -->
        <!-- - show_duration: true -->
        <!-- - show_transcript: true -->

        <!-- ## Twitter -->
        <!-- Auto-tweet after publishing -->
        <!-- - template: New episode: {title} — {url} -->
        <!-- - since: 7              # Only tweet episodes newer than N days -->

        <!-- ## Links -->
        <!-- Show source links in generated scripts -->
        <!-- - show: true -->
        <!-- - position: bottom      # bottom or inline -->
        <!-- - title: Sources -->
        <!-- - max: 10 -->
      MD
    end

    def starter_queue
      { "topics" => [
        "Replace with your first topic",
        "Replace with your second topic"
      ] }.to_yaml
    end
  end
end
