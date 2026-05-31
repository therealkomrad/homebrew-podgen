# frozen_string_literal: true

require "httparty"
require "json"
require_relative "ollama_client" # reuse OllamaMessageResponse, JSON_SCHEMAS, StructuredOutputError

# Interface-compatible LLM client for any OpenAI-compatible /chat/completions endpoint.
# Activated when LLM_ENGINE=openai. Verified against Google AI Studio's Gemini endpoint
# (https://generativelanguage.googleapis.com/v1beta/openai); also works with Groq, Cerebras, etc.
#
# Mirrors Anthropic::Client#messages.create — agents call it the same way as the Ollama client.
# Structured calls (topics, review) request JSON object mode and embed the JSON Schema in the
# system prompt; free-form calls (per-segment script prose) send no response_format.
class OpenAICompatClientWrapper
  def initialize(base_url:, api_key:)
    @messages = OpenAICompatMessagesInterface.new(base_url: base_url, api_key: api_key)
  end

  def messages
    @messages
  end
end

class OpenAICompatMessagesInterface
  @last_call_at = nil
  @throttle_mutex = Mutex.new
  class << self
    attr_accessor :last_call_at, :throttle_mutex
  end

  def initialize(base_url:, api_key:)
    @base_url = base_url.chomp("/")
    @api_key  = api_key
  end

  def create(model:, max_tokens:, system: nil, messages: [], output_config: nil, **_ignored)
    throttle! # respect free-tier requests-per-minute limits across all agents
    schema_name = output_config && output_config[:format].name
    schema      = schema_name && OllamaMessagesInterface::JSON_SCHEMAS[schema_name]

    sys_text = normalize_system(system)
    if schema
      sys_text = "#{sys_text}\n\nRespond with ONLY a single JSON object that conforms to this " \
                 "JSON Schema. No prose, no markdown fences:\n#{JSON.generate(schema)}"
    end

    chat = []
    chat << { role: "system", content: sys_text } if sys_text && !sys_text.empty?
    messages.each { |m| chat << { role: m[:role] || m["role"], content: m[:content] || m["content"] } }

    body = {
      model:       model,
      messages:    chat,
      max_tokens:  max_tokens,
      temperature: ENV.fetch("LLM_TEMPERATURE", "0.7").to_f
    }
    # Gemini 2.5+/3.x are thinking models; without this the reasoning tokens consume the
    # output budget and the visible answer is truncated. "none" disables thinking.
    effort = ENV.fetch("LLM_REASONING_EFFORT", "none")
    body[:reasoning_effort] = effort unless effort.empty? || effort == "default"
    body[:response_format]  = { type: "json_object" } if schema

    response = nil
    attempts = 0
    loop do
      response = HTTParty.post(
        "#{@base_url}/chat/completions",
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@api_key}" },
        body:    body.to_json,
        timeout: 600
      )
      # Free-tier rate limit (per-minute quota). Wait it out and retry a few times before failing.
      break unless response.code == 429 && attempts < 5
      attempts += 1
      sleep(retry_after_seconds(response) || [15 * attempts, 60].min)
    end

    unless response.code == 200
      raise "OpenAI-compat HTTP #{response.code}: #{response.body.to_s[0, 300]}"
    end

    data = JSON.parse(response.body)
    text = data.dig("choices", 0, "message", "content").to_s
    OllamaMessageResponse.new(text: text, usage_data: data)
  rescue JSON::ParserError => e
    raise StructuredOutputError, "OpenAI-compat JSON parse error: #{e.message}"
  end

  private

  # Enforce a minimum interval between LLM calls (shared across all agent instances) so a
  # burst of per-segment calls stays under the provider's requests-per-minute free-tier limit.
  def throttle!
    min_interval = ENV.fetch("LLM_MIN_INTERVAL_SECONDS", "0").to_f
    return if min_interval <= 0

    klass = self.class
    klass.throttle_mutex.synchronize do
      if klass.last_call_at
        elapsed = Time.now - klass.last_call_at
        sleep(min_interval - elapsed) if elapsed < min_interval
      end
      klass.last_call_at = Time.now
    end
  end

  # Reads a retry delay from the 429 response (Retry-After header or Gemini's
  # RetryInfo retryDelay like "21s"). Returns seconds (Float) or nil.
  def retry_after_seconds(response)
    hdr = response.headers["retry-after"] || response.headers["Retry-After"]
    return hdr.to_f if hdr && hdr.to_f > 0

    body = response.body.to_s
    m = body.match(/"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"/)
    m && m[1].to_f
  rescue StandardError
    nil
  end

  def normalize_system(system)
    case system
    when Array  then system.map { |b| b.is_a?(Hash) ? (b[:text] || b["text"] || "").to_s : b.to_s }.join("\n\n")
    when String then system
    else ""
    end
  end
end
