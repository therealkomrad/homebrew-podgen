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
    init_anthropic_client
    @guidelines = guidelines
    @script_path = script_path
    @priority_urls = Array(priority_urls)
    @links_config = links_config || {}
  end

  # Input: array of { topic:, findings: [{ title:, url:, summary: }] }
  # Output: { title:, segments: [{ name:, text: }] }
  def generate(research_data)
    validate_research_data(research_data)
    log("Generating script with #{@model}")
    research_text = format_research(research_data)

    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError, StructuredOutputError, RuntimeError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 8192,
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
          seg[:sources] = s.sources.map { |src| { title: src.title, url: src.url } } if s.sources&.any?
          seg
        },
        sources: script.sources.map { |s| { title: s.title, url: s.url } }
      }

      save_script_debug(result)
      result
    end
  end

  private

  def build_system_prompt
    today = Date.today.strftime("%Y-%m-%d (%A)")
    base_prompt = <<~PROMPT
      You are an expert podcast scriptwriter.
      Generate a complete podcast script following the provided guidelines exactly.

      Each segment must have a short descriptive name that reflects its content
      (e.g. "Opening", "Bitcoin ETF Surge", "Rails 8 Authentication", "Wrap-Up").
      These names are internal labels, not read aloud — they serve as section titles.
      Do NOT use generic names like "intro", "segment_1", or "outro".

      Write naturally as spoken word — no stage directions, no timestamps, no markdown.
      Each segment's text should be the exact words the host will speak aloud.
      Do not invent a host name, persona, or sign-off identity. There is no named host.
      Use numeric digits for numbers, prices, percentages, and quantities ($67,500, 10 GW,
      22%, 1,031 BTC). TTS handles digits correctly — do NOT spell them out as words.

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
        {
          name: s.name,
          text: s.text,
          sources_field_present: !s.sources.nil?,
          sources: s.sources&.map { |src| { title: src.title, url: src.url } }
        }
      end,
      top_level_sources: script.sources.map { |s| { title: s.title, url: s.url } }
    }
  end

  def save_script_debug(script)
    FileUtils.mkdir_p(File.dirname(@script_path))
    File.write(@script_path, ScriptRenderer.render(script))
    ScriptArtifact.write(ScriptArtifact.json_path_for(@script_path), script)
    log("Script saved to #{@script_path}")
  end

end
