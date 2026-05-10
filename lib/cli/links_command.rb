# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "priority_links")

module PodgenCLI
  class LinksCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @remove_url = nil
      @clear = false

      require "optparse"
      OptionParser.new do |opts|
        opts.on("--remove URL", "Remove a queued link") { |u| @remove_url = u }
        opts.on("--clear", "Remove all queued links") { @clear = true }
      end.parse!(args)

      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("links")
      return code if code

      config = PodcastConfig.new(@podcast_name)
      links = PriorityLinks.new(config.links_path)

      if @clear
        count = links.clear!
        puts count > 0 ? "\u2713 Cleared #{count} link(s)" : "No links to clear"
        return 0
      end

      if @remove_url
        if links.remove(@remove_url)
          puts "\u2713 Removed: #{@remove_url}"
          puts "  #{links.count} link(s) remaining"
        else
          puts "Not found: #{@remove_url}"
        end
        return 0
      end

      # List all queued links
      entries = links.all
      if entries.empty?
        puts "No priority links queued for '#{@podcast_name}'"
        return 0
      end

      entries.each_with_index do |entry, i|
        line = "  #{i + 1}. #{entry['url']} (#{entry['added']})"
        line += " \u2014 #{entry['note']}" if entry["note"]
        puts line
      end
      puts "  #{entries.length} priority link(s) queued"

      0
    end
  end
end
