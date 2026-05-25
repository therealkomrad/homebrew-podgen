# frozen_string_literal: true

require "httparty"
require "json"
require "base64"
require_relative "colors"
require_relative "../http_retryable"

module Tell
  def self.build_tts(engine, config)
    case engine
    when "elevenlabs" then ElevenlabsTts.new(config)
    when "google"     then GoogleTts.new(config)
    when "openai"     then OpenaiTts.new(config)
    else raise "Unknown tts_engine: #{engine}"
    end
  end

  class ElevenlabsTts
    include HttpRetryable

    BASE_URL = "https://api.elevenlabs.io/v1/text-to-speech"
    MAX_RETRIES = 2

    def initialize(config)
      @api_key       = config.api_key
      @voice_id      = config.voice_id
      @model_id      = config.tts_model_id
      @output_format = config.output_format
    end

    def synthesize(text, voice: nil)
      vid = voice || @voice_id
      url = "#{BASE_URL}/#{vid}?output_format=#{@output_format}"

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

      with_http_retries("ElevenLabs TTS", max: MAX_RETRIES) do
        response = HTTParty.post(
          url,
          headers: {
            "xi-api-key" => @api_key,
            "Content-Type" => "application/json"
          },
          body: body.to_json,
          timeout: 60
        )

        case response.code
        when 200
          response.body
        when *RETRIABLE_CODES
          raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
        else
          raise "ElevenLabs TTS failed: HTTP #{response.code}: #{parse_error(response)}"
        end
      end
    end

  end

  class GoogleTts
    include HttpRetryable

    BASE_URL = "https://texttospeech.googleapis.com/v1/text:synthesize"
    MAX_RETRIES = 2

    # Map ISO 639-1 codes to Google BCP-47 language codes
    LANGUAGE_CODES = {
      "sl" => "sl-SI", "en" => "en-US", "de" => "de-DE", "fr" => "fr-FR",
      "es" => "es-ES", "it" => "it-IT", "pt" => "pt-BR", "nl" => "nl-NL",
      "pl" => "pl-PL", "ja" => "ja-JP", "ko" => "ko-KR", "zh" => "cmn-CN",
      "ru" => "ru-RU", "uk" => "uk-UA", "cs" => "cs-CZ", "hr" => "hr-HR",
      "sr" => "sr-RS", "bg" => "bg-BG", "sk" => "sk-SK", "ro" => "ro-RO",
      "hu" => "hu-HU", "tr" => "tr-TR", "ar" => "ar-XA", "hi" => "hi-IN",
      "th" => "th-TH", "vi" => "vi-VN", "id" => "id-ID", "fi" => "fi-FI",
      "sv" => "sv-SE", "da" => "da-DK", "no" => "nb-NO", "el" => "el-GR",
      "he" => "he-IL"
    }.freeze

    def initialize(config)
      @api_key       = config.tts_api_key
      @voice_name    = config.voice_id
      @language_code = config.google_language_code
    end

    def synthesize(text, voice: nil)
      vname = voice || @voice_name

      body = {
        input: { text: text },
        voice: { languageCode: @language_code, name: vname },
        audioConfig: { audioEncoding: "MP3" }
      }

      with_http_retries("Google TTS", max: MAX_RETRIES) do
        response = HTTParty.post(
          BASE_URL,
          headers: {
            "Content-Type" => "application/json",
            "x-goog-api-key" => @api_key
          },
          body: body.to_json,
          timeout: 60
        )

        case response.code
        when 200
          data = JSON.parse(response.body)
          Base64.decode64(data["audioContent"])
        when *RETRIABLE_CODES
          raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
        else
          raise "Google TTS failed: HTTP #{response.code}: #{parse_error(response)}"
        end
      end
    end

  end

  # OpenAI-compatible TTS — works with OpenAI cloud (tts-1/tts-1-hd) and
  # any local server that mirrors the /v1/audio/speech endpoint, such as
  # openedai-speech (Piper / Kokoro-82M) for zero-cost local generation.
  class OpenaiTts
    include HttpRetryable

    DEFAULT_BASE_URL = "https://api.openai.com/v1"
    MAX_RETRIES = 2

    def initialize(config)
      @api_key  = config.tts_api_key || "local"
      @base_url = config.tts_base_url || DEFAULT_BASE_URL
      @model    = config.tts_model_id || "tts-1"
      @voice    = config.voice_id     || "onyx"
    end

    def synthesize(text, voice: nil)
      body = {
        model:           @model,
        input:           text,
        voice:           voice || @voice,
        response_format: "mp3"
      }

      with_http_retries("OpenAI TTS", max: MAX_RETRIES) do
        response = HTTParty.post(
          "#{@base_url}/audio/speech",
          headers: {
            "Authorization" => "Bearer #{@api_key}",
            "Content-Type"  => "application/json"
          },
          body: body.to_json,
          timeout: 60
        )

        case response.code
        when 200
          response.body
        when *RETRIABLE_CODES
          raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
        else
          raise "OpenAI TTS failed: HTTP #{response.code}: #{response.body.to_s[0, 200]}"
        end
      end
    end
  end
end
