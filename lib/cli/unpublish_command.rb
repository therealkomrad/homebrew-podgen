# frozen_string_literal: true

require "open3"
require "optparse"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "upload_tracker")

module PodgenCLI
  class UnpublishCommand
    include PodcastCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--youtube", "Delete YouTube videos instead of R2") { @options[:youtube] = true }
      end.parse!(args)
      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def run
      code = require_podcast!("unpublish")
      return code if code

      if @options[:youtube]
        unpublish_youtube
      else
        unpublish_r2
      end
    end

    private

    def unpublish_youtube
      load_config!
      tracker = UploadTracker.for_config(@config)
      tracking = tracker.load
      youtube = tracking["youtube"]

      unless youtube.is_a?(Hash) && youtube.values.any? { |entries| entries.is_a?(Hash) && !entries.empty? }
        puts "No YouTube videos tracked for '#{@podcast_name}'."
        return 0
      end

      videos = youtube.flat_map do |playlist, entries|
        next [] unless entries.is_a?(Hash)
        entries.map { |base_name, video_id| { base_name: base_name, video_id: video_id, playlist: playlist } }
      end

      if @options[:dry_run]
        videos.each { |v| puts "  would delete: #{v[:base_name]} (#{v[:video_id]})" }
        puts "#{videos.length} video(s) would be deleted (dry-run)"
        return 0
      end

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "youtube_uploader")
      uploader = build_youtube_uploader
      uploader.authorize!

      deleted = 0
      failed = 0
      videos.each do |v|
        uploader.remove_from_playlist(v[:video_id], v[:playlist]) if v[:playlist] != "default"
        if uploader.delete_video(v[:video_id])
          puts "  deleted: #{v[:base_name]} (#{v[:video_id]})"
          deleted += 1
        else
          puts "  skipped: #{v[:base_name]} (#{v[:video_id]})"
          failed += 1
        end
      end

      # Clear youtube entries from tracker
      tracking["youtube"] = {}
      tracker.save(tracking)

      puts "Deleted #{deleted} video(s) from YouTube." if deleted > 0
      puts "Skipped #{failed} video(s) (not found or forbidden)." if failed > 0
      0
    end

    def unpublish_r2
      missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
      unless missing.empty?
        $stderr.puts "Missing required environment variables: #{missing.join(', ')}"
        return 2
      end

      unless rclone_available?
        $stderr.puts "rclone is not installed. Install with: brew install rclone"
        return 2
      end

      bucket = ENV["R2_BUCKET"]
      dest = "r2:#{bucket}/#{@podcast_name}/"

      args = ["rclone", "purge", dest]
      args.push("--dry-run") if @options[:dry_run]
      args.push("-v") if @options[:verbosity] == :verbose

      if @options[:dry_run]
        puts "Would remove all files from #{dest} (dry-run)"
      else
        puts "Removing all files from #{dest}"
      end

      success = run_rclone(args)

      unless success
        $stderr.puts "rclone purge failed."
        return 1
      end

      if @options[:dry_run]
        puts "Done (dry-run, no files removed)."
      else
        puts "Unpublished '#{@podcast_name}' from R2."
      end
      0
    end

    def build_youtube_uploader
      YouTubeUploader.new
    end

    def run_rclone(args)
      rclone_env = {
        "RCLONE_CONFIG_R2_TYPE" => "s3",
        "RCLONE_CONFIG_R2_PROVIDER" => "Cloudflare",
        "RCLONE_CONFIG_R2_ACCESS_KEY_ID" => ENV["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY" => ENV["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_R2_ENDPOINT" => ENV["R2_ENDPOINT"],
        "RCLONE_CONFIG_R2_ACL" => "private"
      }
      system(rclone_env, *args)
    end

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
