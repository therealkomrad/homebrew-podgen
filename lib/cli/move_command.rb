# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "date"
require "fileutils"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "cli", "episode_selector")
require_relative File.join(root, "lib", "cli", "rss_command")
require_relative File.join(root, "lib", "episode_artifacts")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "upload_tracker")

module PodgenCLI
  # Move an episode (or a whole day of episodes) to a different date,
  # renaming all on-disk artifacts and updating history.yml + uploads.yml
  # accordingly. Local-only: doesn't touch remote YouTube/LingQ titles
  # or URLs (those keep their original values; re-publish if needed).
  #
  # Two forms:
  #   podgen move <pod> <from>  <to>     # single episode (auto-suffix on target collision)
  #   podgen move <pod> <from>+ <to>     # whole day (strict; errors on any target collision)
  #
  # Both <from> and <to> accept the flexible date forms parsed by
  # EpisodeSelector::DateParser (YYYY-MM-DD[a-z], YYYYMMDD, MM-DD, MMDD, DD).
  class MoveCommand
    include PodcastCommand

    SUFFIXES = [""] + ("a".."z").to_a

    def initialize(args, options)
      @options = options

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen move <podcast> <from_date> <to_date>"
        opts.separator ""
        opts.separator "  <from_date>+ moves every episode whose date is <from_date>"
        opts.separator "               to <to_date> with suffixes preserved (strict;"
        opts.separator "               errors if anything already exists at <to_date>)."
      end.parse!(args)

      @podcast_name = args.shift
      @from_token   = args.shift
      @to_token     = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("move <podcast> <from_date> <to_date>")
      return code if code

      unless @from_token && @to_token
        $stderr.puts "Error: move requires <from_date> and <to_date>"
        return 2
      end

      config = load_config!

      wildcard = @from_token.end_with?("+")
      to_wildcard = @to_token.end_with?("+")

      if to_wildcard
        $stderr.puts "Error: wildcard '+' is not allowed on <to_date>"
        return 2
      end

      to_date, to_suffix = parse_date(@to_token.sub(/\+\z/, ""))

      if wildcard
        from_date, from_suffix = parse_date(@from_token.sub(/\+\z/, ""))
        if from_suffix
          $stderr.puts "Error: wildcard form requires a bare date (no suffix) on <from_date>"
          return 2
        end
        if to_suffix
          $stderr.puts "Error: <to_date> must be a bare date (no suffix) when using the '+' wildcard"
          return 2
        end
        run_wildcard(config, from_date, to_date)
      else
        from_date, from_suffix = parse_date(@from_token)
        run_single(config, from_date, from_suffix, to_date, to_suffix)
      end
    rescue ArgumentError => e
      $stderr.puts "Error: #{e.message}"
      2
    end

    private

    def parse_date(token)
      EpisodeSelector::DateParser.parse(token)
    end

    # ── single-episode form ──────────────────────────────────────────

    def run_single(config, from_date, from_suffix, to_date, to_suffix)
      from_base = base_for(config, from_date, from_suffix || "")
      from_date_str = from_date.strftime("%Y-%m-%d")
      to_date_str = to_date.strftime("%Y-%m-%d")

      if from_date_str == to_date_str && (from_suffix || "") == (to_suffix || "")
        $stderr.puts "Error: source and target are the same (#{from_base})"
        return 1
      end

      artifacts = EpisodeArtifacts.for_basename(config.episodes_dir, from_base)
      if artifacts.empty?
        $stderr.puts "No episode found at '#{from_base}' in #{config.episodes_dir}"
        nearby = same_day_basenames(config, from_date_str)
        $stderr.puts "Did you mean: #{nearby.join(', ')}?" if nearby.any?
        return 1
      end

      to_base = resolve_target_base(config, to_date, to_suffix)
      return 1 unless to_base

      perform_move(config, [[from_base, to_base]], to_date, artifacts_per_base: { from_base => artifacts })
    end

    # Resolve the target basename for the single-episode form. Returns the
    # chosen basename, or nil after printing an error.
    def resolve_target_base(config, to_date, to_suffix)
      to_date_str = to_date.strftime("%Y-%m-%d")
      podcast = config.name

      if to_suffix
        candidate = "#{podcast}-#{to_date_str}#{to_suffix}"
        if EpisodeArtifacts.for_basename(config.episodes_dir, candidate).any?
          $stderr.puts "Error: target '#{candidate}' already exists. Scrap it first or pick another suffix."
          return nil
        end
        return candidate
      end

      SUFFIXES.each do |s|
        candidate = "#{podcast}-#{to_date_str}#{s}"
        return candidate if EpisodeArtifacts.for_basename(config.episodes_dir, candidate).empty?
      end
      $stderr.puts "Error: target date #{to_date_str} has no free suffix slots (a..z all taken)"
      nil
    end

    # ── wildcard (whole-day) form ────────────────────────────────────

    def run_wildcard(config, from_date, to_date)
      from_date_str = from_date.strftime("%Y-%m-%d")
      to_date_str = to_date.strftime("%Y-%m-%d")

      if from_date_str == to_date_str
        $stderr.puts "Error: source and target dates are the same (#{from_date_str})"
        return 1
      end

      source_bases = same_day_basenames(config, from_date_str)
      if source_bases.empty?
        $stderr.puts "No episodes found on #{from_date_str} in #{config.episodes_dir}"
        return 1
      end

      # Any artifact at the target date is a conflict (any base, any suffix).
      target_existing = same_day_basenames(config, to_date_str)
      if target_existing.any?
        $stderr.puts "Error: target date #{to_date_str} already has episodes: #{target_existing.join(', ')}"
        $stderr.puts "Scrap them first or pick a different target date."
        return 1
      end

      pairs = source_bases.map do |from_base|
        suffix = from_base.sub(/\A#{Regexp.escape(config.name)}-#{Regexp.escape(from_date_str)}/, "")
        [from_base, "#{config.name}-#{to_date_str}#{suffix}"]
      end

      artifacts_per_base = pairs.to_h { |from_base, _| [from_base, EpisodeArtifacts.for_basename(config.episodes_dir, from_base)] }
      perform_move(config, pairs, to_date, artifacts_per_base: artifacts_per_base)
    end

    # ── shared rename + side-effects ─────────────────────────────────

    # pairs: [[from_base, to_base], ...]
    # artifacts_per_base: { from_base => [path, ...] }
    #
    # Each pair's file renames are tracked so we can roll back if any
    # rename fails partway. Pre-validation already ensured no target
    # collisions exist, so failures here mean transient FS errors (disk
    # full, permission, race) — surface them clearly and don't leave a
    # half-moved episode on disk.
    def perform_move(config, pairs, to_date, artifacts_per_base:)
      moved_files = 0
      completed_pairs = []
      pairs.each do |from_base, to_base|
        renamed_in_pair = []
        begin
          artifacts_per_base[from_base].each do |old_path|
            new_filename = File.basename(old_path).sub(/\A#{Regexp.escape(from_base)}/, to_base)
            new_path = File.join(File.dirname(old_path), new_filename)
            File.rename(old_path, new_path)
            renamed_in_pair << [old_path, new_path]
            moved_files += 1
          end
        rescue => e
          moved_files -= renamed_in_pair.length
          rollback_renames!(renamed_in_pair)
          $stderr.puts "Error renaming '#{from_base}' → '#{to_base}': #{e.message}"
          $stderr.puts "Rolled back this episode's #{renamed_in_pair.length} partial rename(s)." if renamed_in_pair.any?
          if completed_pairs.any?
            $stderr.puts "Previously-moved episodes left in place (you may want to move them back manually): #{completed_pairs.map { |f, t| "#{f}→#{t}" }.join(', ')}"
          end
          return 1
        end
        EpisodeHistory.new(config.history_path).rename!(from_base, new_basename: to_base, new_date: to_date)
        UploadTracker.for_config(config).rename(from_base, to_base)
        completed_pairs << [from_base, to_base]
        puts "  ✓ #{from_base} → #{to_base}" unless quiet?
      end

      regenerate_rss(config)
      puts "Moved #{pairs.length} episode(s), #{moved_files} file(s). RSS regenerated." unless quiet?
      0
    end

    # Reverse a partial set of file renames in reverse order so each
    # reverse rename is into an empty slot. Best-effort — log per-file
    # failures but don't raise (the caller has already failed and is
    # about to return non-zero).
    def rollback_renames!(renames)
      renames.reverse_each do |old_path, new_path|
        begin
          File.rename(new_path, old_path)
        rescue => e
          $stderr.puts "  rollback failed for #{File.basename(new_path)} → #{File.basename(old_path)}: #{e.message}"
        end
      end
    end

    def regenerate_rss(config)
      PodgenCLI::RssCommand.new([config.name], { verbosity: @options[:verbosity] }).run
    rescue => e
      $stderr.puts "Warning: RSS regen failed: #{e.message}"
    end

    # ── helpers ──────────────────────────────────────────────────────

    # English (non-language-variant) basenames on a given date.
    def same_day_basenames(config, date_str)
      podcast = config.name
      Dir.glob(File.join(config.episodes_dir, "#{podcast}-#{date_str}*.mp3"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}\.mp3\z/) }
        .map { |f| File.basename(f, ".mp3") }
        .sort
    end

    def base_for(config, date, suffix)
      "#{config.name}-#{date.strftime('%Y-%m-%d')}#{suffix}"
    end

    def quiet?
      @options[:verbosity] == :quiet
    end
  end
end
