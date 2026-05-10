# frozen_string_literal: true

require "optparse"
require "date"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "format_helper")
require_relative File.join(root, "lib", "yaml_loader")
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "episode_filtering")
require_relative File.join(root, "lib", "word_stats")

module PodgenCLI
  class StatsCommand
    def initialize(args, options)
      @options = options
      @all = false
      @downloads = false
      @days = 30
      @words = false
      @top = 50
      @sort = "body"
      OptionParser.new do |opts|
        opts.on("--all", "Show stats for all podcasts") { @all = true }
        opts.on("--downloads", "Show download analytics from Cloudflare") { @downloads = true }
        opts.on("--days N", Integer, "Lookback period for downloads (default 30)") { |n| @days = n }
        opts.on("--today", "Downloads for today (shortcut for --days 1)") { @downloads = true; @days = 1 }
        opts.on("--week", "Downloads for last 7 days") { @downloads = true; @days = 7 }
        opts.on("--month", "Downloads for last 30 days") { @downloads = true; @days = 30 }
        opts.on("--words", "Vocabulary frequency across all episodes") { @words = true }
        opts.on("--top N", Integer, "Limit --words to top N rows (default 50, 0 = all)") { |n| @top = n }
        opts.on("--sort COL", %w[body vocab], "Sort --words by 'body' (default) or 'vocab' frequency") { |s| @sort = s }
      end.parse!(args)
      @podcast_name = args.shift
      unless args.empty?
        raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
      end
    end

    def run
      if @words
        return run_words
      elsif @downloads
        run_downloads
      elsif @all
        run_all
      elsif @podcast_name
        run_single(@podcast_name)
      else
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen stats <podcast_name>"
        $stderr.puts "       podgen stats --all"
        $stderr.puts "       podgen stats --downloads [podcast] [--days N]"
        $stderr.puts "       podgen stats --today|--week|--month [podcast]"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end
    end

    private

    def run_words
      unless @podcast_name
        $stderr.puts "Usage: podgen stats <podcast> --words [--top N]"
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      stats = WordStats.new(config: config, logger: nil).build(top: @top)
      if stats.empty?
        puts "#{@podcast_name}: no vocabulary data found"
        return 0
      end

      sorted = case @sort
               when "vocab" then stats.sort_by { |s| [-s.vocab_count, -s.body_count, s.lemma] }
               else              stats.sort_by { |s| [-s.body_count, -s.vocab_count, s.lemma] }
               end
      sorted = sorted.first(@top) if @top.positive?

      puts "Vocabulary frequency for '#{@podcast_name}' (#{stats.length} unique lemma(s)):"
      puts
      printf "  %5s  %5s  %-22s  %-10s  %s\n", "BODY", "VOCAB", "LEMMA", "POS", "DEFINITION"
      printf "  %5s  %5s  %-22s  %-10s  %s\n", "─────", "─────", "─" * 22, "─" * 10, "─" * 30
      sorted.each do |s|
        printf "  %5d  %5d  %-22s  %-10s  %s\n",
               s.body_count, s.vocab_count,
               truncate(s.lemma, 22),
               truncate(s.pos.to_s, 10),
               truncate(s.definition.to_s, 50)
      end
      0
    end

    def truncate(str, width)
      return str if str.length <= width
      str[0, width - 1] + "…"
    end

    def run_downloads
      require_relative "../analytics_client"
      client = AnalyticsClient.new

      unless client.configured?
        $stderr.puts "Download analytics not configured."
        $stderr.puts "Set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in .env"
        $stderr.puts "See docs/cloudflare.md for setup."
        return 2
      end

      if @podcast_name
        show_podcast_downloads(client, @podcast_name)
      else
        show_all_downloads(client)
      end

      0
    rescue => e
      $stderr.puts "Analytics query failed: #{e.message}"
      1
    end

    def show_all_downloads(client)
      totals = client.podcast_totals(days: @days)

      if totals.empty?
        puts "No download data for the last #{@days} days."
        return
      end

      valid = PodcastConfig.available
      totals.select! { |r| valid.include?(r[:podcast]) }
      return puts "No download data for known podcasts." if totals.empty?

      podcasts = totals.map { |r| r[:podcast] }
      total_dl = totals.sum { |r| r[:downloads] }

      puts "Downloads (last #{@days} days): #{total_dl} total"
      totals.each do |row|
        avg = row[:days] > 0 ? (row[:downloads].to_f / row[:days]).round(1) : 0
        puts "  #{row[:podcast]}: #{row[:downloads]} (#{avg}/day)"
      end

      # Fetch per-podcast breakdowns
      apps = {}
      countries = {}
      daily = {}
      episodes = {}
      podcasts.each do |name|
        apps[name] = client.app_breakdown(podcast: name, days: @days)
        countries[name] = client.country_breakdown(podcast: name, days: @days)
        daily[name] = client.daily_breakdown(podcast: name, days: @days)
        episodes[name] = client.episode_downloads(podcast: name, days: @days)
      end

      puts
      print_pivoted_table("Apps", podcasts, apps, :app, :downloads)

      puts
      print_pivoted_table("Countries", podcasts, countries, :country, :downloads)

      puts
      print_pivoted_table("Daily", podcasts, daily, :date, :downloads, sort: :key_desc)

      # Episodes: side-by-side per podcast (names differ across podcasts)
      episode_columns = podcasts.filter_map do |name|
        eps = episodes[name]
        next if eps.empty?
        name_w = [eps.map { |r| r[:episode].length }.max, 20].max
        lines = eps.map { |r| format("  %-#{name_w}s %6d", r[:episode], r[:downloads]) }
        { header: "Episodes (#{name}):", lines: lines }
      end

      if episode_columns.any?
        puts
        print_side_by_side(episode_columns)
      end
    end

    def show_podcast_downloads(client, podcast)
      episodes = client.episode_downloads(podcast: podcast, days: @days)
      countries = client.country_breakdown(podcast: podcast, days: @days)
      apps = client.app_breakdown(podcast: podcast, days: @days)
      daily = client.daily_breakdown(podcast: podcast, days: @days)

      total = episodes.sum { |r| r[:downloads] }
      avg = daily.any? ? (total.to_f / daily.length).round(1) : 0

      puts "Downloads for #{podcast} (last #{@days} days): #{total} total, #{avg}/day avg"

      if apps.any?
        puts
        puts "  Apps:"
        apps.each do |row|
          puts "    %-24s %6d" % [row[:app], row[:downloads]]
        end
      end

      # Episodes / Countries / Daily: three columns side by side
      columns = []

      if episodes.any?
        name_w = [episodes.map { |r| r[:episode].length }.max, 20].max
        lines = episodes.map { |r| format("  %-#{name_w}s %6d", r[:episode], r[:downloads]) }
        columns << { header: "Episodes:", lines: lines }
      end

      if countries.any?
        lines = countries.map { |r| format("  %-6s %6d", r[:country], r[:downloads]) }
        columns << { header: "Countries:", lines: lines }
      end

      if daily.any?
        lines = daily.map { |r| format("  %-12s %6d", r[:date], r[:downloads]) }
        columns << { header: "Daily:", lines: lines }
      end

      if columns.any?
        puts
        print_side_by_side(columns)
      end
    end

    def run_all
      podcasts = PodcastConfig.available
      if podcasts.empty?
        puts "No podcasts found."
        return 0
      end

      rows = podcasts.map { |name| gather_stats(name) }

      # Header
      fmt = "%-16s %-9s %8s %9s %9s %5s %5s %3s"
      puts format(fmt, "Podcast", "Type", "Episodes", "Duration", "Size", "Feed", "Cover", "URL")
      rows.each do |r|
        puts format(fmt,
          truncate(r[:name], 16),
          r[:type],
          r[:episode_count],
          r[:duration],
          r[:size],
          r[:feed_count] || "-",
          r[:has_cover] ? "yes" : "no",
          r[:has_url] ? "yes" : "no"
        )
      end
      0
    end

    def run_single(name)
      config = PodcastConfig.new(name)
      config.load_env!

      stats = gather_stats(name)
      verbose = @options[:verbosity] == :verbose

      puts "#{name} — #{config.title}"
      puts "  Type:       #{config.type}"
      puts "  Episodes:   #{stats[:episode_count]}#{stats[:date_range]}"
      puts "  Duration:   #{stats[:duration]}"
      puts "  Size:       #{stats[:size]}"
      puts "  Languages:  #{config.languages.map { |l| l['code'] }.join(', ')}"
      puts "  Sources:    #{format_sources(config.sources)}"

      if stats[:feed_count]
        feed_mtime = File.mtime(config.feed_path).strftime("%b %d") rescue nil
        feed_info = "feed.xml (#{stats[:feed_count]} episodes"
        feed_info += ", built #{feed_mtime}" if feed_mtime
        feed_info += ")"
        puts "  Feed:       #{feed_info}"
      else
        puts "  Feed:       not generated"
      end

      if stats[:cover_path]
        cover_size = format_size(File.size(stats[:cover_path]))
        puts "  Cover:      #{File.basename(stats[:cover_path])} (#{cover_size})"
      else
        puts "  Cover:      none"
      end

      if config.base_url
        puts "  Base URL:   #{config.base_url}"
      end

      if verbose
        puts
        puts "  Episodes:"
        stats[:episodes].each do |ep|
          puts "    #{ep[:filename]}  #{ep[:size_str]}  #{ep[:duration_str]}"
        end

        # Research cache
        cache_dir = File.join(File.dirname(config.episodes_dir), "research_cache")
        if Dir.exist?(cache_dir)
          cache_files = Dir.glob(File.join(cache_dir, "*"))
          cache_size = cache_files.sum { |f| File.size(f) rescue 0 }
          puts
          puts "  Research cache: #{cache_files.length} files (#{format_size(cache_size)})"
        end

        # Tails directory (language pipeline)
        tails_dir = File.join(File.dirname(config.episodes_dir), "tails")
        if Dir.exist?(tails_dir)
          tail_files = Dir.glob(File.join(tails_dir, "*.mp3"))
          tail_size = tail_files.sum { |f| File.size(f) rescue 0 }
          puts "  Tails:          #{tail_files.length} files (#{format_size(tail_size)})"
        end

        # History stats
        entries = YamlLoader.load(config.history_path, default: nil)
        if entries.is_a?(Array)
          topics = entries.flat_map { |e| e["topics"] || [] }.uniq
          puts
          puts "  History:    #{entries.length} entries, #{topics.length} unique topics"
        end
      end

      0
    end

    def gather_stats(name)
      config = PodcastConfig.new(name)
      config.load_env!

      episodes_dir = config.episodes_dir
      mp3s = EpisodeFiltering.all_episodes(episodes_dir).sort

      # Build duration map from history to avoid ffprobe calls where possible
      duration_map = build_duration_map(config)

      total_size = mp3s.sum { |f| File.size(f) rescue 0 }
      total_seconds = mp3s.sum { |f|
        duration_map[File.basename(f)] || AudioAssembler.probe_duration(f) || File.size(f) / (192_000.0 / 8)
      }

      # Date range from filenames
      dates = mp3s.filter_map { |f|
        m = File.basename(f).match(/(\d{4}-\d{2}-\d{2})/)
        Date.parse(m[1]) rescue nil if m
      }.uniq.sort

      date_range = if dates.length >= 2
        " (#{dates.first.strftime('%b %d')} – #{dates.last.strftime('%b %d, %Y')})"
      elsif dates.length == 1
        " (#{dates.first.strftime('%b %d, %Y')})"
      else
        ""
      end

      # Feed episode count
      feed_count = nil
      if File.exist?(config.feed_path)
        require "rexml/document"
        begin
          doc = REXML::Document.new(File.read(config.feed_path))
          feed_count = doc.elements.to_a("//item").length
        rescue
          feed_count = nil
        end
      end

      # Cover
      output_dir = File.dirname(config.episodes_dir)
      cover_path = nil
      if config.image
        candidate = File.join(output_dir, config.image)
        cover_path = candidate if File.exist?(candidate)
        unless cover_path
          candidate = File.join(config.podcast_dir, config.image)
          cover_path = candidate if File.exist?(candidate)
        end
      end

      # Per-episode details (for verbose)
      episode_details = mp3s.map do |path|
        fname = File.basename(path)
        size = File.size(path) rescue 0
        secs = duration_map[fname] || AudioAssembler.probe_duration(path) || size / (192_000.0 / 8)
        {
          filename: fname,
          size_str: format_size(size),
          duration_str: format_duration_short(secs)
        }
      end

      {
        name: name,
        type: config.type,
        episode_count: mp3s.length,
        duration: format_duration(total_seconds),
        size: format_size(total_size),
        date_range: date_range,
        feed_count: feed_count,
        has_cover: !cover_path.nil?,
        cover_path: cover_path,
        has_url: !config.base_url.nil?,
        episodes: episode_details
      }
    end

    # Build a map of MP3 filename → duration (seconds) from history entries.
    # Same suffix logic as RssGenerator to match filenames to history entries.
    SUFFIXES = [""] + ("a".."z").to_a

    def build_duration_map(config)
      entries = YamlLoader.load(config.history_path, default: nil)
      return {} unless entries.is_a?(Array)

      podcast_name = File.basename(File.dirname(config.episodes_dir))
      by_date = {}
      entries.each do |entry|
        date = entry["date"]
        next unless date
        (by_date[date] ||= []) << entry
      end

      map = {}
      by_date.each do |date, date_entries|
        date_entries.each_with_index do |entry, idx|
          next unless entry["duration"]
          suffix = SUFFIXES[idx] || idx.to_s
          map["#{podcast_name}-#{date}#{suffix}.mp3"] = entry["duration"]
        end
      end
      map
    end

    # Renders pre-formatted text columns side by side.
    # columns: [{ header: String, lines: [String] }]
    def print_side_by_side(columns, gap: 3)
      return if columns.empty?

      widths = columns.map do |col|
        ([col[:header].length] + col[:lines].map(&:length)).max
      end

      max_rows = columns.map { |c| c[:lines].length }.max || 0

      header = columns.each_with_index.map { |col, i|
        format("%-#{widths[i]}s", col[:header])
      }.join(" " * gap)
      puts "  #{header.rstrip}"

      max_rows.times do |r|
        line = columns.each_with_index.map { |col, i|
          text = col[:lines][r] || ""
          format("%-#{widths[i]}s", text)
        }.join(" " * gap)
        puts "  #{line.rstrip}"
      end
    end

    # Renders a table with shared row labels and one value column per podcast.
    # per_podcast: { name => [{ label_key => x, value_key => y }] }
    def print_pivoted_table(title, podcasts, per_podcast, label_key, value_key, sort: :value)
      totals = Hash.new(0)
      per_podcast.each_value do |rows|
        rows.each { |r| totals[r[label_key]] += r[value_key] }
      end
      return if totals.empty?

      labels = case sort
               when :value then totals.sort_by { |_, v| -v }.map(&:first)
               when :key_desc then totals.keys.sort.reverse
               else totals.keys.sort
               end

      lookups = per_podcast.transform_values do |rows|
        rows.each_with_object({}) { |r, h| h[r[label_key]] = r[value_key] }
      end

      label_w = ["#{title}:".length, *labels.map { |l| l.to_s.length }].max
      val_ws = podcasts.map do |p|
        vals = labels.filter_map { |l| lookups.dig(p, l)&.to_s&.length }
        [p.length, *vals].max
      end

      line = format("  %-#{label_w}s", "#{title}:")
      podcasts.each_with_index { |p, i| line += format("  %#{val_ws[i]}s", p) }
      puts line

      labels.each do |label|
        line = format("  %-#{label_w}s", label.to_s)
        podcasts.each_with_index do |p, i|
          val = lookups.dig(p, label)
          line += val ? format("  %#{val_ws[i]}d", val) : (" " * (val_ws[i] + 2))
        end
        puts line
      end
    end

    def format_sources(sources)
      sources.map do |key, value|
        if value.is_a?(Array)
          "#{key} (#{value.length} #{value.length == 1 ? 'feed' : 'feeds'})"
        else
          key
        end
      end.join(", ")
    end

    def format_duration(seconds)
      hours = (seconds / 3600).to_i
      mins = ((seconds % 3600) / 60).to_i
      if hours > 0
        "#{hours}h #{mins}m"
      else
        "#{mins}m"
      end
    end

    def format_duration_short(seconds)
      FormatHelper.format_duration_mmss(seconds)
    end

    def format_size(bytes)
      FormatHelper.format_size(bytes, mb_precision: 0)
    end

    def truncate(str, max)
      str.length > max ? str[0...max - 1] + "…" : str
    end
  end
end
