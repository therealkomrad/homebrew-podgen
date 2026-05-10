# frozen_string_literal: true

require "optparse"
require "net/http"
require "uri"
require "json"
require "open3"

root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "podcast_command")

module PodgenCLI
  class ScheduleCommand
    include PodcastCommand

    LAUNCH_AGENTS_DIR = File.join(Dir.home, "Library", "LaunchAgents")
    LABEL_PREFIX = "com.podcastagent"
    PLIST_BUDDY = "/usr/libexec/PlistBuddy"

    attr_reader :hour, :minute

    def initialize(args, options)
      @options = options
      @hour = 6
      @minute = 0
      @publish = false
      @telegram = false
      @test = false
      @remove = false
      @status = false
      @uploads = false
      @uploads_pods = nil
      @uploads_mode = :priority
      @max = nil

      OptionParser.new do |opts|
        opts.on("--time HH:MM", "Time to run in 24h format (default: 06:00)") { |t| parse_time!(t) }
        opts.on("--publish", "Run publish after successful generate") { @publish = true }
        opts.on("--telegram", "Send Telegram alert on failure") { @telegram = true }
        opts.on("--test", "Send a test Telegram message and exit") { @test = true }
        opts.on("--remove", "Remove an installed scheduler") { @remove = true }
        opts.on("--status", "Show scheduler status") { @status = true }
        opts.on("--uploads [PODS]", "Schedule per-pod regen+R2+LingQ then YT batch (comma-sep)") do |pods|
          @uploads = true
          @uploads_pods = pods if pods && !pods.empty?
        end
        opts.on("--mode MODE", "uploads mode: priority (default) or round-robin") do |m|
          @uploads_mode = m.tr("-", "_").to_sym
        end
        opts.on("--max N", Integer, "uploads: cap TOTAL YT uploads per tick (default: no cap)") { |n| @max = n }
      end.parse!(args)

      @podcast_name = args.shift
      reject_leftover_args!(args)
    end

    def publish? = @publish
    def telegram? = @telegram
    def test? = @test
    def remove? = @remove
    def status? = @status

    def installer_args
      args = [@podcast_name, @hour.to_s, @minute.to_s]
      args << "--publish" if @publish
      args << "--telegram" if @telegram
      args
    end

    def run
      if [@remove, @status, @test].count(true) > 1
        $stderr.puts "Error: --remove, --status, and --test are mutually exclusive"
        return 1
      end

      if @uploads
        return remove_scheduler! if @remove
        return show_status       if @status
        return install_uploads!
      end

      if (@remove || @status) && (@podcast_name.nil? || @podcast_name.empty?)
        $stderr.puts "Usage: podgen schedule <podcast> #{@remove ? "--remove" : "--status"}"
        return 2
      end

      return remove_scheduler! if @remove
      return show_status       if @status
      return send_test_message if @test

      code = require_podcast!("schedule")
      return code if code

      return 1 unless valid_time?

      script_path = File.join(File.expand_path("../..", __dir__), "scripts", "install_scheduler.sh")
      exec("bash", script_path, *installer_args)
    end

    # Pure parsers on launchctl output, exposed for unit tests.
    def self.parse_last_exit_status(text)
      m = text.match(/"LastExitStatus"\s*=\s*(-?\d+);/)
      m ? m[1].to_i : nil
    end

    def self.parse_pid(text)
      m = text.match(/"PID"\s*=\s*(\d+);/)
      m ? m[1].to_i : nil
    end

    # launchctl reports raw wait(2) status, not the exit code. Decode:
    #   - 0     → 0 (success)
    #   - 256   → exit 1 (high byte is exit code: status >> 8)
    #   - 1792  → exit 7
    #   - 9     → killed by signal 9 (low byte nonzero, POSIX convention)
    #   - -15   → killed by signal 15 (legacy launchctl: negative = signal)
    # Returns Integer for normal exits, String for signal kills, nil for missing.
    def self.decode_wait_status(raw)
      return nil if raw.nil?
      return 0 if raw == 0
      return "killed (signal #{-raw})" if raw < 0
      return "killed (signal #{raw & 0x7F})" if (raw & 0xFF) != 0
      raw >> 8
    end

    private

    def label
      return "#{LABEL_PREFIX}.uploads" if @uploads
      "#{LABEL_PREFIX}.#{@podcast_name}"
    end

    def plist_path
      File.join(LAUNCH_AGENTS_DIR, "#{label}.plist")
    end

    def plist_exists?
      File.exist?(plist_path)
    end

    # --- --uploads install ---

    POD_NAME_RE = /\A[\w.-]+\z/.freeze

    def install_uploads!
      if @uploads_pods.nil? || @uploads_pods.empty?
        $stderr.puts "Usage: podgen schedule --uploads <pod1,pod2,...> [--time HH:MM] [--mode priority|round-robin] [--max N]"
        return 2
      end

      bad = @uploads_pods.split(",").map(&:strip).reject { |p| p.match?(POD_NAME_RE) }
      unless bad.empty?
        $stderr.puts "Invalid pod name(s): #{bad.join(', ')} (must match #{POD_NAME_RE.source})"
        return 2
      end

      return 1 unless valid_time?

      plist_content = build_uploads_plist
      FileUtils.mkdir_p(LAUNCH_AGENTS_DIR)

      do_launchctl_unload(plist_path) if File.exist?(plist_path)
      File.write(plist_path, plist_content)
      unless do_launchctl_load(plist_path)
        $stderr.puts "Warning: launchctl load may have failed; check #{plist_path} and `launchctl list #{label}`"
      end

      puts "uploads scheduler installed at #{format('%02d:%02d', @hour, @minute)} for: #{@uploads_pods}"
      0
    end

    def do_launchctl_load(path)
      system("launchctl", "load", path, out: File::NULL, err: File::NULL)
    end

    def build_uploads_plist
      project_dir = File.expand_path("../..", __dir__)
      mode_str = @uploads_mode.to_s.tr("_", "-")
      max_args = @max ? "    <string>--max</string>\n    <string>#{@max}</string>\n" : ""
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{label}</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>#{project_dir}/scripts/run_uploads.sh</string>
            <string>#{@uploads_pods}</string>
            <string>--mode</string>
            <string>#{mode_str}</string>
        #{max_args}  </array>
          <key>StartCalendarInterval</key>
          <dict>
            <key>Hour</key>
            <integer>#{@hour}</integer>
            <key>Minute</key>
            <integer>#{@minute}</integer>
          </dict>
          <key>StandardOutPath</key>
          <string>#{project_dir}/logs/uploads_stdout.log</string>
          <key>StandardErrorPath</key>
          <string>#{project_dir}/logs/uploads_stderr.log</string>
          <key>WorkingDirectory</key>
          <string>#{project_dir}</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
            <key>LANG</key>
            <string>en_US.UTF-8</string>
          </dict>
        </dict>
        </plist>
      PLIST
    end

    # --- --remove ---

    def remove_scheduler!
      unless plist_exists?
        $stderr.puts "No scheduler installed for #{@podcast_name}"
        return 1
      end
      do_launchctl_unload(plist_path)
      do_plist_delete(plist_path)
      puts "Scheduler removed for #{@podcast_name}"
      0
    end

    def do_launchctl_unload(path)
      system("launchctl", "unload", path, out: File::NULL, err: File::NULL)
    end

    def do_plist_delete(path)
      File.delete(path)
    end

    # --- --status ---

    def show_status
      display_name = @uploads ? "uploads" : @podcast_name

      unless plist_exists?
        puts "#{display_name}: no scheduler installed."
        return 0
      end

      output = launchctl_list_output(label)
      loaded = !output.nil?
      pid = loaded ? self.class.parse_pid(output) : nil
      mtime = log_mtime(plist_log_path)
      # launchctl reports LastExitStatus=0 by default for never-run jobs.
      # If the log file doesn't exist, treat as never-run so we don't claim
      # a successful run that didn't happen.
      raw_status = loaded && mtime ? self.class.parse_last_exit_status(output) : nil
      exit_code = self.class.decode_wait_status(raw_status)

      puts "#{display_name}:"
      puts "  scheduled:       #{format('%02d:%02d', plist_hour, plist_minute)} daily"
      if @uploads
        pods_str, mode_str, max_str = parse_uploads_args(plist_program_arguments)
        puts "  podcasts:        #{pods_str.split(',').map(&:strip).join(', ')}" if pods_str
        puts "  mode:            #{mode_str || 'priority'} (#{max_str ? "max #{max_str}" : 'no max'})"
      end
      puts "  loaded:          #{loaded ? 'yes' : 'no'}"
      puts "  running:         #{pid ? "yes (PID #{pid})" : 'no'}"
      puts "  last run:        #{format_last_run(mtime)}"
      puts "  last exit code:  #{exit_code.nil? ? 'n/a' : exit_code}"
      0
    end

    # Returns ProgramArguments as an array of strings via PlistBuddy.
    def plist_program_arguments
      out, _, status = Open3.capture3(PLIST_BUDDY, "-c", "Print :ProgramArguments", plist_path)
      return [] unless status.success?
      # PlistBuddy emits "Array {\n    val1\n    val2\n}\n" — pull the inner lines.
      out.lines[1..-2].to_a.map(&:strip).reject(&:empty?)
    end

    # ProgramArguments format: ["/bin/bash", "<run_uploads.sh>", pods, "--mode", mode, "--max", max?]
    # Returns [pods, mode, max] strings (max may be nil).
    def parse_uploads_args(args)
      pods = args[2]
      mode = nil
      max = nil
      i = 3
      while i < args.length
        case args[i]
        when "--mode" then mode = args[i + 1]; i += 2
        when "--max"  then max  = args[i + 1]; i += 2
        else i += 1
        end
      end
      [pods, mode, max]
    end

    def plist_hour
      plist_read(":StartCalendarInterval:Hour").to_i
    end

    def plist_minute
      plist_read(":StartCalendarInterval:Minute").to_i
    end

    def plist_log_path
      plist_read(":StandardOutPath")
    end

    def plist_read(key)
      out, _, status = Open3.capture3(PLIST_BUDDY, "-c", "Print #{key}", plist_path)
      status.success? ? out.strip : nil
    end

    def launchctl_list_output(label)
      out, _, status = Open3.capture3("launchctl", "list", label)
      status.success? ? out : nil
    end

    def log_mtime(path)
      return nil unless path && !path.empty? && File.exist?(path)
      File.mtime(path)
    end

    def format_last_run(mtime)
      return "never" unless mtime
      "#{mtime.strftime('%Y-%m-%d %H:%M:%S')} (#{humanize_ago(Time.now - mtime)})"
    end

    def humanize_ago(seconds)
      return "just now" if seconds < 60
      return "#{(seconds / 60).to_i}m ago" if seconds < 3600
      return "#{(seconds / 3600).to_i}h ago" if seconds < 86_400
      "#{(seconds / 86_400).to_i}d ago"
    end

    # --- --test (existing) ---

    def parse_time!(str)
      match = str.match(/\A(\d{1,2}):(\d{2})\z/)
      unless match
        @time_error = "Invalid time format: #{str} (expected HH:MM)"
        return
      end
      @hour = match[1].to_i
      @minute = match[2].to_i
    end

    def valid_time?
      if @time_error
        $stderr.puts "Error: #{@time_error}"
        return false
      end
      unless (0..23).include?(@hour) && (0..59).include?(@minute)
        $stderr.puts "Error: Invalid time format: #{format('%02d:%02d', @hour, @minute)} (hour 0-23, minute 0-59)"
        return false
      end
      true
    end

    def send_test_message
      config = load_config!
      token = ENV["TELEGRAM_BOT_TOKEN"]
      chat_id = ENV["TELEGRAM_CHAT_ID"]

      unless token && !token.empty? && chat_id && !chat_id.empty?
        $stderr.puts "Error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env"
        return 1
      end

      message = "podgen: Telegram alerts configured for `#{@podcast_name}`"
      uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
      res = Net::HTTP.post_form(uri, chat_id: chat_id, text: message, parse_mode: "Markdown")

      if res.is_a?(Net::HTTPSuccess)
        puts "Test message sent to Telegram."
        0
      else
        body = JSON.parse(res.body) rescue {}
        $stderr.puts "Telegram API error: #{res.code} — #{body['description'] || res.body}"
        1
      end
    end
  end
end
