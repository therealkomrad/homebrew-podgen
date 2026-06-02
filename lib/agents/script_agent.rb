# frozen_string_literal: true

require "fileutils"
require "date"
require "json"
require_relative "../anthropic_client"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../usage_logger"
require_relative "../script_artifact"
require_relative "../script_renderer"

class Source < Anthropic::BaseModel
  required :title, String
  required :url, String
end

class Segment < Anthropic::BaseModel
  required :name, String
  required :text, String
  optional :sources, Anthropic::ArrayOf[Source]
end

class PodcastScript < Anthropic::BaseModel
  required :title, String
  required :segments, Anthropic::ArrayOf[Segment]
  required :sources, Anthropic::ArrayOf[Source]
end

class ScriptAgent
  include AnthropicClient
  include Loggable
  include Retryable
  include UsageLogger

  MAX_RETRIES = 3

  def initialize(guidelines:, script_path:, logger: nil, priority_urls: [], links_config: nil)
    @logger = logger
    init_anthropic_client(ollama_model_env: "OLLAMA_SCRIPT_MODEL")
    @guidelines = guidelines
    @script_path = script_path
    @priority_urls = Array(priority_urls)
    @links_config = links_config || {}
  end

  # Input: array of { topic:, findings: [{ title:, url:, summary: }] }
  # Output: { title:, segments: [{ name:, text: }] }
  def generate(research_data)
    validate_research_data(research_data)

    # Per-segment generation: write each segment (plus opening/closing) in its own focused
    # LLM call. Local models produce far more depth and length this way than emitting a whole
    # 10-minute script in one shot. Opt in via PODGEN_SEGMENT_BY_SEGMENT=true.
    if ENV["PODGEN_SEGMENT_BY_SEGMENT"] == "true"
      return generate_by_segment(research_data)
    end

    if %w[ollama openai].include?(ENV["LLM_ENGINE"])
      max_total = ENV.fetch("OLLAMA_MAX_FINDINGS", "150").to_i
      per_topic = [max_total / research_data.size, 1].max
      research_data = research_data.map { |item| item.merge(findings: item[:findings].first(per_topic)) }
      log("Capped findings: #{per_topic}/topic (#{research_data.sum { |i| i[:findings].size }} total)")
    end

    log("Generating script with #{@model} (#{research_data.sum { |i| i[:findings].size }} total findings)")
    research_text = format_research(research_data)

    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError, StructuredOutputError, RuntimeError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 24576,
          system: build_system_prompt,
          messages: [
            {
              role: "user",
              content: "Write a podcast script based on this research:\n\n#{research_text}"
            }
          ],
          output_config: { format: PodcastScript }
        )
      end

      log_api_usage("Script generated", message, elapsed)

      script = require_parsed_output!(message, PodcastScript)

      save_raw_debug(script, message)

      result = {
        title: script.title,
        segments: script.segments.map { |s|
          seg = { name: s.name, text: s.text }
          srcs = sources_of(s)
          seg[:sources] = srcs if srcs.any?
          seg
        },
        sources: sources_of(script)
      }

      save_script_debug(result)
      result
    end
  end

  private

  # ── Per-segment generation ────────────────────────────────────────────────
  # Writes each topic as its own deep segment, then a dedicated opening and closing.

  def generate_by_segment(research_data)
    per_topic = [(ENV["OLLAMA_SEGMENT_FINDINGS"] || "20").to_i, 1].max
    research_data = research_data.map { |item| item.merge(findings: item[:findings].first(per_topic)) }
    log("Per-segment mode: #{research_data.size} topics, up to #{per_topic} findings/topic, model #{@model}")

    topic_segments = research_data.each_with_index.map do |item, i|
      seg, elapsed = measure_time { generate_topic_segment(item) }
      log("  Segment #{i + 1}/#{research_data.size} \"#{seg[:name]}\" — #{seg[:text].split.size} words, #{seg[:sources].size} sources (#{elapsed.round(1)}s)")
      seg
    end

    title, opening = generate_opening(topic_segments)
    closing = generate_closing(topic_segments)

    segments = [opening, *topic_segments, closing].compact
    aggregated = dedupe_sources(topic_segments.flat_map { |s| s[:sources] })

    result = {
      title: title,
      segments: segments,
      sources: aggregated
    }

    total_words = segments.sum { |s| s[:text].split.size }
    log("Per-segment script assembled: #{segments.size} segments, ~#{total_words} words")
    save_script_debug(result)
    result
  end

  # Segment prose is generated FREE-FORM (no JSON schema). Grammar-constrained decoding makes
  # local models terse — it lets them end the text string early (qwen2.5:7b: 53 words with a
  # schema vs 307 free-form for the same prompt). We parse a leading "TITLE:" line for the
  # segment name and attach the topic's findings as the segment's sources.
  def generate_topic_segment(item)
    research_text = item[:findings].map do |f|
      "- #{f[:title] || 'Untitled'} (#{f[:url] || 'no URL'})\n  #{f[:summary] || 'No summary available'}"
    end.join("\n")

    raw = generate_freeform(
      system: segment_system_prompt,
      user: "Topic area: #{item[:topic]}\n\nResearch findings:\n\n#{research_text}\n\nWrite the segment now. Aim for 300 words.",
      max_tokens: 1200
    )
    name, text = parse_titled(raw, fallback_name: item[:topic].to_s.split.first(6).join(" "))
    { name: name, text: text, sources: findings_to_sources(item[:findings]) }
  end

  # Returns [title, opening_segment]
  def generate_opening(topic_segments)
    digest = topic_segments.map { |s| "## #{s[:name]}\n#{s[:text][0, 400]}" }.join("\n\n")
    raw = generate_freeform(
      system: opening_system_prompt,
      user: "The episode's segments:\n\n#{digest}\n\nWrite the title line then the cold open.",
      max_tokens: 700
    )
    title, text = parse_titled(raw, fallback_name: "Think Principia Daily — #{Date.today.strftime('%B %-d, %Y')}")
    [title, { name: "Opening Rundown", text: text, sources: [] }]
  end

  def generate_closing(topic_segments)
    digest = topic_segments.map { |s| "## #{s[:name]}\n#{s[:text][0, 300]}" }.join("\n\n")
    raw = generate_freeform(
      system: closing_system_prompt,
      user: "The episode's segments:\n\n#{digest}\n\nWrite the closing thought.",
      max_tokens: 500
    )
    _name, text = parse_titled(raw, fallback_name: "Closing Thought")
    { name: "Closing Thought", text: text, sources: [] }
  rescue => e
    log("Closing generation failed (#{e.message}); skipping closing segment")
    nil
  end

  # Free-form (no schema) generation. Returns the raw text the model produced.
  def generate_freeform(system:, user:, max_tokens:)
    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError, StructuredOutputError, RuntimeError]) do
      message = @client.messages.create(
        model: @model,
        max_tokens: max_tokens,
        system: system,
        messages: [{ role: "user", content: user }]
      )
      text = message.respond_to?(:text) ? message.text.to_s : message.content.map { |b| b.text }.join
      text = text.strip
      raise StructuredOutputError, "Empty free-form response" if text.empty?
      text
    end
  end

  # Splits a leading "TITLE: ..." (or "NAME:"/"# ...") line off the body. Returns [name, body].
  def parse_titled(raw, fallback_name:)
    lines = raw.to_s.strip.lines
    first = lines.first.to_s.strip
    if first =~ /\A(?:title|name)\s*[:\-]\s*(.+)\z/i
      name = Regexp.last_match(1).strip.gsub(/\A["']|["']\z/, "")
      body = lines[1..].join.strip
      body = body.sub(/\A#+\s*/, "")
      return [name.empty? ? fallback_name : name, body.empty? ? raw.to_s.strip : body]
    elsif first =~ /\A#+\s*(.+)\z/
      return [Regexp.last_match(1).strip, lines[1..].join.strip]
    end
    [fallback_name, raw.to_s.strip]
  end

  # Use the topic's top findings (titles + URLs) as the segment's source list.
  def findings_to_sources(findings)
    max = (@links_config[:max] || 5).to_i
    findings
      .reject { |f| f[:url].to_s.empty? || f[:title].to_s.empty? }
      .first(max)
      .map { |f| { title: f[:title].to_s, url: f[:url].to_s } }
  end

  def dedupe_sources(sources)
    seen = {}
    sources.each { |s| seen[s[:url]] ||= s }
    seen.values
  end

  def segment_system_prompt
    today = Date.today.strftime("%Y-%m-%d (%A)")
    base = <<~PROMPT
      You are an expert podcast scriptwriter writing ONE segment of a daily research briefing.
      Today is #{today}.

      Write a single, deep, analytical segment of about 300 words (at least 280) about the MOST
      important development in this topic area. Do NOT list every finding. Pick the one or two
      biggest stories and develop them in depth: lead with the specific numbers (prices,
      percentages, dollar amounts, dates, model sizes, benchmark scores), then the analysis —
      what it means, the second-order effect, who wins or loses, the catch or tension — then a
      short "what to watch" (a date, a threshold, or an open question). Go deep, not wide.

      GROUND EVERY CLAIM IN THE FINDINGS: use only facts, numbers, names, dates, and quotes
      that are explicitly present in the research. Do NOT infer, calculate, estimate, or invent
      details that aren't stated (e.g. don't derive an age from a year, don't add a date that
      isn't given). Attribute every claim, quote, and result exactly as the findings do — name
      every party the findings credit, and don't imply causation or contrast the findings don't state.

      Write as spoken word: the exact words the host will say. No stage directions, no markdown,
      no bullet points, no host name, no sign-off. Use numeric digits for numbers (88%, 10x,
      1.4 billion parameters). Short declarative sentences mixed with longer analytical ones. Confident,
      slightly opinionated point of view — use reframing ("The interesting part isn't X, it's Y").

      FORMAT: First output one line "TITLE: <a short, specific headline naming the lead story>"
      (e.g. "TITLE: Grok V9 Coding Push"). Then a blank line, then the segment prose. Do not write
      anything else after the prose.
    PROMPT
    [
      { type: "text", text: base },
      { type: "text", text: @guidelines, cache_control: { type: "ephemeral" } }
    ]
  end

  def opening_system_prompt
    today = Date.today.strftime("%Y-%m-%d (%A)")
    [
      { type: "text", text: <<~PROMPT }
        You are writing the COLD OPEN of a daily research briefing podcast. Today is #{today}.

        In 5-7 punchy sentences, rattle off the single biggest concrete development from EACH
        segment listed by the user — always name the model, method, dataset, paper, company, or
        asset and the hard number (e.g. "A new open model tops the reasoning benchmark at 88%,
        but the real story is the 10x drop in inference cost"). For the opening line, follow the
        guidelines: use a given line verbatim only if they specify an exact one, otherwise vary the
        opener naturally each day in the show's voice (if the guidelines say nothing, a short "here's
        what's worth knowing" rundown line). End with a short call to action like "Let's get into it."
        Spoken word
        only, numeric digits, no markdown.

        FORMAT: First output one line "TITLE: <a specific, headline-style episode title naming the
        day's biggest theme>". Then a blank line, then the cold open prose. Nothing after it.
      PROMPT
    ]
  end

  def closing_system_prompt
    [
      { type: "text", text: <<~PROMPT }
        You are writing the CLOSING THOUGHT of a daily research briefing podcast.

        Write 3-5 sentences: one sharp, specific prediction or provocation to sit with — NOT a
        summary of what was covered. Tie it to a concrete number or dynamic from the segments.
        No "stay tuned", no "in conclusion", no recap. Spoken word, numeric digits, no markdown.
        Output only the closing prose (no title line).
      PROMPT
    ]
  end

  def build_system_prompt
    today = Date.today.strftime("%Y-%m-%d (%A)")
    base_prompt = <<~PROMPT
      You are an expert podcast scriptwriter.
      Generate a complete podcast script following the provided guidelines exactly.

      Give the episode a short, snappy `title` — a punchy headline of 3 to 6 words, at most
      about 45 characters, that captures the day's single biggest theme (e.g. "Sparse Models
      Win" or "The Great Model Squeeze"). NOT the generic show name, and NOT a list of stories.

      Each segment must have a short descriptive name that reflects its content
      (e.g. "Opening", "Sparse Attention Gains", "Causal Inference at Scale", "Wrap-Up").
      These names are internal labels, not read aloud — they serve as section titles.
      Do NOT use generic names like "intro", "segment_1", or "outro".

      Write naturally as spoken word — no stage directions, no timestamps, no markdown.
      Each segment's text should be the exact words the host will speak aloud.
      Do not invent a host name, persona, or sign-off identity. There is no named host.
      Use numeric digits for numbers, percentages, and quantities (88%, 10x, 1.4 billion
      parameters, 3.2 seconds). TTS handles digits correctly — do NOT spell them out as words.

      STRUCTURE: Open with a short "rundown" cold-open segment (follow the guidelines for the opening
      line — verbatim if they give an exact one, otherwise a varied opener in the show's voice —
      name each story's single biggest number, then a short call to action like
      "Let's get into it."), then ONE deep ~300-word analytical
      segment per topic area (lead with the specific numbers, then the analysis — what it means,
      who wins or loses, the catch — then a short "what to watch"), then a brief closing-thought
      segment with one sharp, specific prediction (no recap, no "stay tuned"). TOTAL spoken text
      scales with the number of topic segments — roughly 1,900-2,200 words for a five-segment
      episode (about 300 words per topic segment plus the open and close). Do not exceed 2,400 words.

      GROUND EVERY CLAIM IN THE RESEARCH: use only facts, numbers, names, dates, and quotes
      explicitly present in the findings. Do NOT infer, calculate, estimate, or invent details
      that aren't stated (e.g. don't derive an age from a year). Attribute every claim, quote, and
      result exactly as the findings do — credit every party the findings name.
      Mention ONLY the companies, products, models, people, and figures that actually appear in
      the research findings. Do NOT add any entity, product name, or statistic from your own prior
      knowledge — even if you believe it is real. If the findings don't name it, it does not exist
      for this script. Match the findings' exact wording on status (e.g. "in preview" vs "launched").

      In the sources field, list every article or source you actually referenced in the
      script. Each source needs a short descriptive title (5-8 words max, like a headline)
      and the original URL from the research data. Only include sources whose content
      materially contributed to the script.

      For reference: today's date is #{today}.
    PROMPT

    unless @priority_urls.empty?
      base_prompt += <<~PRIORITY

        PRIORITY LINKS: The research includes links under the "Priority links" topic
        that the producer specifically selected. You MUST cover every priority link
        in the script — do not skip any of them. Weave them naturally into the episode
        alongside the other research findings.
      PRIORITY
    end

    if @links_config[:position] == "inline"
      base_prompt += <<~INLINE

        SOURCE ATTRIBUTION: For each segment, include a `sources` array listing the
        specific articles you referenced in THAT segment. Each source needs a title and
        URL from the research data. Only include sources whose content materially
        contributed to that specific segment. Segments without source references (like
        Opening or Wrap-Up) should omit the sources field.
      INLINE
    end

    max = @links_config[:max]
    if max
      scope = @links_config[:position] == "inline" ? "per segment" : "total"
      base_prompt += <<~MAX

        SOURCE LIMIT: Include at most #{max} source links #{scope}. Choose the most
        relevant and diverse sources. Drop near-duplicate links that cover the same
        story from similar angles.
      MAX
    end

    [
      { type: "text", text: base_prompt },
      {
        type: "text",
        text: @guidelines,
        cache_control: { type: "ephemeral" }
      }
    ]
  end

  def validate_research_data(data)
    raise ArgumentError, "Research data must be an Array, got #{data.class}" unless data.is_a?(Array)
    raise ArgumentError, "Research data is empty — nothing to script" if data.empty?

    data.each_with_index do |item, i|
      raise ArgumentError, "Research item [#{i}] must be a Hash, got #{item.class}" unless item.is_a?(Hash)
      raise ArgumentError, "Research item [#{i}] missing :topic key" unless item.key?(:topic)
      raise ArgumentError, "Research item [#{i}] :topic must be a String" unless item[:topic].is_a?(String)
      raise ArgumentError, "Research item [#{i}] missing :findings key" unless item.key?(:findings)
      raise ArgumentError, "Research item [#{i}] :findings must be an Array" unless item[:findings].is_a?(Array)

      item[:findings].each_with_index do |f, j|
        raise ArgumentError, "Finding [#{i}][#{j}] must be a Hash, got #{f.class}" unless f.is_a?(Hash)
        %i[title url summary].each do |key|
          raise ArgumentError, "Finding [#{i}][#{j}] missing :#{key} key" unless f.key?(key)
        end
      end
    end
  end

  def format_research(research_data)
    research_data.map do |item|
      findings = item[:findings].map do |f|
        "  - #{f[:title] || 'Untitled'} (#{f[:url] || 'no URL'})\n    #{f[:summary] || 'No summary available'}"
      end.join("\n")
      "## #{item[:topic] || 'Unknown topic'}\n#{findings}"
    end.join("\n\n")
  end

  # Dumps the parsed PodcastScript to <pod>/debug/<basename>_script_raw.json,
  # preserving the nil-vs-empty distinction for per-segment sources so we can
  # tell after-the-fact whether the model omitted the field or returned [].
  # Skipped when @script_path doesn't follow the conventional <pod>/episodes/
  # <basename>_script.md layout — the dirname-stepping derivation only makes
  # sense for that shape, and unit tests passing flat tmpdir paths shouldn't
  # leak files above their sandbox.
  #
  # TODO(2026-06-15): always-on diagnostic instrumentation added to investigate
  # the fulgur_news 2026-05-07 missing-per-segment-sources incident. If the
  # issue hasn't recurred by this date, drop this method or gate it on
  # ENV["PODGEN_DEBUG_RAW_SCRIPT"].
  def save_raw_debug(script, message)
    return unless @script_path.end_with?("_script.md")

    debug_dir = File.join(File.dirname(File.dirname(@script_path)), "debug")
    FileUtils.mkdir_p(debug_dir)
    basename = File.basename(@script_path, "_script.md")
    path = File.join(debug_dir, "#{basename}_script_raw.json")
    File.write(path, JSON.pretty_generate(serialize_raw(script, message)))
    log("Raw debug artifact saved to #{path}")
  rescue => e
    log("Warning: failed to save raw debug artifact: #{e.message}")
  end

  def serialize_raw(script, message)
    {
      stop_reason: message.stop_reason,
      title: script.title,
      segments: script.segments.map do |s|
        present = s.respond_to?(:sources) && !s.sources.nil?
        {
          name: s.name,
          text: s.text,
          sources_field_present: present,
          sources: present ? sources_of(s) : nil
        }
      end,
      top_level_sources: sources_of(script)
    }
  end

  # Safely read a {title,url} source list from a parsed segment/script, whether the
  # `sources` field is present, nil, or (for the JSON wrapper) absent entirely.
  def sources_of(obj)
    return [] unless obj.respond_to?(:sources)
    Array(obj.sources).map { |src| { title: src.title, url: src.url } }
  end

  def save_script_debug(script)
    FileUtils.mkdir_p(File.dirname(@script_path))
    File.write(@script_path, ScriptRenderer.render(script))
    ScriptArtifact.write(ScriptArtifact.json_path_for(@script_path), script)
    log("Script saved to #{@script_path}")
  end

end
