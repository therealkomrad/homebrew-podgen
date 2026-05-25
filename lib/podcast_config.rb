# frozen_string_literal: true

require "fileutils"
require "date"
require_relative "yaml_loader"
require_relative "time_value"
require_relative "episode_filtering"
require_relative "guidelines_parser"
require_relative "cover_resolver"

class PodcastConfig
  attr_reader :name, :podcast_dir, :guidelines_path, :queue_path, :links_path, :episodes_dir, :feed_path, :log_dir, :history_path, :excluded_urls_path

  def initialize(name)
    @name = name
    @root = self.class.root
    @podcast_dir = File.join(@root, "podcasts", name)
    podcast_dir = @podcast_dir

    unless Dir.exist?(podcast_dir)
      raise "Unknown podcast: #{name}. Available: #{self.class.available.join(', ')}"
    end

    @guidelines_path = File.join(podcast_dir, "guidelines.md")
    @queue_path      = File.join(podcast_dir, "queue.yml")
    @links_path      = File.join(podcast_dir, "links.yml")
    @env_path        = File.join(podcast_dir, ".env")
    @episodes_dir    = File.join(@root, "output", name, "episodes")
    @feed_path       = File.join(@root, "output", name, "feed.xml")
    @history_path    = File.join(@root, "output", name, "history.yml")
    @excluded_urls_path = File.join(@root, "output", name, "excluded_urls.yml")
    @log_dir         = File.join(@root, "logs", name)
  end

  # Load per-podcast .env overrides on top of root .env.
  # Must be called after Dotenv.load (root .env).
  def load_env!
    return unless File.exist?(@env_path)

    require "dotenv"
    Dotenv.overload(@env_path)
  end

  # Comment-stripped guidelines text (used by ScriptAgent, ValidateCommand, etc.)
  def guidelines
    parser.text
  end

  # Warnings collected during guidelines parsing (e.g. misindented Audio
  # section keys that were silently dropped). Surfaced by the validator.
  def parser_warnings
    parser.warnings
  end

  # --- Delegated to GuidelinesParser ---

  def sources
    parser.sources
  end

  def languages
    parser.languages
  end

  def title
    @title ||= parser.podcast_section[:name] || parser.extract_heading("Name") || @name
  end

  def author
    @author ||= parser.podcast_section[:author] || parser.extract_heading("Author") || "Podcast Agent"
  end

  def type
    @type ||= parser.podcast_section[:type] || parser.extract_heading("Type") || "news"
  end

  def description
    @description ||= parser.podcast_section[:description]
  end

  def base_url
    @base_url ||= parser.podcast_section[:base_url]
  end

  def cover
    @cover ||= parser.image_section[:cover] || parser.podcast_section[:image]
  end

  def image
    @image ||= cover
  end

  def cover_base_image
    @cover_base_image ||= parser.image_section[:base_image] || lingq_config&.dig(:base_image)
  end

  def cover_static_image
    @cover_static_image ||= begin
      if parser.image_section[:cover]
        resolve_path(parser.image_section[:cover])
      elsif lingq_config&.dig(:image)
        lingq_config[:image] # already resolved by parser
      end
    end
  end

  def cover_options
    @cover_options ||= begin
      src = parser.image_section.any? ? parser.image_section : (lingq_config || {})
      CoverResolver::OVERLAY_KEYS.each_with_object({}) { |k, h| h[k] = src[k] if src[k] }
    end
  end

  # Returns the user-provided overrides for AutoCoverResolver settings.
  # Only keys explicitly set in ## Image are returned; the resolver merges
  # with its own defaults. Keys: auto_cover_min_bytes, auto_cover_min_score,
  # auto_cover_candidates, auto_cover_model.
  # Minimum/maximum episode length in seconds, parsed from ## Sources keys
  # min_length: / max_length: (e.g. "2:00", "9:30", "01:23:45", or "775").
  # Returns nil when not configured. Used by EpisodeSource to filter RSS
  # episodes by their itunes_duration metadata before download.
  def min_length_seconds
    return @min_length_seconds if defined?(@min_length_seconds)
    @min_length_seconds = parse_length(parser.sources["min_length"])
  end

  def max_length_seconds
    return @max_length_seconds if defined?(@max_length_seconds)
    @max_length_seconds = parse_length(parser.sources["max_length"])
  end

  # Per-podcast TTS model override. Reads `tts_model:` from ## Audio.
  # Returns nil when not set (callers fall back to ENV or TTSAgent defaults).
  def tts_model_id
    return @tts_model_id if defined?(@tts_model_id)
    raw = parser.audio_section[:tts_model]
    @tts_model_id = raw.is_a?(String) && !raw.strip.empty? ? raw.strip : nil
  end

  # TTS engine override. Reads `tts_engine:` from ## Audio.
  # Values: "elevenlabs" (default), "openai" (also covers openedai-speech / Piper via local URL).
  def tts_engine
    return @tts_engine if defined?(@tts_engine)
    raw = parser.audio_section[:tts_engine]
    @tts_engine = raw.is_a?(String) && !raw.strip.empty? ? raw.strip : nil
  end

  # Per-podcast TTS voice override. Reads `tts_voice:` from ## Audio.
  # For OpenAI: alloy/echo/fable/onyx/nova/shimmer. For ElevenLabs: voice UUID.
  def tts_voice
    return @tts_voice if defined?(@tts_voice)
    raw = parser.audio_section[:tts_voice]
    @tts_voice = raw.is_a?(String) && !raw.strip.empty? ? raw.strip : nil
  end

  # Base URL for OpenAI-compatible TTS. Reads `tts_base_url:` from ## Audio.
  # Defaults to OpenAI cloud when nil. Set to e.g. "http://localhost:8000/v1"
  # for openedai-speech (free, local Piper/Kokoro-82M).
  def tts_base_url
    return @tts_base_url if defined?(@tts_base_url)
    raw = parser.audio_section[:tts_base_url]
    @tts_base_url = raw.is_a?(String) && !raw.strip.empty? ? raw.strip : nil
  end

  def auto_cover_config
    @auto_cover_config ||= begin
      src = parser.image_section
      %i[auto_cover_min_bytes auto_cover_min_score auto_cover_candidates auto_cover_model]
        .each_with_object({}) { |key, h| h[key] = src[key] if src[key] }
    end
  end

  def pronunciation_pls_path
    path = File.join(@podcast_dir, "pronunciation.pls")
    File.exist?(path) ? path : nil
  end

  def site_config
    parser.site_config
  end

  def site_css_path
    path = File.join(@podcast_dir, "site.css")
    File.exist?(path) ? path : nil
  end

  def favicon_path
    %w[favicon.ico favicon.png favicon.svg].each do |name|
      path = File.join(@podcast_dir, name)
      return path if File.exist?(path)
    end
    nil
  end

  def target_language
    @target_language ||= parser.audio_section[:target_language] || parser.extract_heading("Target Language")
  end

  def transcription_language
    @transcription_language ||= parser.audio_section[:language] || parser.extract_heading("Transcription Language")
  end

  def skip
    @skip ||= begin
      val = parser.audio_section[:skip]
      return val if val
      val = parser.extract_heading("Skip Intro")
      val ? TimeValue.parse(val) : nil
    end
  end

  def cut
    @cut ||= parser.audio_section[:cut]
  end

  def autotrim
    @autotrim ||= parser.audio_section[:autotrim]
  end

  def transcription_engines
    parser.transcription_engines
  end

  def lingq_config
    parser.lingq_config
  end

  def links_config
    parser.links_config
  end

  def vocabulary_level
    parser.vocabulary_config&.dig(:level)
  end

  def vocabulary_max
    parser.vocabulary_config&.dig(:max)
  end

  def vocabulary_target_languages
    raw = parser.vocabulary_config&.dig(:target)
    return ["English"] unless raw
    raw.split(",").map(&:strip)
  end

  def vocabulary_target_language
    vocabulary_target_languages.first
  end

  def vocabulary_filters
    config = parser.vocabulary_config
    return {} unless config
    config.slice(:frequency, :similar, :filter, :priority).compact
  end

  def links_enabled?
    !!links_config&.dig(:show)
  end

  def youtube_config
    parser.youtube_config
  end

  def youtube_enabled?
    config = youtube_config
    has_creds = [ENV["YOUTUBE_CLIENT_ID"], ENV["YOUTUBE_CLIENT_SECRET"]].all? { |v| v && !v.empty? }
    config && has_creds
  end

  def lingq_enabled?
    config = lingq_config
    has_key = config&.[](:token) || (ENV["LINGQ_API_KEY"] && !ENV["LINGQ_API_KEY"].empty?)
    config && config[:collection] && has_key
  end

  def twitter_config
    parser.twitter_config
  end

  # Returns the per-language glossary Hash for a language code, or {} if no
  # glossary is configured for that language.
  def translation_glossary_for(lang_code)
    parser.translation_glossary[lang_code.to_s] || {}
  end

  def twitter_enabled?
    twitter_config && %w[TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET
      TWITTER_ACCESS_TOKEN TWITTER_ACCESS_SECRET].all? { |k| ENV[k] && !ENV[k].empty? }
  end

  # Extracts the language code from an episode basename. Basenames with a
  # trailing `-xx` (two-letter ISO code) are non-primary; otherwise the
  # episode is in the primary language.
  def language_for_episode(basename)
    match = basename.match(/-([a-z]{2})\z/)
    return primary_language unless match
    code = match[1]
    # Defensive: the regex accepts any two-letter suffix, but only a code
    # actually configured for this podcast counts as a language.
    configured = languages.map { |l| l["code"] }
    configured.include?(code) ? code : primary_language
  end

  def primary_language
    languages.first&.dig("code") || "en"
  end

  # Builds the public URL of an episode's HTML page on the published site,
  # inserting `/<lang>/` for non-primary languages so the URL points at the
  # actual rendered file (site_generator places non-primary pages under
  # `<root>/<lang>/episodes/`).
  def site_episode_url(basename)
    return nil unless base_url
    lang = language_for_episode(basename)
    prefix = lang == primary_language ? "" : "/#{lang}"
    "#{base_url}/site#{prefix}/episodes/#{basename}.html"
  end

  def cover_generation_enabled?
    bi = cover_base_image
    bi && File.exist?(bi)
  end

  def queue_topics
    YamlLoader.load(@queue_path, default: {}, raise_on_error: true)["topics"]
  end

  def ensure_directories!
    FileUtils.mkdir_p(@episodes_dir)
    FileUtils.mkdir_p(@log_dir)
  end

  # Returns the next available episode basename (without extension) for the given date.
  # First run:  ruby_world-2026-02-18
  # Second run: ruby_world-2026-02-18a
  # Third run:  ruby_world-2026-02-18b
  #
  # The slot-walk picks the LOWEST free letter, not the next sequential one
  # after the count — so `move`-ing out the bare slot frees it up cleanly,
  # and a gap from any other operation gets filled before pushing further
  # along the alphabet.
  def episode_basename(date = Date.today)
    date_str = date.strftime("%Y-%m-%d")
    prefix = "#{@name}-#{date_str}"
    existing = Dir.glob(File.join(@episodes_dir, "#{prefix}*.mp3"))
      .reject { |f| File.basename(f).include?("_concat") }
      .select { |f| EpisodeFiltering.matches_language?(File.basename(f, ".mp3"), "en") }
      .map { |f| File.basename(f, ".mp3") }
      .to_set

    ([""] + ("a".."z").to_a).each do |suffix|
      candidate = "#{prefix}#{suffix}"
      return candidate unless existing.include?(candidate)
    end
    raise "No free episode slot for #{date_str} — all 27 suffixes are taken"
  end

  def episode_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}.mp3")
  end

  def script_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}_script.md")
  end

  def transcript_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}_transcript.md")
  end

  def episode_basename_for_language(date, language_code:)
    base = episode_basename(date)
    language_code == "en" ? base : "#{base}-#{language_code}"
  end

  def episode_path_for_language(date, language_code:)
    File.join(@episodes_dir, "#{episode_basename_for_language(date, language_code: language_code)}.mp3")
  end

  def script_path_for_language(date, language_code:)
    File.join(@episodes_dir, "#{episode_basename_for_language(date, language_code: language_code)}_script.md")
  end

  def log_path(date = Date.today)
    File.join(@log_dir, "#{episode_basename(date)}.log")
  end

  # Project root: resolved via PODGEN_ROOT env var (set by bin/podgen),
  # falling back to the code location (for direct script usage).
  def self.root
    ENV["PODGEN_ROOT"] || File.expand_path("..", __dir__)
  end

  def self.available
    Dir.glob(File.join(root, "podcasts", "*"))
      .select { |f| Dir.exist?(f) }
      .map { |f| File.basename(f) }
      .sort
  end

  private

  def parser
    @parser ||= GuidelinesParser.new(File.read(@guidelines_path), podcast_dir: @podcast_dir)
  end

  def resolve_path(value)
    return value if value.start_with?("/")
    File.join(@podcast_dir, value)
  end

  def parse_length(value)
    return nil unless value
    raw = value.is_a?(Array) ? value.first : value
    TimeValue.parse_duration_seconds(raw)
  end
end
