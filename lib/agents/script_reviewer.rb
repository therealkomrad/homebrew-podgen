# frozen_string_literal: true

require "date"
require_relative "../anthropic_client"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../usage_logger"

class ReviewIssue < Anthropic::BaseModel
  required :severity, String
  required :check, String
  required :segment, String
  required :message, String
end

class ScriptReview < Anthropic::BaseModel
  required :issues, Anthropic::ArrayOf[ReviewIssue]
  required :overall_assessment, String
end

class ScriptReviewer
  include AnthropicClient
  include Loggable
  include Retryable
  include UsageLogger

  BLOCKER = "BLOCKER"
  WARNING = "WARNING"
  NIT     = "NIT"

  WEEKDAYS = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze
  MONTHS = %w[January February March April May June July August September October November December].freeze

  WEEKDAY_PATTERN = /\b(#{WEEKDAYS.join("|")})\b(,?\s+)(#{MONTHS.join("|")})\s+(\d{1,2})(st|nd|rd|th)?\b/i

  STAGE_DIRECTION_PHRASES = [
    /\s*\b\w+\s+seconds?\s+pause\s+here\.?\s*/i,
    /\s*\b\d+\s+seconds?\s+pause\s+here\.?\s*/i,
    /\s*\bpause\s+here\.?\s*/i,
    /\s*\bbrief\s+pause\.?\s*/i,
    /\s*\btake\s+a\s+breath\.?\s*/i,
    /\s*\bsilence\s+here\.?\s*/i,
    /\s*\blong\s+pause\.?\s*/i,
    /\s*\bshort\s+pause\.?\s*/i
  ].freeze

  STAGE_DIRECTION_BRACKETS = /\[([^\]]*\b(?:pause|beat|silence|breath|wait|sigh|laugh)\b[^\]]*)\]/i
  STAGE_DIRECTION_PARENS = /\(([^)]*\b(?:pause|beat|silence|breath|wait|sigh|laugh)\b[^)]*)\)/i

  FORBIDDEN_PHRASES = [
    /\bin today'?s episode\b/i,
    /\bstay tuned\b/i,
    /\bdon'?t forget to subscribe\b/i,
    /\bmake sure to subscribe\b/i,
    /\bhit that like button\b/i,
    /\blike and subscribe\b/i,
    /\bsponsored by\b/i,
    /\bbrought to you by\b/i,
    /\bwithout further ado\b/i,
    /\blet'?s dive (?:right )?in\b/i,
    /\bI'm \w+,? and this (?:has been|is)\b/i,
    /\bmy name is \w+/i,
    /\bI'm your host\b/i,
    /\bthis is \w+,? (?:signing off|for)\b/i
  ].freeze

  MARKDOWN_BOLD = /\*\*(.+?)\*\*/
  MARKDOWN_ITALIC = /(?<!\*)\*([^*]+?)\*(?!\*)/
  MARKDOWN_LINK = /\[([^\]]+)\]\([^)]+\)/
  MARKDOWN_CODE = /`([^`]+)`/
  MARKDOWN_HEADING = /^\#{1,6}\s+/

  NUMBER_MAGNITUDE = /\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|a|an)\s*[-\s]?\s*(hundred|thousand|million|billion|trillion)\b/i

  def initialize(date:, research_data:, priority_urls: [], guidelines: nil, logger: nil)
    @date = date
    @research_data = research_data
    @priority_urls = Array(priority_urls)
    @guidelines = guidelines
    @logger = logger
    init_anthropic_client(env_key: "CLAUDE_REVIEWER_MODEL")
  end

  # Main entry point.
  # Returns { script:, issues:, passed: }
  def review(script)
    corrected = deep_copy(script)
    all_issues = []

    # Layer 1: deterministic checks
    corrected, det_issues = run_deterministic_checks(corrected)
    all_issues.concat(det_issues)

    # Layer 2: AI review
    begin
      ai_issues = run_ai_review(corrected)
      all_issues.concat(ai_issues)
    rescue => e
      log("AI review failed: #{e.message} (proceeding with deterministic checks only)")
    end

    unfixed_blockers = all_issues.select { |i| i[:severity] == BLOCKER && !i[:auto_fixed] }
    {
      script: corrected,
      issues: all_issues,
      passed: unfixed_blockers.empty?
    }
  end

  # Run only deterministic checks (no API call). Useful for testing.
  def run_deterministic_checks(script)
    corrected = deep_copy(script)
    all_issues = []

    checks = %i[
      check_weekday
      check_title_length
      check_stage_directions
      check_markdown
      check_forbidden_phrases
      check_number_format
      check_priority_urls
    ]

    checks.each do |check|
      corrected, issues = send(check, corrected)
      all_issues.concat(issues)
    end

    [corrected, all_issues]
  end

  private

  # --- Layer 1: Deterministic Checks ---

  def check_weekday(script)
    issues = []
    corrected = deep_copy(script)

    corrected[:segments].each do |seg|
      seg[:text] = seg[:text].gsub(WEEKDAY_PATTERN) do |match|
        stated_weekday = $1
        separator = $2
        month_name = $3
        day = $4.to_i
        suffix = $5 || ""

        month_num = MONTHS.index { |m| m.casecmp(month_name) == 0 }&.+(1)
        next match unless month_num

        begin
          actual_date = Date.new(@date.year, month_num, day)
          correct_weekday = actual_date.strftime("%A")

          if stated_weekday.downcase != correct_weekday.downcase
            issues << {
              severity: BLOCKER, check: "weekday", segment: seg[:name],
              message: "Wrong weekday: '#{stated_weekday}, #{month_name} #{day}' should be '#{correct_weekday}, #{month_name} #{day}'",
              auto_fixed: true
            }
            "#{correct_weekday}#{separator}#{month_name} #{day}#{suffix}"
          else
            match
          end
        rescue Date::Error
          match
        end
      end
    end

    [corrected, issues]
  end

  def check_title_length(script)
    issues = []
    corrected = deep_copy(script)
    title = corrected[:title]

    if title.length > 40
      truncated = truncate_title(title, 40)
      issues << {
        severity: BLOCKER, check: "title_length", segment: "title",
        message: "Title too long (#{title.length} chars, max 40): '#{title}' → '#{truncated}'",
        auto_fixed: true
      }
      corrected[:title] = truncated
    end

    [corrected, issues]
  end

  def check_stage_directions(script)
    issues = []
    corrected = deep_copy(script)

    corrected[:segments].each do |seg|
      original = seg[:text]
      removed_something = false

      # Remove bracketed/parenthesized stage directions
      [STAGE_DIRECTION_BRACKETS, STAGE_DIRECTION_PARENS].each do |pattern|
        before = seg[:text]
        seg[:text] = seg[:text].gsub(pattern, "")
        removed_something = true if seg[:text] != before
      end

      # Remove inline stage direction phrases
      STAGE_DIRECTION_PHRASES.each do |pattern|
        before = seg[:text]
        seg[:text] = seg[:text].gsub(pattern, "")
        removed_something = true if seg[:text] != before
      end

      # Only run cleanup when we actually removed something — never touch clean text.
      # Letter-only post-period regex prevents shooting holes in decimals (30.6) or
      # abbreviations (U.S.).
      if removed_something
        seg[:text] = seg[:text]
          .gsub(/\.([a-zA-Z])/, '. \1')
          .gsub(/\s{2,}/, " ")
          .gsub(/\.\s*\./, ".")
          .strip
      end

      if seg[:text] != original
        issues << {
          severity: WARNING, check: "stage_direction", segment: seg[:name],
          message: "Stage direction removed from segment text",
          auto_fixed: true
        }
      end
    end

    [corrected, issues]
  end

  def check_markdown(script)
    issues = []
    corrected = deep_copy(script)

    corrected[:segments].each do |seg|
      original = seg[:text]

      seg[:text] = seg[:text]
        .gsub(MARKDOWN_BOLD, '\1')
        .gsub(MARKDOWN_ITALIC, '\1')
        .gsub(MARKDOWN_LINK, '\1')
        .gsub(MARKDOWN_CODE, '\1')
        .gsub(MARKDOWN_HEADING, "")

      if seg[:text] != original
        issues << {
          severity: WARNING, check: "markdown", segment: seg[:name],
          message: "Markdown formatting stripped from segment text",
          auto_fixed: true
        }
      end
    end

    [corrected, issues]
  end

  def check_forbidden_phrases(script)
    issues = []

    script[:segments].each do |seg|
      FORBIDDEN_PHRASES.each do |pattern|
        if seg[:text].match?(pattern)
          phrase = seg[:text].match(pattern)[0]
          issues << {
            severity: WARNING, check: "forbidden_phrase", segment: seg[:name],
            message: "Forbidden phrase detected: '#{phrase}'",
            auto_fixed: false
          }
        end
      end
    end

    [deep_copy(script), issues]
  end

  def check_number_format(script)
    issues = []
    count = 0

    script[:segments].each do |seg|
      seg[:text].scan(NUMBER_MAGNITUDE) do
        count += 1
      end
    end

    if count > 0
      severity = count > 3 ? WARNING : NIT
      issues << {
        severity: severity, check: "number_format", segment: "overall",
        message: "#{count} spelled-out number(s) found (should use digits, e.g. $400 million not four hundred million)",
        auto_fixed: false
      }
    end

    [deep_copy(script), issues]
  end

  def check_priority_urls(script)
    issues = []
    return [deep_copy(script), issues] if @priority_urls.empty?

    all_source_urls = collect_source_urls(script)

    @priority_urls.each do |url|
      unless all_source_urls.any? { |src_url| urls_match?(src_url, url) }
        issues << {
          severity: BLOCKER, check: "priority_url", segment: "overall",
          message: "Priority URL missing from script sources: #{url}",
          auto_fixed: false
        }
      end
    end

    [deep_copy(script), issues]
  end

  # --- Layer 2: AI Review ---

  def run_ai_review(script)
    log("Running AI review with #{@model}")

    with_retries(max: 2, on: [Anthropic::Errors::APIError, StructuredOutputError, RuntimeError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 4096,
          system: build_review_system_prompt,
          messages: [{ role: "user", content: build_review_user_message(script) }],
          output_config: { format: ScriptReview }
        )
      end

      log_api_usage("Script review", message, elapsed)

      review = require_parsed_output!(message, ScriptReview)

      log("AI review: #{review.overall_assessment}")

      review.issues.map do |issue|
        {
          severity: issue.severity, check: issue.check,
          segment: issue.segment, message: issue.message,
          auto_fixed: false
        }
      end
    end
  end

  def build_review_system_prompt
    today = @date.strftime("%Y-%m-%d (%A)")
    prompt = <<~PROMPT
      You are a podcast script quality reviewer. Compare the script against
      the research data it was generated from and check for:

      1. FACTUAL ACCURACY: Every claim, statistic, price, date, and name in the script
         must be supported by the research data. Flag any statement that adds facts not
         present in any research summary. Be specific about what is unsupported.

      2. HALLUCINATION DETECTION: Identify fabricated content — statistics, quotes,
         events, or details that don't appear in any research finding. This is the most
         critical check.

      3. COVERAGE: Are the major findings from the research adequately covered?
         Flag significant topics that were dropped entirely.

      4. TONE: The script should be conversational and direct — like a smart, slightly
         opinionated friend explaining the news. Flag segments that are too formal,
         too breathless, or contain filler phrases.

      5. NUMBER FORMAT: Numbers should use digits ($67,500, 10 GW, 22%), not words
         (sixty-seven thousand five hundred). Flag spelled-out numbers.

      6. NATURAL FLOW: Would this sound natural read aloud by text-to-speech?
         Flag awkward phrasing, overly long sentences (>40 words), or abrupt transitions.

      Severity levels:
      - BLOCKER: Factual errors, hallucinated content, fabricated statistics
      - WARNING: Tone issues, coverage gaps, unnatural phrasing, number format violations
      - NIT: Minor style suggestions

      Be conservative with BLOCKERs — only flag something as BLOCKER if you are confident
      it is factually wrong or fabricated. Ambiguous cases should be WARNINGs.

      For reference: today's date is #{today}.

      If the script is good, return an empty issues array with a brief positive assessment.
    PROMPT

    prompt
  end

  def build_review_user_message(script)
    script_text = "SCRIPT:\nTitle: #{script[:title]}\n\n"
    script[:segments].each do |seg|
      script_text += "--- #{seg[:name]} ---\n#{seg[:text]}\n\n"
    end

    research_text = format_research(@research_data)

    "Review this podcast script against the research data.\n\n#{script_text}\nRESEARCH DATA:\n#{research_text}"
  end

  # --- Helpers ---

  def deep_copy(script)
    {
      title: script[:title].dup,
      segments: script[:segments].map { |s|
        seg = { name: s[:name].dup, text: s[:text].dup }
        seg[:sources] = s[:sources].map { |src| { title: src[:title].dup, url: src[:url].dup } } if s[:sources]
        seg
      },
      sources: (script[:sources] || []).map { |s| { title: s[:title].dup, url: s[:url].dup } }
    }
  end

  def truncate_title(title, max)
    return title if title.length <= max

    # Try dropping after last comma or dash
    [", ", " — ", " - ", " & "].each do |sep|
      idx = title.rindex(sep)
      if idx && idx > 10 && idx <= max
        candidate = title[0...idx]
        return candidate if candidate.length <= max
      end
    end

    # Word-boundary truncation
    truncated = title[0...max - 1].sub(/\s+\S*$/, "")
    truncated = title[0...max - 1] if truncated.length < 10
    "#{truncated}\u2026"
  end

  def collect_source_urls(script)
    urls = (script[:sources] || []).map { |s| s[:url] }
    script[:segments].each do |seg|
      (seg[:sources] || []).each { |s| urls << s[:url] }
    end
    urls
  end

  def urls_match?(a, b)
    normalize_url(a) == normalize_url(b)
  end

  def normalize_url(url)
    url.to_s.sub(%r{https?://}, "").sub(/\/$/, "").downcase
  end

  def format_research(research_data)
    research_data.map do |item|
      findings = item[:findings].map do |f|
        "  - #{f[:title] || "Untitled"} (#{f[:url] || "no URL"})\n    #{f[:summary] || "No summary available"}"
      end.join("\n")
      "## #{item[:topic] || "Unknown topic"}\n#{findings}"
    end.join("\n\n")
  end

  def log(msg)
    if @logger
      @logger.log("[ScriptReviewer] #{msg}")
    else
      $stderr.puts "[ScriptReviewer] #{msg}"
    end
  end
end
