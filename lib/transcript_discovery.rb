# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "subtitle_parser"
require_relative "logger"

# Discovers existing transcripts from episode metadata before STT transcription.
# Checks multiple sources in priority order: podcast:transcript tags, content:encoded,
# episode web pages, and YouTube captions.
#
# Returns a hash with :text, :source, :quality or nil if nothing found.
# Quality levels:
#   :high   — Official transcript (podcast:transcript, web page). Could replace STT.
#   :medium — Substantial content:encoded text. Good reconciliation reference.
#   :low    — YouTube auto-captions. Tiebreaker only.
module TranscriptDiscovery
  MINIMUM_WORD_COUNT = 100
  FETCH_OPEN_TIMEOUT = 10
  FETCH_READ_TIMEOUT = 15

  # Search for existing transcripts across all available sources.
  #
  # @param rss_item [Hash] Episode metadata from RSS: { transcript_url:, transcript_type:,
  #   content_encoded:, link:, description: }
  # @param youtube_captions [String, nil] Pre-fetched YouTube caption text
  # @param logger [Object, nil] Logger instance
  # @return [Hash, nil] { text:, source:, quality: } or nil
  def self.search(rss_item: {}, youtube_captions: nil, logger: nil)
    # 1. Podcasting 2.0 <podcast:transcript> tag
    if (url = rss_item[:transcript_url])
      result = fetch_podcast_transcript(url, rss_item[:transcript_type], logger: logger)
      return result if result
    end

    # 2. <content:encoded> with substantial text
    if (content = rss_item[:content_encoded])
      result = check_content_encoded(content, logger: logger)
      return result if result
    end

    # 3. Episode web page — disabled: too many false positives from page chrome/JS.
    #    Re-enable when we have a more reliable content extraction strategy.
    # if (link = rss_item[:link])
    #   result = scrape_episode_page(link, logger: logger)
    #   return result if result
    # end

    # 4. YouTube captions (lowest priority)
    if youtube_captions && !youtube_captions.strip.empty?
      return { text: youtube_captions, source: "youtube_captions", quality: :low }
    end

    nil
  end

  # Fetch and parse a Podcasting 2.0 transcript URL.
  def self.fetch_podcast_transcript(url, content_type = nil, logger: nil)
    log("Checking podcast:transcript → #{url}", logger)
    content = fetch_url(url)
    return nil unless content

    text = SubtitleParser.parse(content, content_type: content_type)
    return nil if text.empty? || word_count(text) < MINIMUM_WORD_COUNT

    log("Found transcript via podcast:transcript (#{word_count(text)} words)", logger)
    { text: text, source: "podcast:transcript", quality: :high }
  rescue => e
    log("Failed to fetch podcast:transcript: #{e.message}", logger)
    nil
  end

  # Check content:encoded for substantial text content.
  def self.check_content_encoded(html, logger: nil)
    text = strip_html(html).strip
    return nil if word_count(text) < MINIMUM_WORD_COUNT

    log("Found transcript in content:encoded (#{word_count(text)} words)", logger)
    { text: text, source: "content:encoded", quality: :medium }
  end

  # Scrape an episode web page for transcript content.
  def self.scrape_episode_page(url, logger: nil)
    log("Checking episode page → #{url}", logger)
    html = fetch_url(url)
    return nil unless html

    text = extract_transcript_from_html(html)
    return nil if text.nil? || word_count(text) < MINIMUM_WORD_COUNT

    log("Found transcript on episode page (#{word_count(text)} words)", logger)
    { text: text, source: "episode_page", quality: :high }
  rescue => e
    log("Failed to scrape episode page: #{e.message}", logger)
    nil
  end

  class << self
    private

    def fetch_url(url, limit: 3)
      uri = URI.parse(url)

      limit.times do
        return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = FETCH_OPEN_TIMEOUT
        http.read_timeout = FETCH_READ_TIMEOUT

        response = http.request(Net::HTTP::Get.new(uri))
        case response
        when Net::HTTPSuccess
          body = response.body
          body = body.force_encoding("UTF-8") if body.encoding == Encoding::ASCII_8BIT
          return body
        when Net::HTTPRedirection
          uri = URI.join(uri, response["location"])
        else
          return nil
        end
      end
      nil
    rescue => e
      nil
    end

    def strip_html(html)
      html.gsub(/<script[^>]*>.*?<\/script>/mi, "")
        .gsub(/<style[^>]*>.*?<\/style>/mi, "")
        .gsub(/<br\s*\/?\s*>/i, "\n")
        .gsub(/<\/p>/i, "\n\n")
        .gsub(/<[^>]+>/, "")
        .gsub(/&nbsp;/, " ")
        .gsub(/&amp;/, "&")
        .gsub(/&lt;/, "<")
        .gsub(/&gt;/, ">")
        .gsub(/&#?\w+;/, "")
        .gsub(/\n{3,}/, "\n\n")
        .strip
    end

    # Extract transcript-like text from an HTML page.
    # Looks for <article>, common transcript container classes, or large text blocks.
    def extract_transcript_from_html(html)
      # Try to find article or transcript container
      article = html[/<article[^>]*>(.*?)<\/article>/mi, 1]
      article ||= html[/<div[^>]*class="[^"]*transcript[^"]*"[^>]*>(.*?)<\/div>/mi, 1]
      article ||= html[/<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)<\/div>/mi, 1]

      if article
        text = strip_html(article)
        return text if word_count(text) >= MINIMUM_WORD_COUNT
      end

      # Fallback: extract all paragraph text
      paragraphs = html.scan(/<p[^>]*>(.*?)<\/p>/mi).flatten
      text = paragraphs.map { |p| strip_html(p) }.reject(&:empty?).join("\n\n")
      return text if word_count(text) >= MINIMUM_WORD_COUNT

      nil
    end

    def word_count(text)
      text.split(/\s+/).length
    end

    def log(msg, logger = nil)
      (logger || PodcastAgent.logger).log("[TranscriptDiscovery] #{msg}")
    end
  end
end
