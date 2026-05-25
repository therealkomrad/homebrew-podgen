# frozen_string_literal: true

require "httparty"
require "json"

# Interface-compatible replacement for Anthropic::Client backed by any
# Ollama-compatible API (Ollama, LM Studio, etc.).
# Activated when LLM_ENGINE=ollama is set in the environment.
#
# OllamaClientWrapper.new(base_url:, api_key:)
#   .messages
#   .create(model:, max_tokens:, system:, messages:, output_config: nil)
#     → OllamaMessageResponse
class OllamaClientWrapper
  def initialize(base_url:, api_key: "local")
    @messages = OllamaMessagesInterface.new(base_url: base_url, api_key: api_key)
  end

  def messages
    @messages
  end
end

class OllamaMessagesInterface
  # Appended to the system prompt when output_config requests structured output.
  # Keyed by class name string to avoid circular dependencies with agent files.
  JSON_SCHEMA_HINTS = {
    "PodcastScript" => <<~HINT,
      IMPORTANT: Respond with ONLY a valid JSON object — no markdown code blocks, no explanation, nothing outside the JSON.
      Required structure:
      {"title":"episode title","segments":[{"name":"segment name","text":"spoken text","sources":[{"title":"source title","url":"https://..."}]}],"sources":[{"title":"source title","url":"https://..."}]}
      The "sources" array inside each segment is optional — include it only when that segment directly references specific articles.
    HINT
    "TopicList" => <<~HINT,
      IMPORTANT: Respond with ONLY a valid JSON object — no markdown, no explanation.
      Required structure: {"queries":[{"query":"search query 1"},{"query":"search query 2"},{"query":"search query 3"},{"query":"search query 4"}]}
    HINT
    "ScriptReview" => <<~HINT
      IMPORTANT: Respond with ONLY a valid JSON object — no markdown, no explanation.
      Required structure: {"issues":[{"severity":"BLOCKER","check":"check name","segment":"segment name","message":"description"}],"overall_assessment":"summary"}
      severity must be one of: BLOCKER, WARNING, NIT. If there are no issues, return {"issues":[],"overall_assessment":"Script looks good."}.
    HINT
  }.freeze

  def initialize(base_url:, api_key:)
    @base_url = base_url.chomp("/")
    @api_key  = api_key
  end

  # Mirrors Anthropic::Client#messages.create — agents call this directly.
  # The output_config parameter is intercepted and converted to a JSON schema hint.
  def create(model:, max_tokens:, system: nil, messages: [], output_config: nil, **_ignored)
    system_text = normalize_system(system)
    system_text = append_schema_hint(system_text, output_config)

    openai_messages = build_messages(system_text, messages)

    body = {
      model:      model,
      messages:   openai_messages,
      max_tokens: max_tokens,
      stream:     false
    }
    body[:response_format] = { type: "json_object" } if output_config

    response = HTTParty.post(
      "#{@base_url}/chat/completions",
      headers: {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type"  => "application/json"
      },
      body:    body.to_json,
      timeout: 600
    )

    unless response.code == 200
      raise "Ollama HTTP #{response.code}: #{response.body.to_s[0, 300]}"
    end

    data       = JSON.parse(response.body)
    text       = data.dig("choices", 0, "message", "content") || ""
    usage_data = data["usage"] || {}

    OllamaMessageResponse.new(text: text, usage_data: usage_data)
  rescue JSON::ParserError => e
    raise StructuredOutputError, "Ollama response JSON parse error: #{e.message}"
  end

  private

  # Anthropic supports Array-of-blocks system prompts (for cache_control).
  # Flatten those to a plain string for OpenAI-compatible APIs.
  def normalize_system(system)
    case system
    when Array
      system.map { |b| b.is_a?(Hash) ? (b[:text] || b["text"] || "").to_s : b.to_s }.join("\n\n")
    when String then system
    end
  end

  def append_schema_hint(system_text, output_config)
    return system_text unless output_config && (klass = output_config[:format])

    hint = JSON_SCHEMA_HINTS[klass.name]
    return system_text unless hint

    [system_text, hint].compact.join("\n\n")
  end

  def build_messages(system_text, messages)
    result = []
    result << { role: "system", content: system_text } if system_text && !system_text.empty?
    messages.each do |m|
      result << { role: m[:role] || m["role"], content: m[:content] || m["content"] }
    end
    result
  end
end

class OllamaMessageResponse
  ContentBlock = Struct.new(:text)

  attr_reader :stop_reason

  def initialize(text:, usage_data: {})
    @text       = text
    @usage_data = usage_data
    @stop_reason = "end_turn"
  end

  # Called by require_parsed_output! in AnthropicClient.
  # Strips markdown fences the model may have added and parses JSON.
  def parsed_output
    return @parsed_output if defined?(@parsed_output)

    @parsed_output = begin
      cleaned = @text.gsub(/\A\s*```(?:json)?\s*/i, "").gsub(/\s*```\s*\z/, "").strip
      data = JSON.parse(cleaned)
      JsonStructWrapper.new(data)
    rescue JSON::ParserError => e
      raise StructuredOutputError, "Ollama JSON parse failed: #{e.message}\nRaw: #{@text[0, 400]}"
    end
  end

  # DescriptionAgent reads message.content.first.text for plain-text responses.
  def content
    [ContentBlock.new(@text)]
  end

  # UsageLogger reads message.usage.{input,output}_tokens etc.
  def usage
    OllamaUsage.new(@usage_data)
  end
end

class OllamaUsage
  def initialize(data)
    @data = data
  end

  def input_tokens                = @data["prompt_tokens"]     || 0
  def output_tokens               = @data["completion_tokens"] || 0
  def cache_creation_input_tokens = nil
  def cache_read_input_tokens     = nil
end

# Wraps a parsed JSON Hash recursively, exposing keys as Ruby method calls.
# This makes JsonStructWrapper instances behave like Anthropic::BaseModel objects —
# agents can call .title, .segments, .name, etc. without changes.
class JsonStructWrapper
  def initialize(data)
    @data = data
  end

  def method_missing(name, *args, &block)
    key = name.to_s
    return super unless @data.is_a?(Hash) && (@data.key?(key) || @data.key?(name))

    wrap(@data.key?(key) ? @data[key] : @data[name])
  end

  def respond_to_missing?(name, include_private = false)
    (@data.is_a?(Hash) && (@data.key?(name.to_s) || @data.key?(name))) || super
  end

  def nil?  = @data.nil?
  def any?  = @data.is_a?(Array) ? !@data.empty? : !@data.nil?
  def to_s  = @data.to_s
  def inspect = "#<JsonStructWrapper #{@data.inspect}>"

  private

  def wrap(val)
    case val
    when Hash  then JsonStructWrapper.new(val)
    when Array then val.map { |item| wrap(item) }
    else val  # String, Integer, nil, etc. — pass through unchanged
    end
  end
end
