# frozen_string_literal: true

require_relative "regen_cache"
require_relative "upload_tracker"
require_relative "episode_scanner"
require_relative "transcript_parser"
require_relative "cover_resolver"

# Uploads pending episodes to LingQ for a single podcast configuration.
#
# Extracted from PublishCommand#publish_to_lingq so UploadsCommand can drive
# the per-pod batch flow (R2 → LingQ → YT) in-process and inspect a
# structured Result for each phase.
class LingQPublisher
  Result = Struct.new(:uploaded, :attempted, :errors, keyword_init: true) do
    def success? = errors.empty?
    def failed? = !success?
  end

  def initialize(config:, options: {}, agent: nil, tracker_path: nil, episode_id: nil)
    @config = config
    @options = options
    @agent = agent
    @tracker_path = tracker_path
    @episode_id = episode_id
  end

  def run
    unless @config.lingq_enabled?
      msg = "LingQ not configured. Add ## LingQ section with collection to guidelines.md and set LINGQ_API_KEY."
      $stderr.puts msg
      return Result.new(uploaded: 0, attempted: 0,
                        errors: [{ type: :not_configured, message: msg }])
    end

    unless @config.transcription_language
      msg = "Transcription language not configured. Add language to ## Audio section in guidelines.md."
      $stderr.puts msg
      return Result.new(uploaded: 0, attempted: 0,
                        errors: [{ type: :no_language, message: msg }])
    end

    RegenCache.ensure_regen(@config) { regenerate! }

    lc = @config.lingq_config
    collection = lc[:collection]
    episodes = scan_episodes
    if episodes.empty? && @episode_id
      $stderr.puts "No episode found matching '#{@episode_id}'"
      return Result.new(uploaded: 0, attempted: 0, errors: [])
    end

    uploaded_map = @options[:force] ? {} : tracker.entries_for(:lingq, collection)
    pending = episodes.reject { |ep| uploaded_map.key?(ep[:base_name]) }

    if pending.empty?
      puts "All episodes already uploaded to LingQ collection #{collection}." unless quiet?
      return Result.new(uploaded: 0, attempted: 0, errors: [])
    end

    puts "#{pending.length} episode(s) to upload to LingQ collection #{collection}" unless quiet?

    if @options[:dry_run]
      pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless quiet?
      puts "(dry run)" unless quiet?
      return Result.new(uploaded: 0, attempted: 0, errors: [])
    end

    upload_loop(pending, lc, collection)
  end

  private

  def upload_loop(pending, lc, collection)
    agent = active_agent
    language = @config.transcription_language
    uploaded = 0
    attempted = 0
    errors = []

    pending.each do |ep|
      attempted += 1
      image_path = nil
      begin
        title, description, transcript = parse_transcript(ep[:transcript_path])
        image_path = find_episode_cover(ep[:base_name]) || generate_cover_image(title, description: description)

        puts "  uploading: #{ep[:base_name]} — \"#{title}\"" unless quiet?

        site_url = @config.base_url ? "#{@config.base_url}/site/episodes/#{ep[:base_name]}.html" : nil

        lesson_id = agent.upload(
          title: title,
          text: transcript,
          audio_path: ep[:mp3_path],
          language: language,
          collection: collection,
          level: lc[:level],
          tags: lc[:tags],
          image_path: image_path,
          accent: lc[:accent],
          status: lc[:status],
          description: description,
          original_url: site_url
        )

        tracker.record(:lingq, collection, ep[:base_name], lesson_id)
        uploaded += 1
        puts "  ✓ #{ep[:base_name]} → lesson #{lesson_id}" unless quiet?
      rescue => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        errors << { type: :upload, base: ep[:base_name], message: e.message }
      ensure
        CoverResolver.cleanup(image_path)
      end
    end

    Result.new(uploaded: uploaded, attempted: attempted, errors: errors)
  end

  def regenerate!
    require_relative "cli/rss_command"
    require_relative "site_generator"
    PodgenCLI::RssCommand.new([@config.name], { verbosity: @options[:verbosity] }).run
    SiteGenerator.new(config: @config, clean: true).generate
  rescue => e
    $stderr.puts "Warning: site/feed regen failed: #{e.message}" if @options[:verbosity] == :verbose
  end

  def active_agent
    return @agent if @agent
    require_relative "agents/lingq_agent"
    LingQAgent.new(api_key: @config.lingq_config&.[](:token))
  end

  def scan_episodes
    EpisodeScanner.scan(@config.episodes_dir, episode_id: @episode_id)
  end

  def parse_transcript(path)
    parsed = TranscriptParser.parse(path)
    [parsed.title, parsed.description, parsed.body]
  end

  def find_episode_cover(base_name)
    CoverResolver.find_episode_cover(@config.episodes_dir, base_name)
  end

  def generate_cover_image(title, description: nil)
    return @config.cover_static_image unless @config.cover_generation_enabled?

    result = CoverResolver.generate(
      title: title,
      base_image: @config.cover_base_image,
      options: @config.cover_options
    )
    unless result
      $stderr.puts "  Warning: cover generation failed (using static image)" if @options[:verbosity] == :verbose
    end
    result || @config.cover_static_image
  end

  def tracker
    @tracker ||= @tracker_path ? UploadTracker.new(@tracker_path) : UploadTracker.for_config(@config)
  end

  def quiet?
    @options[:verbosity] == :quiet
  end
end
