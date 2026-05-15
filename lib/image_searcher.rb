# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "tmpdir"
require "fileutils"
require_relative "loggable"

# Searches DuckDuckGo Images for a query, downloads candidates, filters by
# minimum byte size, and returns metadata for survivors.
#
# DDG's image-search JSON endpoint is undocumented and can change without
# notice. Treat this as best-effort. Caller is responsible for cleaning up
# returned tmp file paths.
class ImageSearcher
  include Loggable

  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 " \
               "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  ALLOWED_EXTS = [".jpg", ".jpeg", ".png", ".webp", ".gif"].freeze

  def initialize(logger: nil)
    @logger = logger
  end

  # Returns array of { url:, path:, bytes:, ext: } for survivors above min_bytes.
  def search(query, count:, min_bytes:)
    urls = fetch_urls(query, count: count)
    return [] if urls.empty?

    tmp = Dir.mktmpdir("podgen_imgsearch_")
    survivors = []
    urls.each_with_index do |url, i|
      ext = url_ext(url)
      path = File.join(tmp, "candidate#{i + 1}#{ext}")
      bytes = download(url, path)
      if bytes && bytes >= min_bytes
        survivors << { url: url, path: path, bytes: bytes, ext: ext }
      else
        File.delete(path) if File.exist?(path)
        log("rejected (#{bytes ? "#{bytes}B" : 'failed'}): #{url}") if bytes
      end
    end
    survivors
  end

  private

  def fetch_urls(query, count:)
    vqd = fetch_vqd(query) or return []
    q = URI.encode_www_form_component(query)
    res = http_get("https://duckduckgo.com/i.js?l=us-en&o=json&q=#{q}&vqd=#{vqd}&f=,,,&p=-1",
                   referer: "https://duckduckgo.com/")
    return [] unless res.is_a?(Net::HTTPSuccess)
    data = JSON.parse(res.body) rescue {}
    (data["results"] || []).first(count).map { |r| r["image"] }.compact
  end

  def fetch_vqd(query)
    q = URI.encode_www_form_component(query)
    res = http_get("https://duckduckgo.com/?q=#{q}&iax=images&ia=images")
    return nil unless res.is_a?(Net::HTTPSuccess)
    m = res.body.match(/vqd=['"]([^'"]+)['"]/) || res.body.match(/vqd=([\d-]+)/)
    m && m[1]
  end

  def download(url, path)
    res = http_get(url)
    return nil unless res.is_a?(Net::HTTPSuccess)
    File.binwrite(path, res.body)
    res.body.bytesize
  rescue => e
    log("download failed (#{e.class}): #{e.message}")
    nil
  end

  def http_get(url, referer: nil)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => USER_AGENT)
    req["Referer"] = referer if referer
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: 10, read_timeout: 30) do |http|
      http.request(req)
    end
  end

  def url_ext(url)
    ext = File.extname(URI(url).path).downcase.sub(/\?.*$/, "")
    ALLOWED_EXTS.include?(ext) ? ext : ".jpg"
  rescue URI::InvalidURIError
    ".jpg"
  end

end
