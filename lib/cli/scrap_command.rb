# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "yaml_loader")
require_relative File.join(root, "lib", "episode_filtering")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "atomic_writer")

module PodgenCLI
  class ScrapCommand
    include PodcastCommand

    SUFFIXES = [""] + ("a".."z").to_a

    def initialize(args, options)
      @exclude = false
      @episode_id = nil
      OptionParser.new do |opts|
        opts.on("--exclude", "Also exclude episode URL from future processing") { @exclude = true }
        opts.on("--date DATE", "Episode date (YYYY-MM-DD)") { |v| @episode_id = v }
      end.parse!(args)

      first_arg = args.first
      if first_arg && (first_arg.include?("/") || File.exist?(first_arg))
        resolved = resolve_from_path(args.shift)
        if resolved
          @podcast_name, @episode_id = resolved unless @episode_id
          @podcast_name ||= resolved[0]
        else
          $stderr.puts "Could not determine podcast/episode from path: #{first_arg}"
          @podcast_name = nil
        end
      else
        @podcast_name = args.shift
        @episode_id ||= args.shift # optional: e.g. "2026-03-31b"
      end
      reject_leftover_args!(args)
      @options = options
      @dry_run = options[:dry_run] || false
    end

    def run
      code = require_podcast!("scrap")
      return code if code

      config = PodcastConfig.new(@podcast_name)
      episodes_dir = config.episodes_dir

      # Resolve which episode to scrap
      target_base, date, suffix_index = resolve_target(config, episodes_dir)
      return 1 unless target_base

      # Find all files related to this episode (mp3 + scripts, all languages).
      # Use multiple globs to avoid matching longer suffixes (e.g. -2026-02-18a for -2026-02-18).
      related_files = %w[.* _* -*].flat_map { |pat|
        Dir.glob(File.join(episodes_dir, "#{target_base}#{pat}"))
      }.uniq
        .reject { |f| File.basename(f).include?("_concat") }
        .sort

      if related_files.empty?
        $stderr.puts "No files found for '#{target_base}'"
        return 1
      end

      # Load history and find matching entry
      history = EpisodeHistory.new(config.history_path)
      entries = YamlLoader.load(config.history_path, default: [])
      matching_entry = find_history_entry(entries, target_base) || find_history_entry_by_date(entries, date, suffix_index)

      # Display what will be removed
      label = @episode_id ? "Episode '#{target_base}'" : "Last episode"
      puts "#{label} for '#{@podcast_name}':"
      if matching_entry
        puts "  Title:  #{matching_entry['title']}"
        puts "  Date:   #{matching_entry['date']}"
        topics = matching_entry['topics'] || []
        topics.each { |t| puts "  Topic:  #{t}" }
        source_count = matching_entry['urls']&.length || 0
        puts "  Sources: #{source_count} (will be freed for reuse)"
        puts
      end

      puts "Files to remove:"
      related_files.each { |f| puts "  #{File.basename(f)}" }
      puts

      # Check if exclusion is available (language pipeline only)
      is_language = config.type == "language"
      episode_urls = matching_entry&.[]("urls") || []
      can_exclude = is_language && episode_urls.any?

      if @dry_run
        puts "[dry-run] Would remove #{related_files.length} file(s) and history entry."
        puts "[dry-run] Would also exclude #{episode_urls.length} URL(s)." if @exclude && can_exclude
        return 0
      end

      # Confirm — offer exclude option for language episodes
      if can_exclude
        $stdout.write "Proceed (x also excludes episode URL from future processing)? [y/N/x] "
      else
        $stdout.write "Proceed? [y/N] "
      end
      $stdout.flush
      answer = $stdin.gets&.strip&.downcase
      unless %w[y x].include?(answer)
        puts "Aborted."
        return 0
      end

      do_exclude = @exclude || answer == "x"

      # Delete files
      related_files.each do |f|
        File.delete(f)
      end

      # Remove history entry (atomic write) — prefer basename match, fall back to positional
      removed = if @episode_id
        history.remove_by_basename!(target_base) || history.remove_by_date!(date, suffix_index)
      else
        history.remove_last!
      end

      # Remove LingQ tracking entry for this episode
      remove_upload_tracking(config, target_base)

      # Exclude episode URLs from future processing
      if do_exclude && can_exclude
        exclude_episode_urls(config, episode_urls)
      end

      title = removed ? "\"#{removed['title']}\"" : target_base
      suffix = do_exclude && can_exclude ? " (excluded)" : ""
      puts "\u2713 Scrapped #{related_files.length} file(s): #{title}#{suffix}"
      0
    end

    private

    # Returns [base_name, date_string, suffix_index] or nil on error.
    def resolve_target(config, episodes_dir)
      if @episode_id
        resolve_by_id(episodes_dir)
      else
        resolve_latest(episodes_dir)
      end
    end

    def resolve_by_id(episodes_dir)
      # Parse episode_id: "2026-03-31" or "2026-03-31b"
      match = @episode_id.match(/\A(\d{4}-\d{2}-\d{2})([a-z])?\z/)
      unless match
        $stderr.puts "Invalid episode identifier '#{@episode_id}' — expected YYYY-MM-DD or YYYY-MM-DD[a-z]"
        return nil
      end

      date = match[1]
      suffix = match[2] || ""
      suffix_index = SUFFIXES.index(suffix) || 0
      base = "#{@podcast_name}-#{date}#{suffix}"

      # Verify the episode exists (match .mp3, _script, -lang variants, not longer suffixes)
      unless %w[.* _* -*].any? { |pat| Dir.glob(File.join(episodes_dir, "#{base}#{pat}")).any? }
        $stderr.puts "No files found matching '#{base}' in #{episodes_dir}"
        return nil
      end

      [base, date, suffix_index]
    end

    def resolve_latest(episodes_dir)
      all_mp3s = EpisodeFiltering.all_episodes(episodes_dir)
        .select { |f| File.basename(f).start_with?("#{@podcast_name}-") }
        .sort

      if all_mp3s.empty?
        $stderr.puts "No episodes found for '#{@podcast_name}'"
        return nil
      end

      english_pattern = /^#{Regexp.escape(@podcast_name)}-(\d{4}-\d{2}-\d{2})([a-z])?\.mp3$/
      english_mp3s = all_mp3s.select { |f| File.basename(f).match?(english_pattern) }

      if english_mp3s.empty?
        $stderr.puts "No base episodes found for '#{@podcast_name}'"
        return nil
      end

      latest = File.basename(english_mp3s.last, ".mp3")
      match = latest.match(/(\d{4}-\d{2}-\d{2})([a-z])?$/)
      date = match[1]
      suffix = match[2] || ""
      suffix_index = SUFFIXES.index(suffix) || 0

      [latest, date, suffix_index]
    end

    # Find history entry by basename (preferred — survives scrapping).
    def find_history_entry(entries, basename)
      entries.find { |e| e["basename"] == basename }
    end

    # Fall back to positional index for old entries without basename.
    def find_history_entry_by_date(entries, date, suffix_index)
      matches = entries.select { |e| e["date"].to_s == date }
      matches[suffix_index]
    end

    # Extract podcast name and episode ID from a file path.
    # Recognizes: podcast-YYYY-MM-DD[a-z][_script|_transcript][.ext]
    #             podcast-YYYY-MM-DD[a-z][-lang][.ext]
    # Returns [podcast_name, episode_id] or nil.
    def resolve_from_path(path)
      basename = File.basename(path)
      match = basename.match(/\A(.+?)-(\d{4}-\d{2}-\d{2})([a-z])?/)
      return nil unless match

      podcast_name = match[1]
      date = match[2]
      suffix = match[3] || ""
      [podcast_name, "#{date}#{suffix}"]
    end

    def remove_upload_tracking(config, base_name)
      UploadTracker.for_config(config).remove(base_name)
    end

    def exclude_episode_urls(config, urls)
      path = config.excluded_urls_path
      current = YamlLoader.load(path, default: [])
      added = urls.reject { |u| current.include?(u) }
      return if added.empty?

      current.concat(added)
      AtomicWriter.write_yaml(path, current)
      added.each { |u| puts "  Excluded: #{u}" }
    end
  end
end
