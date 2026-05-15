# frozen_string_literal: true

require "anthropic"
require "base64"
require "json"
require_relative "loggable"

# Ranks candidate cover images using a single batched Claude vision call.
# Each candidate gets a combined score (fits_fairytale_cover + matches_episode_description),
# with hard veto flags (has_watermark, !composition_ok) and a tie-breaker
# bonus for has_title_text.
#
# Returned candidates preserve the original metadata from ImageSearcher and
# add: :score (Integer 2-20), :has_title_text, :has_watermark, :composition_ok,
# :reasons (String), :vetoed (Boolean — true if watermark or bad composition).
#
# Sort order: vetoed last; among non-vetoed, has_title_text first, then
# score DESC.
class ImageRanker
  include Loggable

  DEFAULT_MODEL = "claude-sonnet-4-6"
  MEDIA_TYPES = {
    ".jpg"  => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png"  => "image/png",
    ".webp" => "image/webp",
    ".gif"  => "image/gif"
  }.freeze

  def initialize(model: nil, logger: nil)
    @model = model || DEFAULT_MODEL
    @client = Anthropic::Client.new
    @logger = logger
  end

  def rank(candidates, title:, description:)
    return [] if candidates.nil? || candidates.empty?

    response = @client.messages.create(
      model: @model,
      max_tokens: 2000,
      messages: [{ role: "user", content: build_content(candidates, title, description) }]
    )

    parsed = parse_response(response)
    return [] if parsed.nil?

    annotated = candidates.each_with_index.map do |c, i|
      r = parsed.find { |row| row["index"] == i } || {}
      score = r["visual_quality"].to_i + r["subject_match"].to_i
      vetoed = r["has_overlay_watermark"] == true
      c.merge(
        score: score,
        visual_quality: r["visual_quality"].to_i,
        subject_match: r["subject_match"].to_i,
        has_title_text: r["has_title_text"] == true,
        has_overlay_watermark: r["has_overlay_watermark"] == true,
        reasons: r["reasons"].to_s,
        vetoed: !!vetoed
      )
    end

    annotated.sort_by.with_index do |c, i|
      [c[:vetoed] ? 1 : 0, c[:has_title_text] ? 0 : 1, -c[:score], i]
    end
  end

  private

  def build_content(candidates, title, description)
    blocks = [{ type: "text", text: prompt_intro(title, description, candidates.length) }]
    candidates.each_with_index do |c, i|
      blocks << { type: "text", text: "Image #{i} (index #{i}):" }
      blocks << {
        type: "image",
        source: {
          type: "base64",
          media_type: media_type_for(c[:ext]),
          data: Base64.strict_encode64(File.binread(c[:path]))
        }
      }
    end
    blocks << { type: "text", text: prompt_schema }
    blocks
  end

  def prompt_intro(title, description, n)
    <<~TEXT
      You are evaluating #{n} candidate image#{n == 1 ? "" : "s"} for use as cover art for a podcast episode.

      Episode title: #{title}
      Episode description: #{description.to_s.empty? ? "(none)" : description}

      For each image, score:
      1. visual_quality (1-10): How clean is the image as a finished piece of cover artwork?
         HIGH (8-10): clean rendered illustration, sharp resolution, no JPEG artifacts, no
         visible damage or wear, professional finish.
         LOW (1-4): low-res scan, faded or worn document, photo of physical media (book on
         a shelf, CD on a basket, magazine on a table), screenshot artifacts, busy
         real-world photographic background, heavy noise, or dog-eared/scuffed edges.
      2. subject_match (1-10): How well does the depicted content match the episode title
         and description?
      3. has_title_text (boolean): Does the image already contain visible text matching the
         episode title? (Bonus if true.)
      4. has_overlay_watermark (boolean): Is there a REPEATING watermark pattern — the same
         logo or text tiled across the image, or a translucent overlay covering most of the
         artwork? Veto if true.
         IMPORTANT: small corner logos, attribution lines, theatre/publisher branding in
         the corners, or letterbox bars are NOT watermarks. Only flag a tiled/repeating
         watermark or a centered translucent stamp covering the artwork.
      5. reasons: one short sentence explaining your scoring.
    TEXT
  end

  def prompt_schema
    <<~TEXT
      Return ONLY valid JSON, no prose, no markdown fences. Schema:
      {
        "rankings": [
          {
            "index": 0,
            "visual_quality": 8,
            "subject_match": 9,
            "has_title_text": false,
            "has_overlay_watermark": false,
            "reasons": "..."
          }
        ]
      }
    TEXT
  end

  def media_type_for(ext)
    MEDIA_TYPES[ext.to_s.downcase] || "image/jpeg"
  end

  def parse_response(response)
    text = response.content.first.text rescue nil
    return nil unless text
    json = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
    data = JSON.parse(json)
    data["rankings"]
  rescue JSON::ParserError => e
    log("malformed JSON: #{e.message}")
    nil
  end

end
