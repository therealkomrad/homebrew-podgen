# frozen_string_literal: true

require "optparse"
require "fileutils"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "agents", "cover_agent")
require_relative File.join(root, "lib", "transcript_parser")
require_relative File.join(root, "lib", "cover_resolver")
require_relative File.join(root, "lib", "auto_cover_resolver")

module PodgenCLI
  class CoverCommand
    include PodcastCommand
    include EpisodeSelector

    CANDIDATE_GLOB = "*_cover[0-9]*.*"

    def initialize(args, options)
      @options = options
      @output_path = nil
      @missing_only = false
      @image = nil
      @clean = false
      @overrides = {}

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen cover <podcast> [<date>] [options]"
        opts.separator ""
        opts.on("--missing-only", "Only generate covers for episodes without one") { @missing_only = true }
        opts.on("--image PATH", "Image file path, 'last' for latest ~/Desktop screenshot, or 'auto' to search") { |v| @image = v }
        opts.on("--base-image PATH", "Override base image") { |v| @overrides[:base_image] = v }
        opts.on("--output PATH", "Output file path") { |v| @output_path = v }
        add_date_option!(opts)
        opts.on("--title TEXT", "Cover title text") { |v| @title = v }
        opts.on("--font NAME", "Override font family") { |v| @overrides[:font] = v }
        opts.on("--font-color COLOR", "Override font color") { |v| @overrides[:font_color] = v }
        opts.on("--font-size N", Integer, "Override font size") { |v| @overrides[:font_size] = v }
        opts.on("--width N", "--text-width N", Integer, "Override text wrap width") { |v| @overrides[:width] = v }
        opts.on("--gravity POS", "--text-gravity POS", "Override gravity (Center, South, etc.)") { |v| @overrides[:gravity] = v }
        opts.on("--x-offset N", "--text-x-offset N", Integer, "Override horizontal offset") { |v| @overrides[:x_offset] = v }
        opts.on("--y-offset N", "--text-y-offset N", Integer, "Override vertical offset") { |v| @overrides[:y_offset] = v }
        opts.on("--clean", "Remove _cover{N}.* candidate files (one podcast or all)") { @clean = true }
      end.parse!(args)

      @podcast_name = args.shift
      extract_positional_date!(args)
      reject_leftover_args!(args)
      validate_episode_selection!
      @episode_id = normalized_episode_id
      @title = nil if @title&.empty?
      @dry_run = options[:dry_run] || false
    end

    def run
      return run_clean if @clean

      code = require_podcast!("cover")
      return code if code

      if @image == "auto" && @title && !@title.empty?
        $stderr.puts "Error: --image auto cannot be combined with --title (no episode description for ranking)"
        return 1
      end

      config = load_config!

      code = resolve_image_option
      return code if code

      # --title + --date: episode mode with title override (writes to episode cover path)
      # --title alone: preview mode (writes to podcast_dir/cover_preview.jpg)
      if @title && !@title.empty? && !@episode_id
        return run_manual_title(config)
      end

      # Episode mode (single or batch). May still use @title to override transcript title.
      return run_episode_mode(config)
    end

    private

    def resolve_image_option
      return nil unless @image
      return nil if @image == "auto"  # auto handles batch + single via run_auto_image_mode

      unless @episode_id
        $stderr.puts "Error: --image requires a specific episode ID"
        return 1
      end

      if @image == "last"
        screenshot = Dir.glob(File.join(Dir.home, "Desktop", "Screenshot *.png"))
                       .max_by { |f| File.mtime(f) }
        unless screenshot
          $stderr.puts "Error: no screenshots found on ~/Desktop"
          return 1
        end
        @image = screenshot
      end

      unless File.exist?(@image)
        $stderr.puts "Error: image file not found: #{@image}"
        return 1
      end

      nil
    end

    def run_manual_title(config)
      base_image, cover_opts = resolve_cover_config(config)
      return 1 unless base_image

      output = File.expand_path(@output_path || File.join(config.podcast_dir, "cover_preview.jpg"))

      CoverAgent.new.generate(
        title: @title,
        base_image: base_image,
        output_path: output,
        options: cover_opts
      )

      puts "Cover generated: #{output}"
      0
    rescue => e
      $stderr.puts "Cover generation failed: #{e.message}"
      1
    end

    def run_episode_mode(config)
      episodes = resolve_episodes(config)
      if episodes.empty?
        $stderr.puts "No episodes found#{@episode_id ? " matching '#{@episode_id}'" : ""}"
        return 1
      end

      # Direct image copy mode
      if @image
        return run_auto_image_mode(config, episodes) if @image == "auto"
        return copy_image_to_episodes(episodes)
      end

      base_image, cover_opts = resolve_cover_config(config)
      return 1 unless base_image

      agent = CoverAgent.new
      puts "Generating covers for #{episodes.length} episode(s)"

      processed = 0
      episodes.each do |ep|
        if @dry_run
          puts "  [dry-run] #{ep[:basename]}: #{ep[:title]}"
          next
        end

        title = @title && !@title.empty? ? @title : ep[:title]
        output = File.expand_path(ep[:output])
        puts "  #{ep[:basename]}: #{output}"
        agent.generate(
          title: title,
          base_image: base_image,
          output_path: output,
          options: cover_opts
        )
        processed += 1
      end

      puts "Generated #{processed} cover(s)" unless @dry_run
      0
    rescue => e
      $stderr.puts "Cover generation failed: #{e.message}"
      1
    end

    def run_clean
      podcasts = @podcast_name ? [@podcast_name] : PodcastConfig.available
      total = 0
      podcasts.each do |name|
        episodes_dir = File.join(PodcastConfig.root, "output", name, "episodes")
        next unless Dir.exist?(episodes_dir)

        files = Dir.glob(File.join(episodes_dir, CANDIDATE_GLOB))
        next if files.empty?

        if @dry_run
          files.each { |f| puts "  [dry-run] would remove #{f}" }
        else
          files.each { |f| File.delete(f) }
          puts "#{name}: removed #{files.length} candidate file(s)"
        end
        total += files.length
      end
      puts "Removed #{total} candidate file(s) total" unless @dry_run
      0
    end

    def run_auto_image_mode(config, episodes)
      resolver = AutoCoverResolver.new(config: config.auto_cover_config)
      base_image, cover_opts = resolve_cover_config(config)
      fallback_agent = base_image ? CoverAgent.new : nil

      puts "Auto cover search for #{episodes.length} episode(s) (~$0.02 each)"

      processed = 0
      episodes.each do |ep|
        if @dry_run
          puts "  [dry-run] #{ep[:basename]}: #{ep[:title]}"
          next
        end

        parsed = TranscriptParser.parse(ep[:transcript_path])
        result = resolver.try(
          title: parsed.title,
          description: parsed.description.to_s,
          episodes_dir: config.episodes_dir,
          basename: ep[:basename]
        )

        result[:candidates].each_with_index do |c, idx|
          flags = [
            "vq=#{c[:visual_quality]}",
            "subj=#{c[:subject_match]}",
            c[:has_title_text] ? "title=Y" : "title=N",
            c[:has_overlay_watermark] ? "WATERMARK" : nil,
            c[:vetoed] ? "VETO" : nil
          ].compact.join(" ")
          path = result[:top_paths][idx] || "(unranked)"
          puts "    [#{idx + 1}] score=#{c[:score]} #{flags}  #{File.basename(path)}"
          puts "        #{c[:reasons]}" if c[:reasons] && !c[:reasons].empty?
        end

        if result[:winner_path]
          installed = install_winner_as_cover(result[:winner_path], ep[:output])
          score = result[:candidates].first&.dig(:score)
          puts "  #{ep[:basename]}: #{installed} (auto, score #{score})"
        elsif fallback_agent
          fallback_agent.generate(
            title: ep[:title],
            base_image: base_image,
            output_path: ep[:output],
            options: cover_opts
          )
          puts "  #{ep[:basename]}: #{ep[:output]} (no auto winner — generated with overlay)"
        else
          puts "  #{ep[:basename]}: skipped (no auto winner, no base_image for fallback)"
        end
        processed += 1
      end

      puts "Processed #{processed} episode(s)" unless @dry_run
      0
    rescue => e
      $stderr.puts "Auto cover failed: #{e.message}"
      1
    end

    # Returns the actual destination path (may differ from dest_jpg if magick
    # is unavailable and the source isn't a JPEG — in that case we keep the
    # source extension so file contents and filename agree).
    def install_winner_as_cover(src, dest_jpg)
      ext = File.extname(src).downcase
      if [".jpg", ".jpeg"].include?(ext)
        FileUtils.cp(src, dest_jpg)
        dest_jpg
      elsif system("magick", src, dest_jpg, out: File::NULL, err: File::NULL)
        dest_jpg
      else
        # No magick available and source isn't JPEG — preserve the real
        # extension so the file isn't a non-jpg masquerading as .jpg.
        dest = dest_jpg.sub(/\.jpg$/, ext)
        FileUtils.cp(src, dest)
        dest
      end
    end

    def copy_image_to_episodes(episodes)
      episodes.each do |ep|
        output = ep[:output] # always .jpg
        if @dry_run
          puts "  [dry-run] #{ep[:basename]}: copy #{@image}"
          next
        end
        ext = File.extname(@image).downcase
        if [".jpg", ".jpeg"].include?(ext)
          FileUtils.cp(@image, output)
        elsif system("magick", @image, output) || system("convert", @image, output)
          # converted to JPG via ImageMagick
        else
          output = ep[:output].sub(/\.jpg$/, ext)
          FileUtils.cp(@image, output)
          $stderr.puts "  Warning: ImageMagick not available, copied as #{ext} without conversion"
        end
        puts "  #{ep[:basename]}: #{output}"
      end
      puts "Copied image to #{episodes.length} episode(s)" unless @dry_run
      0
    end

    def resolve_episodes(config)
      dir = config.episodes_dir
      pattern = if @episode_id
        File.join(dir, "*#{@episode_id}_transcript.md")
      else
        File.join(dir, "*_transcript.md")
      end

      Dir.glob(pattern).sort.filter_map do |path|
        basename = File.basename(path, "_transcript.md")

        if @missing_only && CoverResolver.find_episode_cover(dir, basename)
          next
        end

        title = TranscriptParser.extract_title(path)
        next unless title && !title.empty?

        output = File.join(dir, "#{basename}_cover.jpg")
        { basename: basename, title: title, output: output, transcript_path: path }
      end
    end

    def resolve_cover_config(config)
      base_image = @overrides[:base_image] || config.cover_base_image
      # Resolve relative paths against podcast directory
      if base_image && !base_image.start_with?("/") && !File.exist?(base_image)
        candidate = File.join(config.podcast_dir, base_image)
        base_image = candidate if File.exist?(candidate)
      end
      unless base_image && File.exist?(base_image)
        $stderr.puts "No base_image available for cover generation."
        $stderr.puts "  Configure in guidelines.md under ## Image, or pass --base-image PATH"
        return nil
      end

      cover_opts = config.cover_options.merge(@overrides.except(:base_image))
      [base_image, cover_opts]
    end
  end
end
