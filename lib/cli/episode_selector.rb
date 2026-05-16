# frozen_string_literal: true

require "date"
require "optparse"

module PodgenCLI
  # Shared episode-selection parsing for CLI commands that operate on a
  # specific episode (or window of episodes). Include in the command class
  # and call inside its OptionParser block:
  #
  #   add_date_option!(opts)     # adds --date
  #   add_last_option!(opts)     # adds --last N (omit for commands where bulk is unsafe)
  #
  # …or the convenience wrapper for the common case:
  #
  #   add_episode_selection_options!(opts)
  #
  # After parse!, call:
  #
  #   extract_positional_date!(args)   # pops a trailing date positional, if any
  #   reject_leftover_args!(args)
  #   validate_episode_selection!
  #
  # Then read via #episode_date, #episode_suffix, #raw_episode_id,
  # #normalized_episode_id, #last_n.
  #
  # Instance variables owned by this mixin (don't reuse these names for
  # other purposes): @date_arg, @last_n, @parsed_date, @parsed_suffix.
  module EpisodeSelector
    # Token shape used to decide whether the trailing positional is a date:
    # one or more digits/hyphens, optional single trailing lowercase letter.
    # Single-digit positionals are intentional — `podgen voice mypod 1` is
    # "day 1 of the current month". See test_positional_single_digit_day.
    DATE_TOKEN_RE = /\A\d[\d-]*[a-z]?\z/

    # Parses the flexible date forms accepted on the command line.
    # Returns [Date, suffix_or_nil]. Raises ArgumentError on anything else.
    module DateParser
      SUPPORTED_FORMS = "YYYY-MM-DD, YYYYMMDD, MM-DD, MMDD, or DD"
      SUFFIX_RE = /([a-z])\z/

      module_function

      def parse(raw, today: Date.today)
        raise ArgumentError, "Empty date" if raw.nil? || raw.empty?

        body, suffix = strip_suffix(raw)
        ymd = extract_ymd(body, today)
        raise ArgumentError, "Invalid date '#{raw}' — use #{SUPPORTED_FORMS}" unless ymd
        y, m, d = ymd

        date =
          begin
            Date.new(y, m, d)
          rescue Date::Error => e
            raise ArgumentError, "Invalid date '#{raw}': #{e.message}"
          end

        [date, suffix]
      end

      def strip_suffix(raw)
        m = raw.match(SUFFIX_RE)
        return [raw, nil] unless m
        body = raw[0..-2]
        # Suffix is only meaningful if the rest looks like digits/hyphens.
        return [raw, nil] if body.empty? || body.match?(/[^\d-]/)
        [body, m[1]]
      end

      # Returns [year, month, day] or nil if the body doesn't match a supported form.
      # MM-DD accepts single-digit month or day (e.g. "3-31", "3-1") for symmetry
      # with the bare DD form. MMDD is strict-4-digit to stay disjoint from DD.
      def extract_ymd(body, today)
        case body
        when /\A(\d{4})-(\d{2})-(\d{2})\z/   then [$1.to_i, $2.to_i, $3.to_i]
        when /\A(\d{4})(\d{2})(\d{2})\z/     then [$1.to_i, $2.to_i, $3.to_i]
        when /\A(\d{1,2})-(\d{1,2})\z/       then [today.year, $1.to_i, $2.to_i]
        when /\A(\d{2})(\d{2})\z/            then [today.year, $1.to_i, $2.to_i]
        when /\A(\d{1,2})\z/                 then [today.year, today.month, $1.to_i]
        end
      end
    end

    def add_date_option!(opts)
      opts.on("--date DATE", "Episode date YYYY-MM-DD[a-z] (also accepted as trailing positional; short forms MMDD, MM-DD, DD use current year/month)") do |v|
        @date_arg = v
      end
    end

    def add_last_option!(opts)
      opts.on("--last N", Integer, "Operate on N most recent episodes (mutually exclusive with --date)") do |n|
        @last_n = n
      end
    end

    def add_episode_selection_options!(opts)
      add_date_option!(opts)
      add_last_option!(opts)
    end

    # Pops a trailing positional date if present. Raises if it duplicates --date.
    def extract_positional_date!(args)
      return if args.empty?
      return unless args.last.match?(DATE_TOKEN_RE)
      pos = args.pop
      if @date_arg
        raise OptionParser::ParseError, "Specify date via positional or --date, not both"
      end
      @date_arg = pos
    end

    def validate_episode_selection!
      if @date_arg && @last_n
        raise OptionParser::ParseError, "--date and --last are mutually exclusive"
      end
      parse_date_arg! if @date_arg
    end

    def episode_date
      parse_date_arg! if @date_arg && @parsed_date.nil?
      @parsed_date
    end

    def episode_suffix
      parse_date_arg! if @date_arg && @parsed_date.nil?
      @parsed_suffix
    end

    # Raw user-typed date string (whatever shape they passed). Most callers
    # want #normalized_episode_id instead.
    def raw_episode_id
      @date_arg
    end

    # Episode identifier in canonical "YYYY-MM-DD[a-z]" form regardless of
    # the input shape the user typed. Nil when no date was given.
    def normalized_episode_id
      return nil unless episode_date
      "#{episode_date.strftime('%Y-%m-%d')}#{episode_suffix}"
    end

    def last_n
      @last_n
    end

    # English (non-language-suffixed) basenames of episodes that have a
    # `_script.md` file. Use this for commands that only make sense on
    # script-bearing episodes — most notably `voice`, which re-voices
    # from the saved script JSON. NOT pipeline-agnostic: language-pipeline
    # podcasts never produce `_script.md` so this returns [] for them.
    def english_script_basenames(config)
      Dir.glob(File.join(config.episodes_dir, "*_script.md"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}_script\.md\z/) }
        .sort
        .map { |f| File.basename(f, "_script.md") }
    end

    # English (non-language-suffixed) basenames of every episode in the
    # podcast, identified by the `.mp3` artifact (the only file every
    # pipeline produces). Use this for commands that operate on the
    # produced episode regardless of how it was authored — regen, cover,
    # etc. Excludes per-language MP3s like `-jp.mp3`.
    def english_episode_basenames(config)
      Dir.glob(File.join(config.episodes_dir, "*.mp3"))
        .reject { |f| File.basename(f).match?(/-[a-z]{2}\.mp3\z/) }
        .sort
        .map { |f| File.basename(f, ".mp3") }
    end

    private

    def parse_date_arg!
      @parsed_date, @parsed_suffix = DateParser.parse(@date_arg, today: episode_selector_today)
    rescue ArgumentError => e
      raise OptionParser::ParseError, e.message
    end

    # Uniquely named hook so a future includer that defines `today` for its
    # own reasons doesn't accidentally hijack date resolution here.
    def episode_selector_today
      respond_to?(:episode_selector_today_override, true) ? send(:episode_selector_today_override) : Date.today
    end
  end
end
