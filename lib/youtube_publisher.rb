# frozen_string_literal: true

require_relative "regen_cache"
require_relative "upload_tracker"
require_relative "transcript_parser"
require_relative "cover_resolver"

# Publishes pending episodes to YouTube for a single podcast configuration.
#
# Extracted from PublishCommand#publish_to_youtube so that batch flows
# (e.g. yt-batch) can call it in-process and inspect a structured Result
# instead of parsing subprocess stdout for "uploaded N" / "rate limited".
#
# Calls RegenCache.ensure_regen so RSS+site regen happens once per podcast
# per process — when run from yt-batch, the second-and-later ticks per pod
# (round-robin) skip regen automatically.
class YouTubePublisher
  Result = Struct.new(:uploaded, :attempted, :rate_limited, :errors, keyword_init: true) do
    def success? = errors.empty? && !rate_limited
  end

  TIMESTAMP_ENGINE_PRIORITY = %w[groq elab open].freeze

  # In-process cache of (pod_name, playlist_id) verifications. Round-robin
  # creates a fresh publisher per upload, so without this each tick would
  # hit YouTube's playlists API N×M times (M = pending eps per pod) instead
  # of once per pod per tick.
  @verified_playlists = {}
  @verify_mutex = Mutex.new

  class << self
    def playlist_verified?(key)
      @verify_mutex.synchronize { @verified_playlists[key] }
    end

    def mark_playlist_verified(key)
      @verify_mutex.synchronize { @verified_playlists[key] = true }
    end

    def reset_playlist_cache!
      @verify_mutex.synchronize { @verified_playlists.clear }
    end
  end

  def initialize(config:, options: {}, uploader: nil, tracker_path: nil)
    @config = config
    @options = options
    @uploader = uploader
    @tracker_path = tracker_path
  end

  def run
    unless @config.youtube_enabled?
      msg = "YouTube not configured. Add ## YouTube section to guidelines.md and set YOUTUBE_CLIENT_ID/YOUTUBE_CLIENT_SECRET."
      $stderr.puts msg
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                        errors: [{ type: :not_configured, message: msg }])
    end

    RegenCache.ensure_regen(@config) { regenerate! }

    yt_config = @config.youtube_config
    playlist = yt_config[:playlist] || "default"
    language = @config.transcription_language || "en"

    episodes = scan_episodes
    uploaded_map = @options[:force] ? {} : tracker.entries_for(:youtube, playlist)
    pending = episodes.reject { |ep| uploaded_map.key?(ep[:base_name]) }
    pending = pending.first(@options[:max]) if @options[:max]

    if pending.empty?
      puts "All episodes already uploaded to YouTube#{yt_config[:playlist] ? " playlist #{yt_config[:playlist]}" : ""}." unless quiet?
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false, errors: [])
    end

    puts "#{pending.length} episode(s) to upload to YouTube" unless quiet?

    if @options[:dry_run]
      pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless quiet?
      puts "(dry run)" unless quiet?
      return Result.new(uploaded: 0, attempted: 0, rate_limited: false, errors: [])
    end

    require_relative "youtube_uploader"
    require_relative "subtitle_generator"
    require_relative "video_generator"

    uploader = active_uploader

    if yt_config[:playlist]
      verify_key = "#{@config.name}:#{yt_config[:playlist]}"
      unless self.class.playlist_verified?(verify_key)
        begin
          uploader.verify_playlist!(yt_config[:playlist])
          self.class.mark_playlist_verified(verify_key)
        rescue => e
          $stderr.puts "YouTube playlist verification failed: #{e.message}"
          return Result.new(uploaded: 0, attempted: 0, rate_limited: false,
                            errors: [{ type: :playlist_verification, message: e.message }])
        end
      end
    end

    upload_loop(pending, uploader, yt_config, playlist, language)
  end

  private

  def upload_loop(pending, uploader, yt_config, playlist, language)
    uploaded = 0
    attempted = 0
    rate_limited = false
    errors = []

    pending.each do |ep|
      begin
        title, description, _ = parse_transcript(ep[:transcript_path])
        srt_path = prepare_subtitles(ep)

        video_path = ensure_video(ep, errors) or next
        attempted += 1

        puts "  uploading: #{ep[:base_name]} — \"#{title}\"" unless quiet?

        video_id = uploader.upload_video(
          video_path,
          title: title,
          description: description.to_s,
          language: language,
          privacy: yt_config[:privacy] || "unlisted",
          category: yt_config[:category] || "27",
          tags: yt_config[:tags] || []
        )

        tracker.record(:youtube, playlist, ep[:base_name], video_id)

        uploader.upload_captions(video_id, srt_path, language: language) if srt_path && File.exist?(srt_path)
        uploader.add_to_playlist(video_id, yt_config[:playlist]) if yt_config[:playlist]

        uploaded += 1
        puts "  ✓ #{ep[:base_name]} → https://youtu.be/#{video_id}" unless quiet?
      rescue Google::Apis::ClientError => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        if e.message.include?("uploadLimitExceeded") || e.message.include?("quotaExceeded")
          $stderr.puts "  YouTube quota exceeded — stopping batch. Retry after quota resets."
          rate_limited = true
          errors << { type: :rate_limit, base: ep[:base_name], message: e.message }
          break
        end
        errors << { type: :upload, base: ep[:base_name], message: e.message }
      rescue => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        errors << { type: :upload, base: ep[:base_name], message: e.message }
      end
    end

    Result.new(uploaded: uploaded, attempted: attempted, rate_limited: rate_limited, errors: errors)
  end

  def prepare_subtitles(ep)
    episodes_dir = @config.episodes_dir
    ts_path = File.join(episodes_dir, "#{ep[:base_name]}_timestamps.json")
    retranscribe_for_timestamps(ep[:mp3_path], ts_path, ep[:base_name]) unless File.exist?(ts_path)
    reconcile_subtitles_if_needed(ts_path, ep[:transcript_path]) if File.exist?(ts_path)
    srt_path = File.join(episodes_dir, "#{ep[:base_name]}.srt")
    SubtitleGenerator.generate_srt(ts_path, srt_path) if File.exist?(ts_path)
    srt_path
  end

  def ensure_video(ep, errors)
    require_relative "video_builder"

    video_path = File.join(@config.episodes_dir, "#{ep[:base_name]}.mp4")
    cover_path = CoverResolver.find_episode_cover(@config.episodes_dir, ep[:base_name])

    puts "  generating video #{ep[:base_name]}..." if !File.exist?(video_path) && cover_path && !quiet?
    result = VideoBuilder.build(mp3_path: ep[:mp3_path], cover_path: cover_path, video_path: video_path)

    case result.status
    when :built, :exists then result.video_path
    when :no_cover
      $stderr.puts "  ✗ #{ep[:base_name]} skipped: no cover image found"
      errors << { type: :missing_cover, base: ep[:base_name], message: "no cover image" }
      nil
    when :no_audio, :failed
      $stderr.puts "  ✗ #{ep[:base_name]} video step failed: #{result.message}"
      errors << { type: :video, base: ep[:base_name], message: result.message }
      nil
    end
  end

  def regenerate!
    require_relative "cli/rss_command"
    require_relative "site_generator"
    PodgenCLI::RssCommand.new([@config.name], { verbosity: @options[:verbosity] }).run
    SiteGenerator.new(config: @config, clean: true).generate
  rescue => e
    $stderr.puts "Warning: site/feed regen failed: #{e.message}"
  end

  def scan_episodes
    episodes_dir = @config.episodes_dir
    return [] unless Dir.exist?(episodes_dir)

    Dir.glob(File.join(episodes_dir, "*.mp3"))
      .sort
      .filter_map do |mp3_path|
        base_name = File.basename(mp3_path, ".mp3")
        text_path = find_text_file(episodes_dir, base_name)
        next unless text_path
        { base_name: base_name, mp3_path: mp3_path, transcript_path: text_path }
      end
  end

  def find_text_file(dir, base_name)
    %w[_transcript.md _script.md].each do |suffix|
      path = File.join(dir, "#{base_name}#{suffix}")
      return path if File.exist?(path)
    end
    nil
  end

  def parse_transcript(path)
    parsed = TranscriptParser.parse(path)
    [parsed.title, parsed.description, parsed.body]
  end

  def reconcile_subtitles_if_needed(ts_path, transcript_path)
    require_relative "subtitle_reconciliation_runner"

    print "  reconciling subtitles: #{File.basename(ts_path)}..." unless quiet?
    result = SubtitleReconciliationRunner.run(ts_path: ts_path, transcript_path: transcript_path)
    case result.status
    when :reconciled            then puts " done" unless quiet?
    when :already_reconciled,
         :no_api_key,
         :no_transcript,
         :no_timestamps         then puts " skipped (#{result.message})" unless quiet?
    when :failed                then $stderr.puts "\n  Warning: subtitle reconciliation failed: #{result.message} (using raw segments)"
    end
  end

  def retranscribe_for_timestamps(mp3_path, ts_path, base_name)
    language = @config.transcription_language
    unless language
      puts "  ⚠ #{base_name}: no transcription language configured, skipping subtitles" unless quiet?
      return
    end

    engine_code = pick_timestamp_engine
    unless engine_code
      puts "  ⚠ #{base_name}: no transcription engine configured, skipping subtitles" unless quiet?
      return
    end

    puts "  transcribing #{base_name} for subtitles (#{engine_code})..." unless quiet?

    require_relative "transcription/engine_manager"
    require_relative "timestamp_persister"

    manager = Transcription::EngineManager.new(
      engine_codes: [engine_code],
      language: language,
      target_language: @config.target_language
    )
    result = manager.transcribe(mp3_path)
    segments, engine_code = TimestampPersister.extract_segments(result, engine_codes: [engine_code])

    if segments && !segments.empty?
      TimestampPersister.persist(
        segments: segments,
        engine: engine_code,
        intro_duration: 0.0,
        output_path: ts_path
      )
    else
      puts "  ⚠ #{base_name}: transcription returned no segments" unless quiet?
    end
  rescue => e
    $stderr.puts "  ⚠ #{base_name}: retranscription failed (#{e.message}), uploading without subtitles"
  end

  def pick_timestamp_engine
    configured = @config.transcription_engines
    TIMESTAMP_ENGINE_PRIORITY.find { |e| configured.include?(e) } || configured.first
  end

  def active_uploader
    @uploader ||= YouTubeUploader.new
  end

  def tracker
    @tracker ||= @tracker_path ? UploadTracker.new(@tracker_path) : UploadTracker.for_config(@config)
  end

  def quiet?
    @options[:verbosity] == :quiet
  end
end
