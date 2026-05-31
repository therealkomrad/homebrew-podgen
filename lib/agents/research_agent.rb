# frozen_string_literal: true

require "exa-ai"
require "set"
require_relative "../loggable"
require_relative "../retryable"

class ResearchAgent
  include Loggable
  include Retryable

  MAX_RETRIES = 3
  # Exa returns dense, summarized findings — the richest material for the script. Tunable
  # via EXA_RESULTS_PER_TOPIC (default 5) to feed the script writer more specifics.
  RESULTS_PER_TOPIC = (ENV["EXA_RESULTS_PER_TOPIC"].to_i if ENV["EXA_RESULTS_PER_TOPIC"].to_i > 0) || 5

  def initialize(results_per_topic: RESULTS_PER_TOPIC, exclude_urls: Set.new, category: "news", logger: nil)
    @results_per_topic = results_per_topic
    @exclude_urls = exclude_urls
    @category = category
    @logger = logger

    Exa.configure do |config|
      config.api_key = ENV.fetch("EXA_API_KEY") {
        raise "EXA_API_KEY environment variable is not set"
      }
    end
    @client = Exa::Client.new(timeout: 30)
  end

  # Input: array of topic strings
  # Output: array of { topic:, findings: [{ title:, url:, summary: }] }
  def research(topics, exclude_urls: nil)
    effective_excludes = exclude_urls ? (@exclude_urls | exclude_urls) : @exclude_urls
    topics.map do |topic|
      log("Researching: #{topic}")
      start = Time.now
      findings = search_topic(topic, effective_excludes)
      elapsed = (Time.now - start).round(2)
      log("Found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic, exclude_urls = @exclude_urls)
    results = search_with_retry(
      topic,
      num_results: @results_per_topic,
      type: "auto",
      category: @category,
      summary: { query: "Summarize this article's key points for a podcast segment" },
      start_published_date: (Date.today - 7).iso8601
    )

    all = results.results.map do |r|
      {
        title: r["title"],
        url: r["url"],
        summary: r["summary"]
      }
    end

    if exclude_urls.any?
      before = all.length
      all.reject! { |r| exclude_urls.include?(r[:url]) }
      filtered = before - all.length
      log("Filtered #{filtered} previously-used URL(s) for '#{topic}'") if filtered > 0
    end

    all
  rescue Exa::Error => e
    log("Failed to research '#{topic}' after #{MAX_RETRIES} attempts: #{e.message}")
    []
  end

  def search_with_retry(query, **params)
    with_retries(max: MAX_RETRIES, on: [Exa::TooManyRequests, Exa::ServerError]) do
      @client.search(query, **params)
    end
  end
end
