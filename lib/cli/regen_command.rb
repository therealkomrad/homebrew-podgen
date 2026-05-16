# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "date"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "subtitle_reconciliation_runner")
require_relative File.join(root, "lib", "subtitle_generator")
require_relative File.join(root, "lib", "video_builder")
require_relative File.join(root, "lib", "cover_resolver")

module PodgenCLI
  # Regenerate post-pipeline binary artifacts for an existing episode:
  # reconciled timestamps, SRT subtitles, and/or the YouTube .mp4 video.
  # Each artifact normally runs once at generate-time and is skipped on
  # subsequent invocations; this command is the explicit escape hatch.
  #
  # Examples:
  #   podgen regen mypod 2026-05-16 --reconcile     # retry reconciliation
  #   podgen regen mypod 2026-05-16 --subtitles     # regen .srt from timestamps
  #   podgen regen mypod 0516d --video              # rebuild .mp4
  #   podgen regen mypod --all                      # latest episode, all three
  #   podgen regen mypod --last 3 --subtitles       # batch
  class RegenCommand
    include PodcastCommand
    include EpisodeSelector

    def initialize(args, options)
      @options = options
      @video = false
      @subtitles = false
      @reconcile = false
      @force = false

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen regen <podcast> [<date>] [--video|--subtitles|--reconcile|--all] [--force]"
        add_episode_selection_options!(opts)
        opts.on("--video",     "Regenerate the YouTube .mp4 video") { @video = true }
        opts.on("--subtitles", "Regenerate the .srt file from timestamps") { @subtitles = true }
        opts.on("--reconcile", "Reconcile timestamps via Claude (implies --subtitles)") { @reconcile = true }
        opts.on("--all",       "Shorthand for --reconcile --subtitles --video") do
          @reconcile = @subtitles = @video = true
        end
        opts.on("--force",     "Force operations that would otherwise skip") { @force = true }
      end.parse!(args)

      @podcast_name = args.shift
      extract_positional_date!(args)
      reject_leftover_args!(args)
      validate_episode_selection!
    end

    def run
      code = require_podcast!("regen")
      return code if code

      unless @video || @subtitles || @reconcile
        $stderr.puts "Error: specify at least one of --video, --subtitles, --reconcile, --all"
        return 2
      end

      config = load_config!
      basenames = resolve_basenames(config)
      if basenames.empty?
        $stderr.puts "No episodes matched for #{@podcast_name}"
        return 1
      end

      # --reconcile implies SRT regen (the pre-reconciliation .srt is stale).
      do_srt = @subtitles || @reconcile
      do_recon = @reconcile
      do_video = @video

      any_failed = false
      basenames.each do |base|
        any_failed |= !process_episode(config, base, do_recon, do_srt, do_video)
      end

      any_failed ? 1 : 0
    end

    private

    def process_episode(config, base, do_recon, do_srt, do_video)
      ok = true
      dir = config.episodes_dir
      ts_path = File.join(dir, "#{base}_timestamps.json")
      tr_path = File.join(dir, "#{base}_transcript.md")
      srt_path = File.join(dir, "#{base}.srt")
      mp3_path = File.join(dir, "#{base}.mp3")
      mp4_path = File.join(dir, "#{base}.mp4")

      puts "Episode: #{base}" unless quiet?

      if do_recon
        ok &= run_reconcile(base, ts_path, tr_path)
      end

      if do_srt
        ok &= run_srt(base, ts_path, srt_path)
      end

      if do_video
        ok &= run_video(config, base, mp3_path, mp4_path)
      end

      ok
    end

    def run_reconcile(base, ts_path, tr_path)
      unless File.exist?(ts_path)
        $stderr.puts "  ✗ #{base}: no timestamps at #{ts_path} (run `podgen publish --youtube` first to retranscribe)"
        return false
      end
      print "  reconciling: " unless quiet?
      result = SubtitleReconciliationRunner.run(ts_path: ts_path, transcript_path: tr_path, force: true)
      case result.status
      when :reconciled
        puts result.message unless quiet?
        true
      when :no_api_key, :no_transcript, :no_timestamps
        $stderr.puts "  ✗ #{base}: reconcile skipped (#{result.message})"
        false
      when :failed
        $stderr.puts "  ✗ #{base}: reconcile failed (#{result.message})"
        false
      else
        # :already_reconciled can't fire — we pass force: true
        true
      end
    end

    def run_srt(base, ts_path, srt_path)
      unless File.exist?(ts_path)
        $stderr.puts "  ✗ #{base}: no timestamps at #{ts_path} — cannot regenerate .srt"
        return false
      end
      SubtitleGenerator.generate_srt(ts_path, srt_path)
      puts "  ✓ srt: #{srt_path}" unless quiet?
      true
    rescue => e
      $stderr.puts "  ✗ #{base}: srt regen failed: #{e.message}"
      false
    end

    def run_video(config, base, mp3_path, mp4_path)
      cover_path = CoverResolver.find_episode_cover(config.episodes_dir, base)
      print "  rebuilding video: " unless quiet?
      result = VideoBuilder.build(
        mp3_path: mp3_path, cover_path: cover_path, video_path: mp4_path, force: true
      )
      case result.status
      when :built
        puts result.video_path unless quiet?
        true
      when :no_cover
        $stderr.puts "\n  ✗ #{base}: #{result.message} (run `podgen cover #{@podcast_name} #{base.sub(/\A#{Regexp.escape(@podcast_name)}-/, '')}` first)"
        false
      when :no_audio, :failed
        $stderr.puts "\n  ✗ #{base}: video step failed (#{result.message})"
        false
      end
    end

    # Resolves which English episode basenames to operate on. Mirrors the
    # convention used by voice/render: --date narrows to that day (and
    # suffix if given); --last N takes the most-recent N; nothing → latest.
    def resolve_basenames(config)
      all_bases = english_script_basenames(config)
      return [] if all_bases.empty?

      if last_n
        all_bases.last(last_n)
      elsif episode_date
        date_str = episode_date.strftime("%Y-%m-%d")
        target = "#{config.name}-#{date_str}#{episode_suffix}"
        episode_suffix ? all_bases.select { |b| b == target } : all_bases.select { |b| b.include?(date_str) }
      else
        [all_bases.last]
      end
    end

    def english_script_basenames(config)
      Dir.glob(File.join(config.episodes_dir, "*_script.md"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}_script\.md\z/) }
        .sort
        .map { |f| File.basename(f, "_script.md") }
    end

    def quiet?
      @options[:verbosity] == :quiet
    end
  end
end
