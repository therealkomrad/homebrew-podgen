# frozen_string_literal: true

require "set"
require "yaml"
require "digest"
require "anthropic"
require_relative "transcript_parser"
require_relative "transcript_renderer"
require_relative "atomic_writer"
require_relative "tell/hunspell"
require_relative "loggable"

# Aggregates vocabulary-frequency stats across all transcripts of a podcast.
#
# For each lemma found in any episode's ## Vocabulary section:
#   vocab_count — number of episodes the lemma appears in (vocabulary section)
#   body_count  — number of times the lemma OR any of its inflected forms
#                 appears in the transcript bodies
#
# Inflected forms come from three sources:
#   1. The lemma itself (downcased)
#   2. Every historical *original* surface form recorded in past vocab entries
#   3. Tell::Hunspell.expand(lemma, lang:) when the language's dictionary is
#      installed; gracefully absent otherwise
#
# Forms are cached per podcast in output/<podcast>/word_forms.yml and
# regenerated only when the lemma set or hunspell-availability changes.
class WordStats
  include TranscriptRenderer
  include Loggable

  CACHE_FILENAME = "word_forms.yml"

  Result = Struct.new(:lemma, :pos, :definition, :vocab_count, :body_count, :forms, keyword_init: true)

  def initialize(config:, logger: nil)
    @config = config
    @logger = logger
  end

  # Build vocabulary frequency stats.
  #
  # Args:
  #   top: when given, optimize by skipping hunspell expansion for lemmas
  #        unlikely to appear in the top-N. We do a fast first pass without
  #        expansion, take ≥max(3*top, 200) candidates by base count, then
  #        expand only those candidates. Lemmas outside the candidate set
  #        keep their pass-1 (undercount) body_count — fine because they
  #        won't appear in the top-N anyway.
  #        nil or 0 = expand every lemma (slow but exhaustive).
  def build(top: nil)
    transcripts = collect_transcripts
    return [] if transcripts.empty?
    progress("Read #{transcripts.length} transcript(s)")

    @working_language = resolve_working_language(transcripts)
    progress("Working language: #{@working_language}") if @working_language

    vocab_index = aggregate_vocab(transcripts)
    return [] if vocab_index.empty?
    progress("Aggregated #{vocab_index.length} unique lemma(s) from vocab sections")

    body_text = transcripts.map { |t| t[:body].to_s }.join("\n").downcase
    progress("Counting occurrences across #{body_text.length / 1024} KB of transcript text...")

    if top && top.positive? && top * 3 < vocab_index.length
      build_two_pass(vocab_index, body_text, top)
    else
      build_full(vocab_index, body_text)
    end
  end

  private

  # Single-pass: expand every lemma. Used when no --top limit is set.
  def build_full(vocab_index, body_text)
    forms_by_lemma = resolve_forms(vocab_index, vocab_index.keys)
    results = vocab_index.each_with_index.map do |(lemma, info), i|
      forms = forms_by_lemma[lemma] || [lemma]
      r = Result.new(
        lemma: lemma, pos: info[:pos], definition: info[:definition],
        vocab_count: info[:episode_count],
        body_count: count_occurrences(body_text, forms),
        forms: forms
      )
      progress_inline("counting", i + 1, vocab_index.length)
      r
    end
    progress_finish
    results
  end

  # Two-pass: count using base forms first, then expand only top candidates.
  def build_two_pass(vocab_index, body_text, top)
    base_forms_by_lemma = vocab_index.each_with_object({}) do |(lemma, info), h|
      set = Set.new
      set.add(lemma)
      info[:originals].each { |o| set.add(o) }
      h[lemma] = set.to_a
    end

    progress("Pass 1: counting base forms for #{vocab_index.length} lemma(s)")
    base_counts = {}
    vocab_index.each_with_index do |(lemma, _info), i|
      base_counts[lemma] = count_occurrences(body_text, base_forms_by_lemma[lemma])
      progress_inline("pass 1", i + 1, vocab_index.length)
    end
    progress_finish

    buffer = [top * 3, 200].max
    candidates = vocab_index.keys
                            .sort_by { |l| [-base_counts[l], -vocab_index[l][:episode_count], l] }
                            .first(buffer)
    progress("Pass 2: expanding top #{candidates.length} candidate(s)")

    forms_by_lemma = resolve_forms(vocab_index, candidates)
    candidate_set = candidates.to_set

    results = vocab_index.each_with_index.map do |(lemma, info), i|
      forms = forms_by_lemma[lemma] || base_forms_by_lemma[lemma]
      body_count = candidate_set.include?(lemma) ?
                     count_occurrences(body_text, forms) :
                     base_counts[lemma]
      r = Result.new(
        lemma: lemma, pos: info[:pos], definition: info[:definition],
        vocab_count: info[:episode_count],
        body_count: body_count,
        forms: forms
      )
      progress_inline("pass 2 count", i + 1, vocab_index.length)
      r
    end
    progress_finish
    results
  end

  def collect_transcripts
    dir = @config.episodes_dir
    return [] unless Dir.exist?(dir)

    Dir.glob(File.join(dir, "*_transcript.md")).sort.map do |path|
      parsed = TranscriptParser.parse(path)
      vocab_entries = parsed.vocabulary ? parse_vocab_entries(parsed.vocabulary) : nil
      { basename: File.basename(path, "_transcript.md"),
        body: parsed.body,
        vocab_entries: vocab_entries || {} }
    end
  end

  # Returns a hash: lemma => { pos:, definition:, episode_count:, originals: [...] }
  def aggregate_vocab(transcripts)
    index = {}
    transcripts.each do |t|
      seen_in_episode = Set.new
      t[:vocab_entries].each_value do |entry|
        lemma = entry[:lemma].to_s.downcase.strip
        next if lemma.empty?
        seen_in_episode.add(lemma)

        new_definition = pick_definition(entry)
        slot = index[lemma]
        if slot.nil?
          slot = index[lemma] = {
            pos: entry[:pos],
            definition: new_definition,
            episode_count: 0,
            originals: Set.new
          }
        elsif slot[:definition].to_s.empty? && !new_definition.to_s.empty?
          slot[:definition] = new_definition
        end

        if entry[:original]
          lemma_words = lemma.split(/\s+/)
          entry[:original].to_s.split(/,\s*/).each do |raw|
            form = raw.downcase.strip
            next if form.empty?
            # Reject originals that match a single word from a multi-word
            # lemma — typically caused by stray commas in LLM-generated
            # entries like "*ozrl, se*" (meant "*ozrl se*"). Bare "se"
            # would otherwise match every reflexive in the corpus.
            next if lemma_words.length > 1 && lemma_words.include?(form)
            slot[:originals].add(form)
          end
        end
      end
      seen_in_episode.each { |lemma| index[lemma][:episode_count] += 1 }
    end
    index
  end

  # Returns { lemma => [forms] } for the given target_lemmas. Cache hash is
  # keyed on the FULL vocab lemma set (so the cache file stays consistent
  # across two-pass and full builds), but only target lemmas are expanded.
  def resolve_forms(vocab_index, target_lemmas)
    all_lemmas = vocab_index.keys.sort
    lang = language_code
    hunspell_ok = Tell::Hunspell.supports?(lang) if lang
    cache_hash = compute_cache_hash(all_lemmas, lang, hunspell_ok)

    cache = load_cache
    if cache && cache["hash"] == cache_hash
      return cache["forms"].each_with_object({}) { |(k, v), h| h[k] = v.uniq }
    end

    if lang.nil?
      log("Warning: no transcription_language configured; using lemma + originals only")
    elsif !hunspell_ok
      log("Warning: hunspell dict for '#{lang}' not installed; body_count uses lemma + " \
          "historical surface forms only.")
      log("  Install: clone github.com/wooorm/dictionaries → " \
          "copy <lang>/index.{dic,aff} to ~/Library/Spelling/<LANG_CODE>.{dic,aff}")
    end

    progress("Generating word forms for #{target_lemmas.length} lemma(s)#{hunspell_ok ? ' (hunspell)' : ''}")
    forms = {}
    # Non-target lemmas: keep base forms (lemma + originals) without hunspell expansion.
    (all_lemmas - target_lemmas).each do |lemma|
      set = Set.new
      set.add(lemma)
      vocab_index[lemma][:originals].each { |o| set.add(o) }
      forms[lemma] = set.to_a
    end
    # Target lemmas: full expansion.
    target_lemmas.each_with_index do |lemma, i|
      set = Set.new
      set.add(lemma)
      vocab_index[lemma][:originals].each { |o| set.add(o) }
      # Hunspell expansion is only meaningful for single-word lemmas. For
      # multi-word phrases (e.g. "andare d'accordo"), hunspell falls back
      # to expanding individual tokens, which yields false matches across
      # the corpus. Skip those — surface forms cover them adequately.
      if hunspell_ok && lemma.match?(/\A\p{L}+\z/u)
        expanded = Tell::Hunspell.expand(lemma, lang: lang) || []
        expanded.each { |f| set.add(f.downcase) }
      end
      forms[lemma] = set.to_a
      progress_inline("expanding", i + 1, target_lemmas.length)
    end
    progress_finish

    save_cache(hash: cache_hash, forms: forms, language: lang, hunspell: hunspell_ok)
    forms
  end

  def language_code
    @config.respond_to?(:transcription_language) ? @config.transcription_language : nil
  end

  # Determines the working language for definition display:
  #   - latest transcript's vocab languages = candidates
  #   - if 0 or 1 candidate: no detection needed
  #   - if multiple AND old unmarked entries exist: ask Claude (cached) which
  #     language those unmarked defs are in; that's the working language
  #   - if multiple but all marked: pick the first listed
  def resolve_working_language(transcripts)
    candidates = latest_vocab_languages(transcripts)
    return nil if candidates.empty?
    return candidates.first if candidates.length == 1

    sample = unmarked_definition_sample(transcripts)
    return candidates.first if sample.nil? || sample.empty?

    detect_language_via_claude(sample, candidates) || candidates.first
  end

  def latest_vocab_languages(transcripts)
    transcripts.reverse_each do |t|
      next unless t[:vocab_entries].any?
      first_entry = t[:vocab_entries].values.first
      langs = first_entry[:languages]
      return langs if langs && langs.any?
    end
    []
  end

  def unmarked_definition_sample(transcripts)
    transcripts.each do |t|
      t[:vocab_entries].each_value do |entry|
        next if entry[:languages] && entry[:languages].any?
        def_text = entry[:definition].to_s.strip
        return def_text unless def_text.empty?
      end
    end
    nil
  end

  def detect_language_via_claude(sample, candidates)
    cache = load_cache
    detection_hash = Digest::SHA256.hexdigest([candidates.sort.join("|"), sample[0, 200]].join("\x00"))
    if cache && cache["language_detection_hash"] == detection_hash && cache["working_language"]
      return cache["working_language"]
    end

    progress("Asking Claude which of #{candidates.join('/')} the legacy definitions are in...")
    answer = ask_claude_for_language(sample, candidates)
    matched = candidates.find { |c| answer.to_s.casecmp?(c) }
    save_language_detection(detection_hash, matched) if matched
    matched
  rescue => e
    log("Warning: language detection failed: #{e.class}: #{e.message}")
    nil
  end

  def ask_claude_for_language(sample, candidates)
    client = Anthropic::Client.new
    prompt = "Which of these languages is the following text written in? " \
             "Reply with EXACTLY ONE WORD from this list, no punctuation:\n\n" \
             "#{candidates.join("\n")}\n\nText:\n#{sample[0, 500]}"
    response = client.messages.create(
      model: "claude-haiku-4-5-20251001",
      max_tokens: 30,
      messages: [{ role: "user", content: prompt }]
    )
    response.content.first.text.to_s.strip.split(/\s+/).first
  end

  def save_language_detection(detection_hash, working_language)
    existing = load_cache || {}
    existing["language_detection_hash"] = detection_hash
    existing["working_language"] = working_language
    AtomicWriter.write_yaml(cache_path, existing)
  end

  # Picks the definition for a single vocab entry honoring the working language.
  # For multi-language entries, prefers @working_language. For single-language
  # legacy entries, returns the untagged :definition (assumed to be in the
  # working language).
  def pick_definition(entry)
    defs = entry[:definitions]
    if defs && !defs.empty?
      if @working_language && defs[@working_language] && !defs[@working_language].to_s.empty?
        return defs[@working_language]
      end
      return defs.values.find { |v| !v.to_s.empty? }
    end
    entry[:definition]
  end

  def cache_path
    File.join(File.dirname(@config.episodes_dir), CACHE_FILENAME)
  end

  def load_cache
    return nil unless File.exist?(cache_path)
    YAML.safe_load(File.read(cache_path))
  rescue
    nil
  end

  def save_cache(hash:, forms:, language:, hunspell:)
    existing = load_cache || {}
    existing.merge!(
      "hash" => hash,
      "language" => language,
      "hunspell" => hunspell,
      "forms" => forms.transform_values(&:uniq)
    )
    AtomicWriter.write_yaml(cache_path, existing)
  end

  def compute_cache_hash(lemmas, lang, hunspell_ok)
    Digest::SHA256.hexdigest([lemmas.sort.join("\x00"), lang, hunspell_ok].join("|"))
  end

  def count_occurrences(text, forms)
    forms.uniq.sum do |form|
      escaped = Regexp.escape(form)
      regex = /(?<![\p{L}\p{Nd}])#{escaped}(?![\p{L}\p{Nd}])/u
      text.scan(regex).length
    end
  end

  def progress(msg)
    return unless $stderr.tty?
    $stderr.puts msg
  end

  def progress_inline(label, current, total)
    return unless $stderr.tty?
    # Only refresh on milestones to avoid flooding the terminal
    return unless current == 1 || current == total || current % progress_step(total) == 0
    pct = (current * 100.0 / total).round(1)
    $stderr.print "\r  #{label}: #{current}/#{total} (#{pct}%)"
    $stderr.flush
  end

  def progress_finish
    return unless $stderr.tty?
    $stderr.puts
  end

  def progress_step(total)
    [(total / 50.0).ceil, 1].max
  end
end
