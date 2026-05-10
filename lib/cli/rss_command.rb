# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "fileutils"
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "rss_generator")

module PodgenCLI
  class RssCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--base-url URL", "Base URL for enclosures (e.g. https://host.ts.net/podcast)") do |u|
          @options[:base_url] = u
        end
      end.parse!(args)
      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("rss")
      return code if code

      config = load_config!

      base_url = @options[:base_url] || config.base_url

      # Copy cover image from podcast config dir to output dir
      if config.image
        src = File.join(config.podcast_dir, config.image)
        if File.exist?(src)
          dest = File.join(File.dirname(config.feed_path), config.image)
          FileUtils.cp(src, dest)
        else
          $stderr.puts "Warning: image '#{config.image}' not found in #{config.podcast_dir}"
        end
      end

      # Convert markdown transcripts to HTML for podcast apps
      RssGenerator.convert_transcripts(config.episodes_dir)

      feed_paths = []

      config.languages.each do |lang|
        lang_code = lang["code"]

        feed_path = if lang_code == "en"
          config.feed_path
        else
          config.feed_path.sub(/\.xml$/, "-#{lang_code}.xml")
        end

        generator = RssGenerator.new(
          episodes_dir: config.episodes_dir,
          feed_path: feed_path,
          title: config.title,
          description: config.description,
          author: config.author,
          language: lang_code,
          base_url: base_url,
          image: config.image,
          history_path: config.history_path
        )
        generator.generate
        feed_paths << feed_path
      end

      unless @options[:verbosity] == :quiet
        feed_paths.each { |fp| puts "Feed: #{fp}" }
        if base_url
          puts "Feed URL: #{base_url}/feed.xml"
        else
          puts
          puts "To serve locally:"
          puts "  cd #{File.dirname(config.feed_path)} && ruby -run -e httpd . -p 8080"
          puts "  Feed URL: http://localhost:8080/feed.xml"
        end
      end

      0
    end
  end
end
