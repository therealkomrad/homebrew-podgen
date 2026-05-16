# frozen_string_literal: true

require "optparse"
require_relative "cli/version"

module PodgenCLI
  COMMANDS = {
    "generate"  => ["Run the full podcast pipeline",       "cli/generate_command",    "GenerateCommand"],
    "translate" => ["Translate episodes to new languages",  "cli/translate_command",   "TranslateCommand"],
    "render"    => ["Re-render script markdown from JSON",   "cli/render_command",      "RenderCommand"],
    "voice"     => ["Voice or re-voice an episode from JSON", "cli/voice_command",       "VoiceCommand"],
    "scrap"     => ["Remove episode and history entry",     "cli/scrap_command",       "ScrapCommand"],
    "rss"       => ["Generate RSS feed for a podcast",     "cli/rss_command",         "RssCommand"],
    "site"      => ["Generate static HTML website",        "cli/site_command",        "SiteCommand"],
    "publish"   => ["Publish to Cloudflare R2 or LingQ",    "cli/publish_command",    "PublishCommand"],
    "stats"     => ["Show podcast statistics",             "cli/stats_command",       "StatsCommand"],
    "validate"  => ["Validate podcast config and output",  "cli/validate_command",    "ValidateCommand"],
    "list"      => ["List available podcasts",             "cli/list_command",        "ListCommand"],
    "test"      => ["Run a standalone test script",        "cli/test_command",        "TestCommand"],
    "schedule"  => ["Install launchd scheduler",           "cli/schedule_command",    "ScheduleCommand"],
    "analytics" => ["Manage download analytics Worker",    "cli/analytics_command",   "AnalyticsCommand"],
    "add"       => ["Add a priority link for next episode", "cli/add_command",         "AddCommand"],
    "links"     => ["List or manage queued priority links", "cli/links_command",       "LinksCommand"],
    "vocab"     => ["Manage known vocabulary words",        "cli/vocab_command",       "VocabCommand"],
    "revocab"   => ["Re-annotate vocabulary on transcripts", "cli/revocab_command",     "RevocabCommand"],
    "reformat"  => ["Reformat transcripts with paragraph breaks", "cli/reformat_command",    "ReformatCommand"],
    "exclude"   => ["Exclude URLs from future episodes",    "cli/exclude_command",     "ExcludeCommand"],
    "cover"     => ["Generate episode cover image",          "cli/cover_command",       "CoverCommand"],
    "regen"     => ["Regenerate video / subtitles / reconciliation for an existing episode", "cli/regen_command", "RegenCommand"],
    "init"      => ["Initialize a new podcast",              "cli/init_command",        "InitCommand"],
    "fork"      => ["Fork podcast into a new namespace",    "cli/fork_command",        "ForkCommand"],
    "unpublish" => ["Remove podcast from Cloudflare R2",    "cli/unpublish_command",   "UnpublishCommand"],
    "tweet"     => ["Tweet about an episode",               "cli/tweet_command",       "TweetCommand"],
    "uploads"   => ["Per-pod regen+R2+LingQ then YT batch across pods", "cli/uploads_command", "UploadsCommand"]
  }.freeze

  def self.run(argv)
    options = { verbosity: :normal }

    global = OptionParser.new do |opts|
      opts.banner = "Usage: podgen [options] <command> [args]"
      opts.separator ""
      opts.separator "Fully autonomous podcast generation pipeline."
      opts.separator ""
      opts.separator "Commands:"
      opts.separator "  generate <podcast>             Run the full pipeline (news or language)"
      opts.separator "  translate <podcast>            Translate episodes to new languages"
      opts.separator "  render <podcast> [--date|--lang] Re-render script markdown from canonical JSON"
      opts.separator "  voice <podcast> [--date|--lang|--force] Voice/re-voice from script JSON (recover from TTS failure)"
      opts.separator "  scrap <podcast> [episode|path]  Remove episode files + history entry"
      opts.separator "  rss <podcast>                  Generate RSS feed"
      opts.separator "  site <podcast>                 Generate static HTML website"
      opts.separator "  publish <podcast>              Publish to Cloudflare R2 (--lingq for LingQ)"
      opts.separator "  stats <podcast> | --all        Show podcast statistics"
      opts.separator "  validate <podcast> | --all     Validate config and output"
      opts.separator "  list                           List available podcasts"
      opts.separator "  test <name> [args]             Run a standalone test"
      opts.separator "  schedule <podcast>             Install launchd scheduler (--time, --publish, --telegram)"
      opts.separator "  uploads <pod1,pod2,...>        Per-pod regen+R2+LingQ then YT batch (--mode, --max)"
      opts.separator "  analytics <setup|deploy|tail|status>  Manage download analytics Worker"
      opts.separator "  add <podcast> <url> [--note ...]     Queue a priority link for next episode"
      opts.separator "  links <podcast> [--remove|--clear]   List or manage queued priority links"
      opts.separator "  vocab <add|remove|list> <podcast>    Manage known vocabulary words"
      opts.separator "  revocab <podcast> [episode] [--missing-only]  Re-annotate vocabulary"
      opts.separator "  reformat <podcast> [episode]         Reformat transcripts (paragraph breaks, cleanup)"
      opts.separator "  exclude <podcast> <url> [url...]     Exclude URLs from future episodes"
      opts.separator "  cover <podcast> <title|episode-id>   Generate episode cover image"
      opts.separator "  regen <podcast> [date] [--video|--subtitles|--reconcile|--all]  Regenerate post-pipeline artifacts"
      opts.separator "  init <name> | <source> <name>      Initialize a new podcast (skeleton or from existing)"
      opts.separator "  fork <old> <new>                   Fork podcast with all content into a new namespace"
      opts.separator "  unpublish <podcast>                Remove podcast from Cloudflare R2"
      opts.separator "  tweet <podcast> <episode-id>       Tweet about an episode (--force, --dry-run)"
      opts.separator ""
      opts.separator "Pipelines (configured via ## Type in guidelines.md):"
      opts.separator "  news      Research topics, write script, TTS, assemble MP3 (default)"
      opts.separator "  language  Download from RSS, --file, or --url (YouTube), transcribe, assemble MP3"
      opts.separator ""
      opts.separator "Transcription engines (## Transcription Engine in guidelines.md):"
      opts.separator "  open      OpenAI Whisper / gpt-4o-transcribe (default)"
      opts.separator "  elab      ElevenLabs Scribe v2"
      opts.separator "  groq      Groq hosted Whisper"
      opts.separator "  List multiple engines for side-by-side comparison mode."
      opts.separator ""
      opts.separator "Tests:"
      opts.separator "  research, rss, hn, claude_web, bluesky, x, script, tts,"
      opts.separator "  assembly, translation, transcription, sources"
      opts.separator "  Example: podgen test transcription lahko_noc elab"
      opts.separator "           podgen test transcription audio.mp3 all"
      opts.separator ""
      opts.separator "Options:"

      opts.on("-v", "--verbose", "Verbose output") { options[:verbosity] = :verbose }
      opts.on("-q", "--quiet",   "Suppress terminal output (errors still shown)") { options[:verbosity] = :quiet }
      opts.on("--dry-run", "Validate config, skip API calls and file output") { options[:dry_run] = true }
      opts.on("--lingq", "Enable LingQ upload (generate) or publish to LingQ (publish)") { options[:lingq] = true }
      opts.on("-V", "--version", "Print version and exit") do
        puts "podgen #{VERSION}"
        return 0
      end
      opts.on("-h", "--help", "Show this help") do
        puts opts
        return 0
      end
    end

    begin
      global.order!(argv)
    rescue OptionParser::InvalidOption => e
      $stderr.puts "#{e.message}\n\n#{global}"
      return 2
    end

    command_name = argv.shift

    unless command_name
      puts global
      return 2
    end

    entry = COMMANDS[command_name]
    unless entry
      $stderr.puts "Unknown command: #{command_name}\n\n#{global}"
      return 2
    end

    _, require_path, class_name = entry
    require_relative require_path

    begin
      cmd = PodgenCLI.const_get(class_name).new(argv, options)
    rescue OptionParser::ParseError => e
      $stderr.puts "#{command_name}: #{e.message}"
      return 2
    end
    cmd.run
  end
end
