# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "podcast_validator")

module PodgenCLI
  class ValidateCommand
    def initialize(args, options)
      @options = options
      @all = false
      OptionParser.new do |opts|
        opts.on("--all", "Validate all podcasts") { @all = true }
      end.parse!(args)
      @podcast_name = args.shift
      unless args.empty?
        raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
      end
    end

    def run
      if @all
        run_all
      elsif @podcast_name
        run_single(@podcast_name)
      else
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen validate <podcast_name>"
        $stderr.puts "       podgen validate --all"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end
    end

    private

    def run_all
      podcasts = PodcastConfig.available
      if podcasts.empty?
        puts "No podcasts found."
        return 0
      end

      worst = 0
      podcasts.each_with_index do |name, idx|
        puts if idx > 0
        code = run_single(name)
        worst = code if code > worst
      end
      worst
    end

    def run_single(name)
      config = PodcastConfig.new(name)
      config.load_env!

      verbose = @options[:verbosity] == :verbose
      quiet = @options[:verbosity] == :quiet

      puts "Validating #{name}..." unless quiet

      result = PodcastValidator.validate(config)

      unless quiet
        result.passes.each { |msg| puts "  \u2713 #{msg}" } if verbose
        result.warnings.each { |msg| puts "  \u26a0 #{msg}" }
        result.errors.each { |msg| puts "  \u2717 #{msg}" }
        puts
        puts "#{result.passes.length} passed, #{result.warnings.length} warning#{'s' unless result.warnings.length == 1}, #{result.errors.length} error#{'s' unless result.errors.length == 1}"
      end

      if !result.errors.empty?
        2
      elsif !result.warnings.empty?
        1
      else
        0
      end
    end
  end
end
