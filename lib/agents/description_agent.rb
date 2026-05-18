# frozen_string_literal: true

require_relative "../anthropic_client"
require_relative "../loggable"
require_relative "../usage_logger"

class DescriptionAgent
  include AnthropicClient
  include Loggable
  include UsageLogger
  MAX_RETRIES = 3
  TRANSCRIPT_LIMIT = 2000

  def initialize(logger: nil)
    @logger = logger
    init_anthropic_client(env_key: "CLAUDE_DESCRIPTION_MODEL", default_model: "claude-sonnet-4-6")
  end

  # Cleans a YouTube/RSS episode title by stripping category prefixes, labels, and noise.
  # e.g. "PRAVLJICA ZA OTROKE: Lačni medved" → "Lačni medved"
  # Returns cleaned title, or original on failure.
  def clean_title(title:)
    return title if title.to_s.strip.empty?

    title = normalize_screaming_title(title)
    log("Cleaning title: \"#{title}\"")

    message, elapsed = measure_time do
      @client.messages.create(
        model: @model,
        max_tokens: 256,
        system: clean_title_system_prompt,
        messages: [
          { role: "user", content: title }
        ]
      )
    end

    result = message.content.first.text.strip
    log_api_usage("Description clean_title", message, elapsed)

    if result.empty?
      log("Cleaned title was empty, keeping original")
      return title
    end

    # Re-run screaming-caps normalization on the LLM output: stripping a
    # mixed-case suffix from a screaming prefix flips a sub-threshold input
    # into an over-threshold output, which the input-side normalization
    # already missed.
    result = normalize_screaming_title(result)

    if result != title
      log("Title cleaned: \"#{title}\" → \"#{result}\"")
    else
      log("Title already clean")
    end
    result
  rescue => e
    log("Warning: Title cleanup failed: #{e.message} (non-fatal, keeping original)")
    title
  end

  # Cleans a YouTube/RSS episode description by extracting only story-relevant content.
  # Drops links, credits, promos, hashtags, emoji headers, parent notes, etc.
  # Returns cleaned description string, or original on failure.
  def clean(title:, description:)
    return description if description.to_s.strip.empty?

    log("Cleaning description for \"#{title}\" (#{description.length} chars)")

    message, elapsed = measure_time do
      @client.messages.create(
        model: @model,
        max_tokens: 1024,
        system: clean_system_prompt,
        messages: [
          {
            role: "user",
            content: "Title: #{title}\n\nDescription:\n#{description}"
          }
        ]
      )
    end

    result = message.content.first.text.strip
    log_api_usage("Description clean", message, elapsed)

    if result.empty?
      log("Cleaned description was empty, keeping original")
      return description
    end

    log("Description cleaned: #{description.length} → #{result.length} chars")
    result
  rescue => e
    log("Warning: Description cleanup failed: #{e.message} (non-fatal, keeping original)")
    description
  end

  # Generates a story title from the transcript content.
  # Returns generated title string, or nil on failure.
  def generate_title(transcript:, language:)
    return nil if transcript.to_s.strip.empty?

    truncated = transcript[0, TRANSCRIPT_LIMIT]
    log("Generating title from transcript (#{language}, #{truncated.length} chars)")

    message, elapsed = measure_time do
      @client.messages.create(
        model: @model,
        max_tokens: 256,
        system: generate_title_system_prompt(language),
        messages: [
          { role: "user", content: truncated }
        ]
      )
    end

    result = message.content.first.text.strip
    log_api_usage("Description generate_title", message, elapsed)

    if result.empty?
      log("Generated title was empty")
      return nil
    end

    log("Title generated: \"#{result}\"")
    result
  rescue => e
    log("Warning: Title generation failed: #{e.message} (non-fatal)")
    nil
  end

  # Generates a short description from the transcript for local file episodes.
  # Returns generated description string, or empty string on failure.
  def generate(title:, transcript:)
    return "" if transcript.to_s.strip.empty?

    truncated = transcript[0, TRANSCRIPT_LIMIT]
    log("Generating description for \"#{title}\" from transcript (#{truncated.length} chars)")

    message, elapsed = measure_time do
      @client.messages.create(
        model: @model,
        max_tokens: 512,
        system: generate_system_prompt,
        messages: [
          {
            role: "user",
            content: "Title: #{title}\n\nTranscript:\n#{truncated}"
          }
        ]
      )
    end

    result = message.content.first.text.strip
    log_api_usage("Description generate", message, elapsed)

    log("Description generated: #{result.length} chars")
    result
  rescue => e
    log("Warning: Description generation failed: #{e.message} (non-fatal)")
    ""
  end

  private

  # YouTube/RSS source titles are often screamed in all caps. Detect and downcase
  # to sentence case so the LLM (which is told to preserve capitalization) can't
  # echo the screaming back. Triggers only on long, mostly-uppercase strings.
  # Proper nouns past the first word will be lowercased — acceptable trade-off
  # versus an extra LLM call for smart casing.
  def normalize_screaming_title(title)
    return title if title.length < 5

    letters = title.scan(/\p{L}/)
    return title if letters.empty?

    upper_count = letters.count { |c| c == c.upcase && c != c.downcase }
    return title if (upper_count.to_f / letters.length) < 0.7

    downcased = title.downcase
    # Capitalize first letter (Unicode-safe via single-char upcase).
    downcased.sub(/\p{L}/) { |c| c.upcase }
  end

  def clean_title_system_prompt
    <<~PROMPT
      You receive ONE title and output ONE title. You never ask questions.
      You never explain. You never apologize. You never echo examples back.

      Your job: return the proper name of a story/episode/work, with
      surrounding labels stripped.

      Strip:
      - Category/genre prefixes (e.g. "PRAVLJICA ZA OTROKE:", "FAIRY TALE:", "KIDS STORY:")
      - Subtitles/taglines after colon or dash (e.g. "Title: gentle bedtime story" → "Title")
      - Content descriptions (e.g. "mirna Grimmova pravljica za lahko noč")
      - Series labels (e.g. "S1E3 -", "Episode 12:")
      - Channel names, emoji, audience labels, mood/tone descriptors
      - Redundant quotes or brackets around the title

      Examples (input → output):
      - "Trnuljčica: mirna Grimmova pravljica za lahko noč" → "Trnuljčica"
      - "PRAVLJICA ZA OTROKE: Lačni medved" → "Lačni medved"
      - "The Three Bears - A Bedtime Story for Kids" → "The Three Bears"
      - "Sleeping Beauty" → "Sleeping Beauty"
      - "Kaj delam narobe" → "Kaj delam narobe"

      Rules:
      - The entire input IS a title. Even if it reads like a question or a
        plain sentence, treat it as a title and process accordingly.
      - Preserve language, capitalization, and punctuation of the core name.
      - If the input is already clean, output it unchanged.
      - Output ONLY the cleaned title text, on a single line, with no
        commentary, no quotes around the result, no preamble.
    PROMPT
  end

  def clean_system_prompt
    <<~PROMPT
      Extract ONLY the story synopsis or content summary from this episode description. Return just the plot or topic — nothing else.

      Remove ALL of the following:
      - Links and URLs
      - Emoji-prefixed lines
      - Credits, attributions, music credits
      - Target audience mentions (e.g. "for children aged 3-7", "ideal for bedtime")
      - Usage suggestions (e.g. "perfect for evening ritual", "great for learning")
      - Tone/style descriptions (e.g. "gentle pace", "soft voice", "calming")
      - Parent/teacher/listener notes
      - Hashtags
      - Playlist or channel promotions
      - Subscription calls to action
      - Timestamps or chapter markers
      - Social media handles
      - Copyright notices

      Return ONLY the plot summary or content description — 1-3 sentences max.
      If there is no relevant content description, return the title as-is.
      Do not add any commentary, labels, or explanation. Output the cleaned text directly.
    PROMPT
  end

  def generate_title_system_prompt(language)
    <<~PROMPT
      Generate a concise title for this #{language} story/episode based on the transcript.
      The title should be in #{language} — like a book title on a library shelf.
      Focus on the main character, event, or theme of the story.
      Output only the title, nothing else. No quotes, no labels, no explanation.
    PROMPT
  end

  def generate_system_prompt
    <<~PROMPT
      Generate a brief 1-2 sentence description of this episode based on the transcript.
      Focus on what the episode is about — the story, topic, or main content.
      Write in the same language as the transcript.
      Do not add any commentary, labels, or explanation. Output the description directly.
    PROMPT
  end

end
