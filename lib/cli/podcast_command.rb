# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  # Shared helpers for CLI commands that operate on a single podcast.
  # Include in command classes that accept a podcast name argument.
  module PodcastCommand
    private

    # Validates that @podcast_name is set and exists. Prints usage and available
    # podcasts if missing or unknown. Returns exit code 2 on failure, nil on success.
    def require_podcast!(command_name)
      available = PodcastConfig.available

      unless @podcast_name
        $stderr.puts "Usage: podgen #{command_name} <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      return nil if available.include?(@podcast_name)

      $stderr.puts "Unknown podcast: #{@podcast_name}"
      $stderr.puts
      suggest_similar(@podcast_name, available)
      $stderr.puts "Available podcasts:"
      available.each { |name| $stderr.puts "  - #{name}" }
      2
    end

    def suggest_similar(name, available)
      close = available.select { |a| levenshtein(name, a) <= [name.length / 3, 2].max }
      return if close.empty?

      $stderr.puts "Did you mean?"
      close.each { |c| $stderr.puts "  - #{c}" }
      $stderr.puts
    end

    def levenshtein(a, b)
      m, n = a.length, b.length
      d = Array.new(m + 1) { |i| i }
      (1..n).each do |j|
        prev = d[0]
        d[0] = j
        (1..m).each do |i|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          temp = d[i]
          d[i] = [d[i] + 1, d[i - 1] + 1, prev + cost].min
          prev = temp
        end
      end
      d[m]
    end

    # Creates and returns a PodcastConfig, calling load_env! automatically.
    def load_config!
      @config = PodcastConfig.new(@podcast_name)
      @config.load_env!
      @config
    end

    # Raises if any positional args remain after expected positionals were
    # extracted. Catches typos like `-rss URL` (parsed as `--rss=ss` plus a
    # leftover `URL`) and stray words like `generate <pod> extra_arg`.
    def reject_leftover_args!(args)
      return if args.empty?
      raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
    end
  end
end
