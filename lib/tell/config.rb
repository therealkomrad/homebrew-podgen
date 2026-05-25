# frozen_string_literal: true

require_relative "../yaml_loader"
require_relative "colors"

module Tell
  class Config
    REQUIRED_KEYS = %w[original_language target_language voice_id].freeze
    VALID_TRANSLATION_ENGINES = %w[deepl claude openai].freeze
    VALID_TTS_ENGINES = %w[elevenlabs google openai].freeze
    CONFIG_PATH = File.expand_path("~/.tell.yml")
    DEFAULT_TRANSLATION_TIMEOUT = 8.0

    TRANSLATION_API_KEYS = {
      "deepl"  => { config: "deepl_auth_key",    env: "DEEPL_AUTH_KEY" },
      "claude" => { config: "anthropic_api_key",  env: "ANTHROPIC_API_KEY" },
      "openai" => { config: "openai_api_key",     env: "OPENAI_API_KEY" }
    }.freeze

    # Common language code mistakes (country code → ISO 639-1)
    LANGUAGE_ALIASES = {
      "jp" => "ja",  # Japan country code → Japanese
      "kr" => "ko",  # Korea country code → Korean
      "cn" => "zh",  # China country code → Chinese
      "br" => "pt",  # Brazil country code → Portuguese
      "ua" => "uk",  # Ukraine country code → Ukrainian
      "cz" => "cs",  # Czechia country code → Czech
      "gr" => "el"   # Greece country code → Greek
    }.freeze

    VALID_GLOSS_MODELS = %w[opus sonnet haiku].freeze
    GLOSS_MODEL_IDS = {
      "opus"   => "claude-opus-4-7",
      "sonnet" => "claude-sonnet-4-6",
      "haiku"  => "claude-haiku-4-5-20251001"
    }.freeze
    DEFAULT_GLOSS_MODEL = "opus"

    attr_reader :original_language, :target_language, :voice_id,
                :voice_male, :voice_female,
                :translation_engines, :tts_engine,
                :tts_model_id, :tts_base_url, :output_format,
                :api_key, :tts_api_key, :google_language_code,
                :reverse_translate, :gloss, :gloss_reverse, :phonetic,
                :gloss_model, :phonetic_model, :phonetic_system,
                :engine_api_keys, :translation_timeout

    def initialize(overrides: {}, data: nil)
      @raw_data = data || load_config
      data = @raw_data.dup
      validate!(data)

      @original_language  = normalize_lang(overrides[:from] || data["original_language"])
      @target_language    = normalize_lang(overrides[:to]   || data["target_language"])

      # Merge per-language overrides before reading remaining settings
      apply_language_overrides!(data, overrides)

      @voice_id           = overrides[:voice] || data["voice_id"]
      @voice_male         = data["voice_male"]
      @voice_female       = data["voice_female"]
      @tts_engine         = overrides[:tts_engine] || data.fetch("tts_engine", "elevenlabs")
      @tts_model_id       = data["tts_model_id"] || data.fetch("model_id", "eleven_multilingual_v2")
      @tts_base_url       = data["tts_base_url"] || ENV["TTS_BASE_URL"]
      @output_format      = data.fetch("output_format", "mp3_44100_128")
      @reverse_translate  = overrides[:reverse] || data.fetch("reverse_translate", false)
      @gloss              = overrides[:gloss] || data.fetch("gloss", false)
      @gloss_reverse      = overrides[:gloss_reverse] || data.fetch("gloss_reverse", false)
      @phonetic           = overrides[:phonetic] || data.fetch("phonetic", false)
      @translation_timeout = (ENV["TELL_TRANSLATE_TIMEOUT"] || data.fetch("translation_timeout", DEFAULT_TRANSLATION_TIMEOUT)).to_f

      resolve_gloss_model!(data)
      resolve_phonetic_model!(data)
      resolve_phonetic_system!(data, overrides)

      resolve_translation_engines!(data)
      validate_tts_engine!
      resolve_tts_api_key!(data)
    end

    # Backward compat: primary engine name
    def translation_engine
      @translation_engines.first
    end

    # Backward compat: primary engine's API key
    def engine_api_key
      @engine_api_keys[translation_engine]
    end

    # Convenience: first (strongest) model is the reconciler
    def gloss_reconciler = gloss_model.first
    def phonetic_reconciler = phonetic_model.first

    # Language to use as "to" for reverse translation and glossing.
    # When original_language is "auto" (config-driven translation mode),
    # we don't have a real language code, so default to English.
    def reverse_language
      @original_language == "auto" ? "en" : @original_language
    end

    # Return a Config for a specific target language, with per-language
    # overrides applied. Cached so each language is built once.
    # No file re-read — uses the raw YAML data from initial load.
    def for_language(lang)
      lang = normalize_lang(lang.to_s)
      return self if lang == @target_language

      @lang_configs ||= {}
      @lang_configs[lang] ||= self.class.new(overrides: { to: lang }, data: @raw_data)
    end

    # Resolve phonetic system for a specific language.
    # Returns system key string or nil (= use default for that language).
    def phonetic_system_for(lang)
      case @phonetic_system
      when Hash then @phonetic_system[lang]
      when String then @phonetic_system
      end
    end

    private

    VOICE_KEYS = %w[voice_id voice_male voice_female].freeze

    # Merge language-specific overrides from the `languages:` block into data.
    # e.g. languages: { ja: { tts_engine: elevenlabs, voice_id: "..." } }
    # When CLI overrides tts_engine to a different engine than the language block
    # specifies, skip voice keys — they're paired with the language block's engine.
    def apply_language_overrides!(data, overrides)
      languages = data["languages"]
      return unless languages.is_a?(Hash)

      lang_overrides = languages[@target_language]
      return unless lang_overrides.is_a?(Hash)

      if overrides[:tts_engine] && lang_overrides["tts_engine"] &&
         overrides[:tts_engine] != lang_overrides["tts_engine"]
        lang_overrides = lang_overrides.reject { |k, _| VOICE_KEYS.include?(k) }
      end

      data.merge!(lang_overrides)
    end

    def normalize_lang(code)
      code = code.to_s.downcase
      LANGUAGE_ALIASES.fetch(code, code)
    end

    def load_config
      unless File.exist?(CONFIG_PATH)
        raise <<~MSG
          Config file not found: #{CONFIG_PATH}

          Create ~/.tell.yml with:

            original_language:   en
            target_language:     sl
            voice_id:            "voice_id"
            # voice_male:        "male_voice_id"              # for /m style hint
            # voice_female:      "female_voice_id"            # for /f style hint
            tts_engine:          elevenlabs                    # elevenlabs | google
            tts_model_id:        eleven_multilingual_v2        # ElevenLabs model
            output_format:       mp3_44100_128                 # ElevenLabs format
            translation_engine:  deepl                         # deepl | claude | openai (or [deepl, claude])
            translation_timeout: 8.0                           # per-engine timeout (seconds)
            reverse_translate:   false                         # show reverse translation
            gloss:               false                         # grammatical gloss
            phonetic:            false                         # phonetic reading
            gloss_model:         opus                          # opus | sonnet | haiku (or [opus, sonnet])
            phonetic_model:      opus                          # opus | sonnet | haiku (default: first gloss_model)
            # phonetic_system:   ipa                           # ipa | hepburn | pinyin | ... (or {ja: hepburn, zh: pinyin})

            # Per-language overrides (merged when target language matches):
            # languages:
            #   ja:
            #     tts_engine:    elevenlabs
            #     voice_id:      "japanese_voice_id"
            #   ko:
            #     voice_id:      "korean_voice_id"

          Env: ELEVENLABS_API_KEY, GOOGLE_API_KEY, DEEPL_AUTH_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY
        MSG
      end

      YamlLoader.load(CONFIG_PATH, default: {}, raise_on_error: true)
    end

    def validate!(data)
      missing = REQUIRED_KEYS.select { |k| data[k].nil? || data[k].to_s.empty? }
      return if missing.empty?

      raise "Missing required config keys in #{CONFIG_PATH}: #{missing.join(', ')}"
    end

    def resolve_gloss_model!(data)
      raw = ENV["TELL_GLOSS_MODEL"] || data.fetch("gloss_model", DEFAULT_GLOSS_MODEL)
      @gloss_model = Array(raw).map { |m| GLOSS_MODEL_IDS.fetch(m.to_s, m.to_s) }
    end

    def resolve_phonetic_model!(data)
      raw = ENV["TELL_PHONETIC_MODEL"] || data.fetch("phonetic_model", nil)
      if raw
        @phonetic_model = Array(raw).map { |m| GLOSS_MODEL_IDS.fetch(m.to_s, m.to_s) }
      else
        # Default: first gloss model only (single-element array)
        @phonetic_model = [@gloss_model.first]
      end
    end

    def resolve_phonetic_system!(data, overrides)
      @phonetic_system = overrides[:phonetic_system] || ENV["TELL_PHONETIC_SYSTEM"] || data["phonetic_system"]
    end

    def resolve_translation_engines!(data)
      raw = data.fetch("translation_engine", "deepl")
      @translation_engines = Array(raw).map(&:to_s)

      @translation_engines.each do |eng|
        unless VALID_TRANSLATION_ENGINES.include?(eng)
          raise "Invalid translation_engine '#{eng}'. Must be one of: #{VALID_TRANSLATION_ENGINES.join(', ')}"
        end
      end

      @engine_api_keys = {}
      @translation_engines.each_with_index do |eng, i|
        key_info = TRANSLATION_API_KEYS[eng]
        key = data[key_info[:config]] || ENV[key_info[:env]]

        if key
          @engine_api_keys[eng] = key
        elsif i == 0
          raise "#{eng} translation requires #{key_info[:env]} (set in env or as '#{key_info[:config]}' in #{CONFIG_PATH})"
        else
          $stderr.puts Colors.warning("warn: #{eng} fallback skipped — #{key_info[:env]} not set")
        end
      end

      # Remove engines without keys (except primary, which already raised)
      @translation_engines.select! { |eng| @engine_api_keys.key?(eng) }
    end

    def validate_tts_engine!
      return if VALID_TTS_ENGINES.include?(@tts_engine)

      raise "Invalid tts_engine '#{@tts_engine}'. Must be one of: #{VALID_TTS_ENGINES.join(', ')}"
    end

    def resolve_tts_api_key!(data)
      case @tts_engine
      when "elevenlabs"
        @api_key = data["elevenlabs_api_key"] || ENV["ELEVENLABS_API_KEY"]
        raise "ElevenLabs requires ELEVENLABS_API_KEY" unless @api_key
      when "google"
        @api_key = nil
        @tts_api_key = data["google_api_key"] || ENV["GOOGLE_API_KEY"]
        raise "Google TTS requires GOOGLE_API_KEY (set in env or as 'google_api_key' in #{CONFIG_PATH})" unless @tts_api_key
        @google_language_code = data["google_language_code"] || derive_google_language_code
        adapt_google_voice!
      when "openai"
        # API key is optional when using a local server (openedai-speech etc.)
        @tts_api_key = data["openai_api_key"] || ENV.fetch("OPENAI_API_KEY", "local")
        @api_key     = nil
      end
    end

    def derive_google_language_code
      require_relative "tts"
      GoogleTts::LANGUAGE_CODES.fetch(@target_language) do
        raise "No Google language code mapping for '#{@target_language}'. Set 'google_language_code' explicitly in #{CONFIG_PATH}"
      end
    end

    # When -t overrides the target language, swap the voice's language prefix
    # to match. E.g. "sl-SI-Chirp3-HD-Kore" + lang "ja-JP" → "ja-JP-Chirp3-HD-Kore"
    def adapt_google_voice!
      [@voice_id, @voice_male, @voice_female].each_with_index do |voice, i|
        next unless voice
        next if voice.start_with?(@google_language_code)

        parts = voice.split("-", 3) # ["sl", "SI", "Chirp3-HD-Kore"]
        next unless parts.length == 3

        adapted = "#{@google_language_code}-#{parts[2]}"
        case i
        when 0 then @voice_id = adapted
        when 1 then @voice_male = adapted
        when 2 then @voice_female = adapted
        end
      end
    end
  end
end
