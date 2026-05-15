# frozen_string_literal: true

require "date"
require "net/http"
require "uri"
require_relative "atomic_writer"
require_relative "yaml_loader"
require_relative "logger"

# Manages priority links for news podcasts.
# Links are stored in podcasts/<name>/links.yml and consumed on successful generation.
class PriorityLinks
  def initialize(path)
    @path = path
  end

  # Returns array of link hashes: [{ "url" => ..., "added" => ..., "note" => ... }]
  def all
    YamlLoader.load(@path, default: [])
  end

  def empty?
    all.empty?
  end

  def count
    all.length
  end

  # Add a URL. Deduplicates by URL. Returns true if added, false if duplicate.
  def add(url, note: nil)
    entries = all
    return false if entries.any? { |e| e["url"] == url }

    entry = { "url" => url, "added" => Date.today.to_s }
    entry["note"] = note if note && !note.empty?
    entries << entry
    write!(entries)
    true
  end

  # Remove a URL. Returns true if found and removed, false otherwise.
  def remove(url)
    entries = all
    before = entries.length
    entries.reject! { |e| e["url"] == url }
    return false if entries.length == before

    write!(entries)
    true
  end

  # Clear all links. Returns count of removed links.
  def clear!
    entries = all
    count = entries.length
    return 0 if count.zero?

    File.delete(@path) if File.exist?(@path)
    count
  end

  # Fetch content for all links, returning research-style findings.
  # Returns: [{ title:, url:, summary: }]
  # Includes the user's note in the summary if present.
  def fetch_all(logger: nil)
    entries = all
    return [] if entries.empty?

    target = logger || PodcastAgent.logger
    entries.map do |entry|
      url = entry["url"]
      note = entry["note"]
      target.log("  Fetching: #{url}")

      title, summary = fetch_page_info(url)
      title ||= url
      summary = [note, summary].compact.reject(&:empty?).join(" — ") if note

      target.log("  \u2713 #{title}")
      { title: title, url: url, summary: summary || "Priority link added by producer" }
    end
  end

  # Remove all links that were successfully consumed (by URL set).
  def consume!(urls)
    entries = all
    before = entries.length
    url_set = urls.to_set
    entries.reject! { |e| url_set.include?(e["url"]) }
    write!(entries) if entries.length != before
  end

  private

  def write!(entries)
    if entries.empty?
      AtomicWriter.delete_if_exists(@path)
    else
      AtomicWriter.write_yaml(@path, entries)
    end
  end

  # Fetch page title and first paragraph via simple HTTP GET.
  # Returns [title, summary] or [nil, nil] on failure.
  def fetch_page_info(url, max_redirects: 3)
    return [nil, nil] if max_redirects <= 0

    uri = URI.parse(url)
    return [nil, nil] unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "podgen/1.0 (podcast link preview)"
      request["Accept"] = "text/html"
      http.request(request)
    end

    if response.is_a?(Net::HTTPRedirection) && response["location"]
      return fetch_page_info(response["location"], max_redirects: max_redirects - 1)
    end

    return [nil, nil] unless response.is_a?(Net::HTTPSuccess)

    html = response.body.to_s.force_encoding("UTF-8")

    title = html[/<title[^>]*>([^<]+)<\/title>/i, 1]&.strip
    title = title&.gsub(/\s+/, " ")

    # Try to extract meta description
    summary = html[/<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']/i, 1]
    summary ||= html[/<meta[^>]+content=["']([^"']+)["'][^>]+name=["']description["']/i, 1]
    summary = summary&.strip&.gsub(/\s+/, " ")

    [title, summary]
  rescue => _e
    [nil, nil]
  end
end
