# frozen_string_literal: true

require_relative "agents/tts_agent"
require_relative "audio_assembler"
require_relative "loggable"

# Encapsulates the "voice a script" stage: TTS for each segment, audio
# assembly with intro/outro, and cleanup of intermediate audio files.
#
# Pulled out of GenerateCommand and TranslateCommand so a failed voicing
# can be retried in isolation via `podgen voice <pod> --lang LANG` without
# re-running script generation or translation.
class Voicer
  include Loggable

  DEFAULT_SEGMENT_PAUSE = 2.0

  def initialize(logger: nil)
    @logger = logger
  end

  # Synthesize and assemble a single language MP3.
  # segments: [{ name:, text: }, ...] — output by ScriptAgent / TranslationAgent
  # Returns the output_path on success; raises on failure.
  def voice(segments:, output_path:, voice_id:, title:, author:,
            tts_model_id: nil, pronunciation_pls_path: nil,
            intro_path: nil, outro_path: nil,
            segment_pause: DEFAULT_SEGMENT_PAUSE,
            lang_code: nil)
    label = lang_code ? " (#{lang_code})" : ""

    phase_start("TTS#{label}")
    tts_agent = TTSAgent.new(
      logger: @logger,
      voice_id_override: voice_id,
      model_id_override: tts_model_id,
      pronunciation_pls_path: pronunciation_pls_path
    )
    audio_paths = tts_agent.synthesize(segments)
    log("TTS complete#{label}: #{audio_paths.length} audio files")
    phase_end("TTS#{label}")

    phase_start("Assembly#{label}")
    assembler = AudioAssembler.new(logger: @logger)
    assembler.assemble(audio_paths, output_path,
                       intro_path: intro_path, outro_path: outro_path,
                       metadata: { title: title, artist: author },
                       segment_pause: segment_pause)
    phase_end("Assembly#{label}")

    audio_paths.each { |p| File.delete(p) if File.exist?(p) }
    output_path
  end

end
