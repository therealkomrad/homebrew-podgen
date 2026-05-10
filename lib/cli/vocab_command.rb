# frozen_string_literal: true

require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "cli", "podcast_command")
require_relative File.join(root, "lib", "known_vocabulary")

module PodgenCLI
  class VocabCommand
    include PodcastCommand

    def initialize(args, options)
      @options = options
      @lang = nil

      OptionParser.new do |opts|
        opts.on("--lang CODE", "Language code (default: from config)") { |l| @lang = l }
      end.parse!(args)

      @subcommand = args.shift
      @podcast_name = args.shift
      @word = args.shift
      reject_leftover_args!(args)
    end

    def run
      case @subcommand
      when "add"    then add_word
      when "remove" then remove_word
      when "list"   then list_words
      else usage; 2
      end
    end

    private

    def add_word
      code = require_podcast!("vocab add")
      return code if code
      return missing_word("add") unless @word

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      if kv.add(lang, @word)
        puts "Added '#{@word.downcase}' to known vocabulary (#{lang})"
      else
        puts "Already known: '#{@word.downcase}' (#{lang})"
      end
      0
    end

    def remove_word
      code = require_podcast!("vocab remove")
      return code if code
      return missing_word("remove") unless @word

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      if kv.remove(lang, @word)
        puts "Removed '#{@word.downcase}' from known vocabulary (#{lang})"
      else
        puts "Not found: '#{@word.downcase}' (#{lang})"
      end
      0
    end

    def list_words
      code = require_podcast!("vocab list")
      return code if code

      load_config!
      lang = resolve_language
      return 2 unless lang

      kv = KnownVocabulary.for_config(@config)
      words = kv.lemmas(lang)

      if words.empty?
        puts "No known vocabulary words for #{lang}"
      else
        puts "Known vocabulary (#{lang}): #{words.length} words"
        words.each { |w| puts "  #{w}" }
      end
      0
    end

    def resolve_language
      lang = @lang || @config.transcription_language
      unless lang
        $stderr.puts "No language configured. Use --lang or set language in ## Audio section."
        return nil
      end
      lang
    end

    def missing_word(subcommand)
      $stderr.puts "Usage: podgen vocab #{subcommand} <podcast> <word> [--lang CODE]"
      2
    end

    def usage
      $stderr.puts "Usage: podgen vocab <add|remove|list> <podcast> [word] [--lang CODE]"
      $stderr.puts
      $stderr.puts "Subcommands:"
      $stderr.puts "  add <podcast> <word>      Add word to known vocabulary"
      $stderr.puts "  remove <podcast> <word>   Remove word from known vocabulary"
      $stderr.puts "  list <podcast>            List known vocabulary words"
      $stderr.puts
      $stderr.puts "Options:"
      $stderr.puts "  --lang CODE   Language code (default: from podcast config)"
    end
  end
end
