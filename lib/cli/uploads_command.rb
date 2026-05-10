# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "upload_tracker")
require_relative File.join(root, "lib", "r2_publisher")
require_relative File.join(root, "lib", "lingq_publisher")
require_relative File.join(root, "lib", "youtube_publisher")

module PodgenCLI
  # Per-tick batch upload across multiple podcasts.
  #
  # Two phases per tick:
  #   1. Per-pod sequential: regen RSS+site (cached), R2 sync, LingQ.
  #      R2 failure is hard — pod is skipped from phase 2.
  #      LingQ failure is logged but pod still reaches phase 2 (LingQ retries
  #      next tick on its own pending list).
  #   2. YouTube batch across surviving pods: priority (drain pod by pod) or
  #      round-robin (one ep per pod per round), capped by --max if set.
  #      Rate-limit halts the YT phase but is an EXPECTED daily occurrence
  #      and does NOT contribute to a non-zero overall exit code.
  class UploadsCommand
    def initialize(args, options)
      @options = options
      @mode = :priority
      @max = nil

      OptionParser.new do |opts|
        opts.banner = "Usage: podgen uploads <pod1,pod2,...> [--mode priority|round-robin] [--max N]"
        opts.on("--mode MODE", "priority (default) or round-robin") do |m|
          @mode = m.tr("-", "_").to_sym
        end
        opts.on("--max N", Integer, "Cap TOTAL YT uploads across the tick (default: no cap)") do |n|
          @max = n
        end
      end.parse!(args)

      @pods_arg = args.shift
      unless args.empty?
        raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
      end
    end

    def run
      pods = parse_pods(@pods_arg)
      if pods.empty?
        $stderr.puts "Usage: podgen uploads <pod1,pod2,...> [--mode priority|round-robin] [--max N]"
        return 2
      end

      max_msg = @max ? " (yt-max #{@max})" : ""
      puts "uploads: #{@mode} mode across #{pods.join(', ')}#{max_msg}"

      # Phase 1: per-pod regen + R2 + LingQ. Track failures.
      surviving_pods = []
      failures = []  # any non-rate-limit failure → non-zero exit

      pods.each do |pod|
        puts "─── #{pod} ───"
        r2 = run_r2_for(pod)
        if r2.failed?
          $stderr.puts "uploads: #{pod} R2 sync FAILED — skipping LingQ + YT for this pod"
          failures << { pod: pod, phase: :r2, errors: r2.errors }
          next
        end

        lingq = run_lingq_for(pod)
        # :not_configured isn't a failure — pod just doesn't use LingQ.
        if lingq.failed? && lingq.errors.none? { |e| e[:type] == :not_configured }
          failures << { pod: pod, phase: :lingq, errors: lingq.errors }
        end

        surviving_pods << pod
      end

      # Phase 2: YouTube batch across surviving pods.
      tick = case @mode
             when :priority    then run_priority(surviving_pods)
             when :round_robin then run_round_robin(surviving_pods)
             else
               $stderr.puts "Unknown mode: #{@mode}"
               return 2
             end

      print_summary(tick, failures)

      # Rate limit is expected/daily, not a failure.
      # Any other failure (R2, LingQ non-:not_configured) → exit 1.
      failures.empty? ? 0 : 1
    end

    private

    Tick = Struct.new(:per_pod, :rate_limited, keyword_init: true)

    def run_priority(pods)
      remaining = @max
      per_pod = Hash.new { |h, k| h[k] = { uploaded: 0, errors: 0 } }
      rate_limited = false

      pods.each do |pod|
        break if remaining == 0
        next if pending_count_for(pod) == 0

        result = run_yt_for(pod, max: remaining)
        per_pod[pod][:uploaded] += result.uploaded
        per_pod[pod][:errors] += result.errors.length
        remaining -= result.uploaded if remaining

        if result.rate_limited
          rate_limited = true
          break
        end
      end

      Tick.new(per_pod: per_pod, rate_limited: rate_limited)
    end

    def run_round_robin(pods)
      remaining = @max
      per_pod = Hash.new { |h, k| h[k] = { uploaded: 0, errors: 0 } }
      rate_limited = false
      drained = {}

      catch(:stop) do
        loop do
          uploaded_this_round = 0
          pods.each do |pod|
            throw :stop if remaining == 0
            next if drained[pod]
            if pending_count_for(pod) == 0
              drained[pod] = true
              next
            end

            result = run_yt_for(pod, max: 1)
            per_pod[pod][:uploaded] += result.uploaded
            per_pod[pod][:errors] += result.errors.length
            remaining -= result.uploaded if remaining
            uploaded_this_round += result.uploaded

            if result.rate_limited
              rate_limited = true
              throw :stop
            end

            permanent_skip_only = result.uploaded == 0 &&
                                  result.errors.any? &&
                                  result.errors.all? { |e| e[:type] == :missing_cover }
            if pending_count_for(pod) == 0 || permanent_skip_only
              drained[pod] = true
            end
          end
          break if uploaded_this_round == 0
        end
      end

      Tick.new(per_pod: per_pod, rate_limited: rate_limited)
    end

    def parse_pods(arg)
      return [] if arg.nil? || arg.empty?
      arg.split(",").map(&:strip).reject(&:empty?)
    end

    # Phase-1 hooks (override-able in tests)

    def run_r2_for(pod)
      config = PodcastConfig.new(pod)
      R2Publisher.new(config: config, options: { verbosity: @options[:verbosity] }).run
    rescue => e
      $stderr.puts "uploads: R2 publisher crash for #{pod} (#{e.message})"
      R2Publisher::Result.new(synced: false, tweets_posted: 0,
                              errors: [{ type: :publisher_crash, message: e.message }])
    end

    def run_lingq_for(pod)
      config = PodcastConfig.new(pod)
      LingQPublisher.new(config: config, options: { verbosity: @options[:verbosity] }).run
    rescue => e
      $stderr.puts "uploads: LingQ publisher crash for #{pod} (#{e.message})"
      LingQPublisher::Result.new(uploaded: 0, attempted: 0,
                                 errors: [{ type: :publisher_crash, message: e.message }])
    end

    def run_yt_for(pod, max:)
      config = PodcastConfig.new(pod)
      YouTubePublisher.new(
        config: config,
        options: { max: max, verbosity: @options[:verbosity] }
      ).run
    rescue => e
      $stderr.puts "uploads: YT publisher crash for #{pod} (#{e.message})"
      YouTubePublisher::Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                                   errors: [{ type: :publisher_crash, message: e.message }])
    end

    def pending_count_for(pod)
      config = PodcastConfig.new(pod)
      return 0 unless config.youtube_enabled?

      playlist = config.youtube_config[:playlist] || "default"
      tracker = UploadTracker.for_config(config)
      uploaded = tracker.entries_for(:youtube, playlist)

      episodes = mp3_basenames_with_transcripts(config.episodes_dir)
      episodes.count { |b| !uploaded.key?(b) }
    rescue => e
      $stderr.puts "uploads: skipping YT count for #{pod} (#{e.message})"
      0
    end

    def mp3_basenames_with_transcripts(episodes_dir)
      return [] unless Dir.exist?(episodes_dir)

      Dir.glob(File.join(episodes_dir, "*.mp3")).filter_map do |mp3|
        base = File.basename(mp3, ".mp3")
        has_text = %w[_transcript.md _script.md].any? do |suffix|
          File.exist?(File.join(episodes_dir, "#{base}#{suffix}"))
        end
        base if has_text
      end
    end

    def print_summary(tick, failures)
      puts "─── summary ───"
      tick.per_pod.each do |pod, v|
        puts "  #{pod}: yt-uploaded #{v[:uploaded]}#{v[:errors] > 0 ? " (#{v[:errors]} yt-errors)" : ''}"
      end
      total = tick.per_pod.values.sum { |v| v[:uploaded] }
      puts "uploads: total YT uploaded #{total}#{tick.rate_limited ? ' — STOPPED on YouTube rate limit' : ''}"
      unless failures.empty?
        puts "uploads: #{failures.length} pod(s) had non-YT failures:"
        failures.each { |f| puts "  - #{f[:pod]}: #{f[:phase]} (#{f[:errors].first&.[](:message)})" }
      end
    end
  end
end
