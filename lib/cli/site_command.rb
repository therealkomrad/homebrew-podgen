# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "site_generator")

module PodgenCLI
  class SiteCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @clean = false
      @base_url = nil

      OptionParser.new do |opts|
        opts.on("--clean", "Remove existing site/ before generating") { @clean = true }
        opts.on("--base-url URL", "Override base_url from config") { |url| @base_url = url }
      end.parse!(args)

      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("site")
      return code if code

      load_config!

      generator = SiteGenerator.new(
        config: @config,
        base_url: @base_url,
        clean: @clean
      )

      generator.generate
      0
    end
  end
end
