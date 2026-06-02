# frozen_string_literal: true

require "anthropic"

class StructuredOutputError < StandardError; end

# Shared LLM client initialization.
# Include in classes that call the LLM and call init_anthropic_client
# in initialize to set @client and @model.
#
# Supports two engines via the LLM_ENGINE environment variable:
#   LLM_ENGINE=anthropic (default) — Anthropic Claude via the official SDK
#   LLM_ENGINE=ollama               — Any Ollama-compatible local server (free)
#
# Ollama env vars:
#   OLLAMA_BASE_URL  (default: http://localhost:11434/v1)
#   OLLAMA_MODEL     (default: llama3.1:8b — use qwen2.5:7b for best JSON compliance)
module AnthropicClient
  private

  # ollama_model_env / openai_model_env: optional env var names for a per-agent model
  # override on the Ollama / OpenAI-compatible (e.g. Gemini) engines respectively
  # (e.g. "OLLAMA_SCRIPT_MODEL", "LLM_REVIEW_MODEL"). Each falls back to the engine's
  # default model when unset/empty — so a lightweight model can review while the main
  # model writes, which also spreads load across separate per-model rate-limit quotas
  # (Gemini's free tier is metered per-project-per-model).
  def init_anthropic_client(env_key: "CLAUDE_MODEL", default_model: "claude-opus-4-7", ollama_model_env: nil, openai_model_env: nil)
    if ENV["LLM_ENGINE"] == "ollama"
      require_relative "ollama_client"
      @client = OllamaClientWrapper.new(
        base_url: ENV.fetch("OLLAMA_BASE_URL", "http://localhost:11434"),
        api_key:  ENV.fetch("OLLAMA_API_KEY", "local")
      )
      override = ollama_model_env && ENV[ollama_model_env]
      override = nil if override == ""
      @model = override || ENV.fetch("OLLAMA_MODEL", "llama3.1:8b")
    elsif ENV["LLM_ENGINE"] == "openai"
      # Any OpenAI-compatible /chat/completions endpoint (Gemini free tier, Groq, Cerebras…).
      require_relative "openai_compat_client"
      @client = OpenAICompatClientWrapper.new(
        base_url: ENV.fetch("OPENAI_COMPAT_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai"),
        api_key:  ENV.fetch("OPENAI_COMPAT_API_KEY") { ENV.fetch("OPENAI_API_KEY", "") }
      )
      override = openai_model_env && ENV[openai_model_env]
      override = nil if override == ""
      @model = override || ENV.fetch("LLM_MODEL", "gemini-2.5-flash")
    else
      @client = Anthropic::Client.new
      @model = ENV.fetch(env_key, default_model)
    end
  end

  # Extract and validate structured output from an API response.
  # Raises StructuredOutputError when the SDK silently stored an error hash
  # instead of the expected model instance (e.g. JSON parse failure).
  def require_parsed_output!(message, _expected_class = nil)
    parsed = message.parsed_output
    if parsed.nil?
      raise StructuredOutputError,
        "No parsed output (stop_reason: #{message.stop_reason})"
    end
    if parsed.is_a?(Hash) && parsed.key?(:error)
      raise StructuredOutputError,
        "SDK parsing failed: #{parsed[:error]}"
    end
    parsed
  end
end
