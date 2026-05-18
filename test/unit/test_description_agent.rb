# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/description_agent"

class TestDescriptionAgent < Minitest::Test
  # --- clean_title ---

  def test_clean_title_returns_cleaned
    agent = build_agent("Lačni medved")
    result = agent.clean_title(title: "PRAVLJICA ZA OTROKE: Lačni medved")
    assert_equal "Lačni medved", result
  end

  def test_clean_title_empty_returns_original
    agent = build_agent("anything")
    assert_equal "", agent.clean_title(title: "")
    assert_equal nil, agent.clean_title(title: nil)
  end

  def test_clean_title_on_api_error_returns_original
    agent = build_agent_with_error
    result = agent.clean_title(title: "Some Title")
    assert_equal "Some Title", result
  end

  def test_clean_title_empty_result_returns_original
    agent = build_agent("")
    result = agent.clean_title(title: "Original Title")
    assert_equal "Original Title", result
  end

  # --- ALL CAPS normalization (pre-LLM) ---
  # We assert on what the LLM RECEIVES, not the response, because the LLM is
  # mocked. The point of normalization is to denormalize at input so the LLM's
  # "preserve capitalization" rule can't echo screaming caps back.

  def test_clean_title_sends_normalized_title_to_llm_when_all_caps
    agent = build_agent("ignored")
    client = agent.instance_variable_get(:@client)
    agent.clean_title(title: "UNA NOTTE FANTASMAGORICA")
    sent = client.last_call[:messages].first[:content]
    assert_equal "Una notte fantasmagorica", sent
  end

  def test_clean_title_normalizes_all_caps_unicode_preserving_accents
    agent = build_agent("ignored")
    client = agent.instance_variable_get(:@client)
    agent.clean_title(title: "PRAVLJICA O ČRNI OVCI")
    sent = client.last_call[:messages].first[:content]
    assert_equal "Pravljica o črni ovci", sent
  end

  def test_clean_title_leaves_mixed_case_unchanged
    agent = build_agent("ignored")
    client = agent.instance_variable_get(:@client)
    agent.clean_title(title: "Una notte FANTASMAGORICA")
    sent = client.last_call[:messages].first[:content]
    assert_equal "Una notte FANTASMAGORICA", sent
  end

  def test_clean_title_does_not_normalize_short_uppercase
    agent = build_agent("ignored")
    client = agent.instance_variable_get(:@client)
    agent.clean_title(title: "AI")
    sent = client.last_call[:messages].first[:content]
    assert_equal "AI", sent
  end

  # --- ALL CAPS normalization (post-LLM) ---
  # Regression for fiabe-2026-05-17: the RSS title was
  #   "LA VERA STORIA DELL'APE E DEL FIORE SENZA NOME di Julian Canettieri (vincitore...)"
  # Mixed-case suffix pulled the uppercase ratio under 70%, so the input
  # was not normalized. The LLM then stripped the suffix and returned
  # "LA VERA STORIA DELL'APE E DEL FIORE SENZA NOME" — now all-caps but
  # past the normalization point. Output must also be normalized.

  def test_clean_title_normalizes_all_caps_in_llm_response
    agent = build_agent("LA VERA STORIA DELL'APE E DEL FIORE SENZA NOME")
    # Pre-normalization sees a mixed-case input and leaves it alone.
    result = agent.clean_title(title: "Una storia: LA VERA STORIA DELL'APE E DEL FIORE SENZA NOME di Julian Canettieri")
    assert_equal "La vera storia dell'ape e del fiore senza nome", result
  end

  def test_clean_title_leaves_properly_cased_llm_response_unchanged
    agent = build_agent("La vera storia dell'ape")
    result = agent.clean_title(title: "Una storia: La vera storia dell'ape")
    assert_equal "La vera storia dell'ape", result
  end

  # --- clean ---

  def test_clean_returns_cleaned_description
    agent = build_agent("A bear goes on an adventure.")
    result = agent.clean(title: "Lačni medved", description: "A bear goes on an adventure. Subscribe! #kids")
    assert_equal "A bear goes on an adventure.", result
  end

  def test_clean_empty_description_returns_original
    agent = build_agent("anything")
    assert_equal "", agent.clean(title: "T", description: "")
    assert_equal nil, agent.clean(title: "T", description: nil)
  end

  def test_clean_on_api_error_returns_original
    agent = build_agent_with_error
    result = agent.clean(title: "T", description: "Original desc")
    assert_equal "Original desc", result
  end

  def test_clean_empty_result_returns_original
    agent = build_agent("")
    result = agent.clean(title: "T", description: "Original desc")
    assert_equal "Original desc", result
  end

  # --- generate_title ---

  def test_generate_title_returns_generated_title
    agent = build_agent("Szczepan i smok")
    result = agent.generate_title(transcript: "Dawno temu żył sobie chłopiec imieniem Szczepan...", language: "Polish")
    assert_equal "Szczepan i smok", result
  end

  def test_generate_title_empty_transcript_returns_nil
    agent = build_agent("anything")
    assert_nil agent.generate_title(transcript: "", language: "Polish")
    assert_nil agent.generate_title(transcript: nil, language: "Polish")
  end

  def test_generate_title_on_api_error_returns_nil
    agent = build_agent_with_error
    assert_nil agent.generate_title(transcript: "Some text", language: "Polish")
  end

  def test_generate_title_empty_result_returns_nil
    agent = build_agent("")
    assert_nil agent.generate_title(transcript: "Some text", language: "Polish")
  end

  # --- generate ---

  def test_generate_returns_description
    agent = build_agent("A story about a hungry bear.")
    result = agent.generate(title: "Lačni medved", transcript: "Nekoč je živel medved...")
    assert_equal "A story about a hungry bear.", result
  end

  def test_generate_empty_transcript_returns_empty
    agent = build_agent("anything")
    assert_equal "", agent.generate(title: "T", transcript: "")
    assert_equal "", agent.generate(title: "T", transcript: nil)
  end

  def test_generate_on_api_error_returns_empty
    agent = build_agent_with_error
    result = agent.generate(title: "T", transcript: "Some transcript")
    assert_equal "", result
  end

  def test_generate_truncates_long_transcript
    agent = build_agent("Short description")
    client = agent.instance_variable_get(:@client)

    long_transcript = "x" * 5000
    agent.generate(title: "T", transcript: long_transcript)

    user_msg = client.last_call[:messages].first[:content]
    # TRANSCRIPT_LIMIT is 2000
    assert user_msg.length < 5000
  end

  # --- model selection ---

  def test_default_model_is_sonnet
    prev_desc = ENV.delete("CLAUDE_DESCRIPTION_MODEL")
    prev_web = ENV.delete("CLAUDE_WEB_MODEL")
    agent = DescriptionAgent.new
    assert_equal "claude-sonnet-4-6", agent.instance_variable_get(:@model)
  ensure
    ENV["CLAUDE_DESCRIPTION_MODEL"] = prev_desc if prev_desc
    ENV["CLAUDE_WEB_MODEL"] = prev_web if prev_web
  end

  def test_claude_description_model_env_overrides_default
    ENV["CLAUDE_DESCRIPTION_MODEL"] = "claude-haiku-4-5-20251001"
    agent = DescriptionAgent.new
    assert_equal "claude-haiku-4-5-20251001", agent.instance_variable_get(:@model)
  ensure
    ENV.delete("CLAUDE_DESCRIPTION_MODEL")
  end

  def test_claude_web_model_does_not_affect_description_agent
    ENV.delete("CLAUDE_DESCRIPTION_MODEL")
    ENV["CLAUDE_WEB_MODEL"] = "claude-haiku-4-5-20251001"
    agent = DescriptionAgent.new
    assert_equal "claude-sonnet-4-6", agent.instance_variable_get(:@model)
  ensure
    ENV.delete("CLAUDE_WEB_MODEL")
  end

  # --- system prompt anti-conversational guards ---

  def test_clean_title_prompt_forbids_conversational_responses
    agent = DescriptionAgent.new
    prompt = agent.send(:clean_title_system_prompt)
    assert_match(/never ask questions/i, prompt)
    assert_match(/never explain/i, prompt)
  end

  def test_clean_title_prompt_includes_question_shaped_title_example
    # Regression: bajke 2026-05-01 — "Kaj delam narobe" was interpreted as
    # a question by the LLM, which then echoed example titles back as a
    # conversational reply. The prompt must teach: ambiguous input is a title.
    agent = DescriptionAgent.new
    prompt = agent.send(:clean_title_system_prompt)
    assert_match(/Kaj delam narobe.*Kaj delam narobe/m, prompt,
      "expected the question-shaped title example to be present")
  end

  private

  def build_agent(response_text)
    agent = DescriptionAgent.new
    client = MockTextClient.new(response_text)
    agent.instance_variable_set(:@client, client)
    agent
  end

  def build_agent_with_error
    agent = DescriptionAgent.new
    client = MockTextClient.new(nil, error: RuntimeError.new("API down"))
    agent.instance_variable_set(:@client, client)
    agent
  end

  class MockTextClient
    attr_reader :calls

    def initialize(text, error: nil)
      @text = text
      @error = error
      @calls = []
    end

    def messages = self
    def last_call = @calls.last

    def create(**kw)
      @calls << kw
      raise @error if @error
      MockTextMsg.new(@text)
    end
  end

  class MockTextMsg
    def initialize(text) = @text = text
    def stop_reason = "end_turn"
    def usage = MockUsage.new
    def content = [MockBlock.new(@text)]
  end

  MockBlock = Struct.new(:text)

  class MockUsage
    def input_tokens = 100
    def output_tokens = 30
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
