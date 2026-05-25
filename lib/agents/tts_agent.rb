# frozen_string_literal: true

require "httparty"
require "json"
require "base64"
require "open3"
require "digest"
require "yaml"
require "fileutils"
require "tmpdir"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../http_retryable"
require_relative "../yaml_loader"
require_relative "../audio_assembler"
require_relative "../text_splitter"

class TTSAgent
  include Loggable
  include Retryable
  include HttpRetryable

  ELEVENLABS_BASE_URL = "https://api.elevenlabs.io/v1/text-to-speech"
  # Backwards-compat alias used in tests / external callers.
  BASE_URL = ELEVENLABS_BASE_URL
  DICT_API_URL = "https://api.elevenlabs.io/v1/pronunciation-dictionaries"
  OPENAI_DEFAULT_BASE_URL = "https://api.openai.com/v1"
  OPENAI_MAX_CHARS = 4_096
  TRIM_THRESHOLD = 0.5 # seconds of trailing audio before we trim
  # Upper bound on trim. ElevenLabs eleven_v3 sometimes returns
  # character_end_times_seconds that under-reports the real speech end by
  # tens of seconds for long chunks (alignment array truncated). Trusting
  # that and silencing everything past it wipes real speech. Anything above
  # this is treated as bad alignment data — skip the trim with a warning.
  MAX_TRIM_SECONDS = 5.0
  # Models whose `character_end_times_seconds` is too unreliable to base
  # any trim/silence decision on. eleven_v3 routinely under-reports the
  # real speech end by 0.5–1.5s, which falls inside the trim threshold
  # band and silences the last words of segments. For these models, skip
  # the trim entirely and accept any trailing room tone as-is.
  MODELS_WITH_UNRELIABLE_ALIGNMENT = %w[eleven_v3].freeze
  DEFAULT_MAX_CHARS = 9_500 # Safety margin below v2's 10,000 char limit
  # Per-model character limits per request (with safety margin).
  # eleven_v3 has a tighter ~5k limit; v2/turbo allow ~10k.
  MODEL_MAX_CHARS = {
    "eleven_v3"              => 4_500,
    "eleven_multilingual_v2" => 9_500,
    "eleven_multilingual_v1" => 9_500,
    "eleven_turbo_v2_5"      => 9_500,
    "eleven_turbo_v2"        => 9_500,
    "eleven_flash_v2_5"      => 9_500,
    "eleven_flash_v2"        => 9_500
  }.freeze
  DEFAULT_MODEL_ID = "eleven_multilingual_v2"
  MAX_RETRIES = 3
  # Models that don't accept previous_request_ids / next_request_ids
  # (the API returns HTTP 400 unsupported_model). Cross-chunk continuity
  # is silently disabled for these.
  MODELS_WITHOUT_REQUEST_CONTINUITY = %w[eleven_v3].freeze
  # Backwards-compat alias for callers/tests that referenced the constant.
  MAX_CHARS = DEFAULT_MAX_CHARS

  def initialize(logger: nil, voice_id_override: nil, model_id_override: nil,
                 engine_override: nil, base_url_override: nil,
                 pronunciation_pls_path: nil)
    @logger = logger
    @engine = (engine_override || ENV.fetch("TTS_ENGINE", "elevenlabs")).to_s

    if @engine == "openai"
      @api_key   = ENV.fetch("OPENAI_API_KEY", "local")
      @base_url  = base_url_override || ENV.fetch("TTS_BASE_URL", OPENAI_DEFAULT_BASE_URL)
      @voice_id  = voice_id_override || ENV.fetch("OPENAI_TTS_VOICE", "onyx")
      @model_id  = model_id_override || ENV.fetch("OPENAI_TTS_MODEL", "tts-1")
      @splitter  = TextSplitter.new(max_chars: OPENAI_MAX_CHARS)
      @pronunciation_locators = []
    else
      @api_key = ENV.fetch("ELEVENLABS_API_KEY") { raise "ELEVENLABS_API_KEY environment variable is not set" }
      @voice_id = voice_id_override || ENV.fetch("ELEVENLABS_VOICE_ID") { raise "ELEVENLABS_VOICE_ID environment variable is not set" }
      @model_id = model_id_override || ENV.fetch("ELEVENLABS_MODEL_ID", DEFAULT_MODEL_ID)
      @output_format = ENV.fetch("ELEVENLABS_OUTPUT_FORMAT", "mp3_44100_128")
      @pronunciation_locators = resolve_pronunciation_dictionary(pronunciation_pls_path)
      @splitter = TextSplitter.new(max_chars: max_chars_for_model(@model_id))
    end
  end

  private

  def max_chars_for_model(model_id)
    MODEL_MAX_CHARS[model_id] || DEFAULT_MAX_CHARS
  end

  public

  # Input: array of { name:, text: } segment hashes
  # Output: ordered array of file paths to MP3 files
  def synthesize(segments)
    return synthesize_openai(segments) if @engine == "openai"

    audio_paths = []
    previous_request_ids = []
    log("Model: #{@model_id}, voice: #{@voice_id} (max #{max_chars_for_model(@model_id)} chars/chunk)")

    segments.each_with_index do |segment, idx|
      log("Synthesizing segment #{idx + 1}/#{segments.length}: #{segment[:name]} (#{segment[:text].length} chars)")
      start = Time.now

      chunks = @splitter.split(segment[:text])

      chunks.each_with_index do |chunk, chunk_idx|
        log("  Chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk.length} chars)") if chunks.length > 1

        path = File.join(Dir.tmpdir, "podgen_#{idx}_#{chunk_idx}_#{Process.pid}.mp3")
        request_id = synthesize_chunk(
          text: chunk,
          path: path,
          previous_request_ids: previous_request_ids.last(3)
        )

        audio_paths << path
        previous_request_ids << request_id if request_id

        log("  Saved #{File.size(path)} bytes → #{path}")
      end

      elapsed = (Time.now - start).round(2)
      log("  Done in #{elapsed}s")
    end

    audio_paths
  end

  private

  def synthesize_openai(segments)
    log("OpenAI-compatible TTS: #{@base_url}, model: #{@model_id}, voice: #{@voice_id} (max #{OPENAI_MAX_CHARS} chars/chunk)")
    audio_paths = []

    segments.each_with_index do |segment, idx|
      log("Synthesizing segment #{idx + 1}/#{segments.length}: #{segment[:name]} (#{segment[:text].length} chars)")
      start = Time.now

      chunks = @splitter.split(segment[:text])
      chunks.each_with_index do |chunk, chunk_idx|
        log("  Chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk.length} chars)") if chunks.length > 1
        path = File.join(Dir.tmpdir, "podgen_#{idx}_#{chunk_idx}_#{Process.pid}.mp3")
        synthesize_openai_chunk(text: chunk, path: path)
        audio_paths << path
        log("  Saved #{File.size(path)} bytes → #{path}")
      end

      elapsed = (Time.now - start).round(2)
      log("  Done in #{elapsed}s")
    end

    audio_paths
  end

  def synthesize_openai_chunk(text:, path:)
    url = "#{@base_url}/audio/speech"
    body = { model: @model_id, input: text, voice: @voice_id, response_format: "mp3" }

    with_retries(max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
      response = HTTParty.post(
        url,
        headers: {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => "application/json"
        },
        body: body.to_json,
        timeout: 120
      )

      case response.code
      when 200
        File.binwrite(path, response.body)
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "OpenAI TTS failed: HTTP #{response.code}: #{response.body.to_s[0, 200]}"
      end
    end
  end

  def synthesize_chunk(text:, path:, previous_request_ids: [])
    url = "#{BASE_URL}/#{@voice_id}/with-timestamps?output_format=#{@output_format}"

    body = {
      text: text,
      model_id: @model_id,
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.0,
        use_speaker_boost: true
      }
    }
    if !previous_request_ids.empty? && !MODELS_WITHOUT_REQUEST_CONTINUITY.include?(@model_id)
      body[:previous_request_ids] = previous_request_ids
    end
    body[:pronunciation_dictionary_locators] = @pronunciation_locators unless @pronunciation_locators.empty?

    with_retries(max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
      response = HTTParty.post(
        url,
        headers: {
          "xi-api-key" => @api_key,
          "Content-Type" => "application/json"
        },
        body: body.to_json,
        timeout: 120
      )

      case response.code
      when 200
        data = JSON.parse(response.body)
        audio_bytes = Base64.decode64(data["audio_base64"])
        File.open(path, "wb") { |f| f.write(audio_bytes) }

        alignment = data["alignment"]
        trim_trailing_audio(path, alignment) if alignment

        response.headers["request-id"]
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "TTS failed: HTTP #{response.code}: #{parse_error(response)}"
      end
    end
  end

  def trim_trailing_audio(path, alignment)
    if MODELS_WITH_UNRELIABLE_ALIGNMENT.include?(@model_id)
      log("  Skipping trim: #{@model_id} alignment data is unreliable (silences real speech)")
      return
    end

    end_times = alignment["character_end_times_seconds"]
    return unless end_times&.any?

    speech_end = end_times.last
    audio_duration = probe_duration(path)
    trailing = audio_duration - speech_end

    log("  Trailing audio: #{trailing.round(2)}s (speech ends at #{speech_end.round(2)}s, audio is #{audio_duration.round(2)}s)")

    return unless trailing > TRIM_THRESHOLD

    if trailing > MAX_TRIM_SECONDS
      log("  WARNING: alignment data appears truncated (claims #{trailing.round(2)}s trailing). " \
          "Skipping trim to avoid silencing real speech.")
      return
    end

    silenced_path = "#{path}.silenced.mp3"
    af = "volume=enable='gt(t,#{speech_end})':volume=0"
    cmd = ["ffmpeg", "-y", "-i", path, "-af", af, "-c:a", "libmp3lame", "-b:a", "192k", silenced_path]
    _out, err, status = Open3.capture3(*cmd)

    unless status.success?
      log("  WARNING: ffmpeg silence failed, keeping original: #{err}")
      return
    end

    FileUtils.mv(silenced_path, path)
    log("  Silenced #{trailing.round(2)}s trailing audio (replaced with silence)")
  end

  def probe_duration(path)
    AudioAssembler.probe_duration(path) || raise("ffprobe failed for #{path}")
  end

  def resolve_pronunciation_dictionary(pls_path)
    return [] unless pls_path && File.exist?(pls_path)

    file_sha = Digest::SHA256.file(pls_path).hexdigest
    cache_path = pls_path.sub(/\.pls$/, ".yml")
    cached = load_dict_cache(cache_path)

    if cached && cached[:file_sha256] == file_sha
      log("Using cached pronunciation dictionary #{cached[:dictionary_id]}")
      return [{ pronunciation_dictionary_id: cached[:dictionary_id], version_id: cached[:version_id] }]
    end

    log("Uploading pronunciation dictionary: #{File.basename(pls_path)}")
    dict = upload_pronunciation_dictionary(pls_path)
    save_dict_cache(cache_path, dict[:dictionary_id], dict[:version_id], file_sha)
    log("Pronunciation dictionary ready: #{dict[:dictionary_id]} (v#{dict[:version_id]})")

    [{ pronunciation_dictionary_id: dict[:dictionary_id], version_id: dict[:version_id] }]
  rescue => e
    log("WARNING: Pronunciation dictionary failed, continuing without: #{e.message}")
    []
  end

  def upload_pronunciation_dictionary(pls_path)
    name = "podgen_#{File.basename(pls_path, '.pls')}_#{Time.now.strftime('%Y%m%d%H%M%S')}"

    with_retries(max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
      response = HTTParty.post(
        "#{DICT_API_URL}/add-from-file",
        headers: { "xi-api-key" => @api_key },
        multipart: true,
        body: {
          name: name,
          file: octet_stream_file_part(pls_path)
        },
        timeout: 30
      )

      case response.code
      when 200
        data = JSON.parse(response.body)
        { dictionary_id: data["id"], version_id: data["version_id"] }
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "Upload failed: HTTP #{response.code}: #{parse_error(response)}"
      end
    end
  end

  # Wraps a file for HTTParty multipart upload with an explicit Content-Type.
  # MiniMime maps .pls → "application/pls+xml", which ElevenLabs'
  # /add-from-file parser rejects with HTTP 400 "Lexicon file formatted
  # incorrectly". Curl sends application/octet-stream by default and the
  # API accepts it; we mirror that behavior.
  def octet_stream_file_part(path)
    require "delegate"
    file = File.open(path, "rb")
    wrapper = SimpleDelegator.new(file)
    wrapper.define_singleton_method(:content_type) { "application/octet-stream" }
    wrapper
  end

  def load_dict_cache(path)
    data = YamlLoader.load(path, default: nil)
    return nil unless data.is_a?(Hash) && data["dictionary_id"] && data["version_id"] && data["file_sha256"]

    { dictionary_id: data["dictionary_id"], version_id: data["version_id"], file_sha256: data["file_sha256"] }
  end

  def save_dict_cache(path, dictionary_id, version_id, file_sha)
    File.write(path, YAML.dump({
      "dictionary_id" => dictionary_id,
      "version_id" => version_id,
      "file_sha256" => file_sha
    }))
  end

end
