# frozen_string_literal: true

require "httparty"
require "json"

# Interface-compatible replacement for Anthropic::Client backed by Ollama.
# Activated when LLM_ENGINE=ollama is set in the environment.
# Uses Ollama's native /api/chat endpoint with JSON Schema structured output,
# which constrains token sampling so field names are enforced at the model level.
#
# OllamaClientWrapper.new(base_url:, api_key:)
#   .messages
#   .create(model:, max_tokens:, system:, messages:, output_config: nil)
#     → OllamaMessageResponse
class OllamaClientWrapper
  def initialize(base_url:, api_key: "local")
    @messages = OllamaMessagesInterface.new(base_url: base_url)
  end

  def messages
    @messages
  end
end

class OllamaMessagesInterface
  # JSON Schemas passed to Ollama's `format` parameter.
  # Ollama constrains token sampling to match the schema — field names are enforced
  # at the model level, not just in the prompt.
  JSON_SCHEMAS = {
    "PodcastScript" => {
      type: "object",
      required: ["title", "segments", "sources"],
      properties: {
        title: { type: "string" },
        segments: {
          type: "array",
          items: {
            type: "object",
            required: ["name", "text", "sources"],
            properties: {
              name:    { type: "string" },
              text:    { type: "string" },
              sources: {
                type: "array",
                items: {
                  type: "object",
                  required: ["title", "url"],
                  properties: {
                    title: { type: "string" },
                    url:   { type: "string" }
                  }
                }
              }
            }
          }
        },
        sources: {
          type: "array",
          items: {
            type: "object",
            required: ["title", "url"],
            properties: {
              title: { type: "string" },
              url:   { type: "string" }
            }
          }
        }
      }
    }.freeze,
    # One podcast segment — used by ScriptAgent's per-segment generation mode, which
    # writes each segment in its own focused LLM call for greater depth and length.
    "Segment" => {
      type: "object",
      required: ["name", "text", "sources"],
      properties: {
        name:    { type: "string" },
        text:    { type: "string" },
        sources: {
          type: "array",
          items: {
            type: "object",
            required: ["title", "url"],
            properties: {
              title: { type: "string" },
              url:   { type: "string" }
            }
          }
        }
      }
    }.freeze,
    "TopicList" => {
      type: "object",
      required: ["queries"],
      properties: {
        queries: {
          type: "array",
          items: {
            type: "object",
            required: ["query"],
            properties: {
              query: { type: "string" }
            }
          }
        }
      }
    }.freeze,
    "ScriptReview" => {
      type: "object",
      required: ["issues", "overall_assessment"],
      properties: {
        issues: {
          type: "array",
          items: {
            type: "object",
            required: ["severity", "check", "segment", "message"],
            properties: {
              severity: { type: "string", enum: ["BLOCKER", "WARNING", "NIT"] },
              check:    { type: "string" },
              segment:  { type: "string" },
              message:  { type: "string" }
            }
          }
        },
        overall_assessment: { type: "string" }
      }
    }.freeze
  }.freeze

  def initialize(base_url:)
    @base_url = base_url.chomp("/")
  end

  # Mirrors Anthropic::Client#messages.create — agents call this directly.
  # output_config[:format].name is used to look up the JSON Schema for structured output.
  def create(model:, max_tokens:, system: nil, messages: [], output_config: nil, **_ignored)
    system_text = normalize_system(system)
    schema      = output_config && JSON_SCHEMAS[output_config[:format].name]

    ollama_messages = build_messages(system_text, messages)

    ctx_size    = ENV.fetch("OLLAMA_CTX_SIZE", "8192").to_i
    # Ignore max_tokens from agents for Ollama — those values were sized for cloud APIs.
    # Cap the output budget at OLLAMA_NUM_PREDICT. Reasoning is disabled below, so this
    # budget goes entirely to the JSON answer rather than hidden thinking tokens.
    num_predict = [max_tokens, ENV.fetch("OLLAMA_NUM_PREDICT", "3000").to_i].min
    body = {
      model:    model,
      messages: ollama_messages,
      stream:   false,
      options:  { num_predict: num_predict, num_ctx: ctx_size }
    }

    # Disable reasoning/thinking for thinking models (e.g. qwen3.x). Otherwise the model
    # spends its entire num_predict budget on hidden reasoning tokens and returns empty
    # content, which fails JSON parsing (StructuredOutputError → retry loop). Ollama
    # ignores this flag on non-thinking models. Set OLLAMA_THINK=true to re-enable.
    body[:think] = false unless ENV["OLLAMA_THINK"] == "true"

    # Send the JSON Schema itself (Ollama structured outputs) — not the generic
    # format:"json" flag. Constrained decoding forces the model to emit an object that
    # matches the schema; weaker local models otherwise return markdown prose for complex
    # asks (e.g. script generation), failing JSON parsing.
    body[:format] = schema if schema

    response = HTTParty.post(
      "#{@base_url}/api/chat",
      headers: { "Content-Type" => "application/json" },
      body:    body.to_json,
      timeout: 3600
    )

    unless response.code == 200
      raise "Ollama HTTP #{response.code}: #{response.body.to_s[0, 300]}"
    end

    data       = JSON.parse(response.body)
    text       = data.dig("message", "content") || ""
    usage_data = data

    OllamaMessageResponse.new(text: text, usage_data: usage_data)
  rescue JSON::ParserError => e
    raise StructuredOutputError, "Ollama response JSON parse error: #{e.message}"
  end

  private

  # Anthropic supports Array-of-blocks system prompts (for cache_control).
  # Flatten those to a plain string for Ollama.
  def normalize_system(system)
    case system
    when Array
      system.map { |b| b.is_a?(Hash) ? (b[:text] || b["text"] || "").to_s : b.to_s }.join("\n\n")
    when String then system
    end
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

  attr_reader :stop_reason, :text

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

  def input_tokens                = @data["prompt_eval_count"] || 0
  def output_tokens               = @data["eval_count"]        || 0
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
