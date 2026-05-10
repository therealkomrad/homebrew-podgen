# frozen_string_literal: true

require "open3"
require "optparse"
require "fileutils"

module PodgenCLI
  class AnalyticsCommand
    WORKER_DIR = File.expand_path("~/.podgen/analytics-worker")
    DATASET = "podgen_downloads"

    SUBCOMMANDS = %w[setup deploy tail status].freeze

    def initialize(args, options)
      @options = options
      @subcommand = args.shift
      unless args.empty?
        raise OptionParser::ParseError, "unexpected argument(s): #{args.join(' ')}"
      end
    end

    def run
      case @subcommand
      when "setup"  then setup
      when "deploy" then deploy
      when "tail"   then tail
      when "status" then status
      else
        usage
        2
      end
    end

    private

    def usage
      $stderr.puts "Usage: podgen analytics <subcommand>"
      $stderr.puts
      $stderr.puts "Subcommands:"
      $stderr.puts "  setup    Create and deploy the Cloudflare Worker for download analytics"
      $stderr.puts "  deploy   Redeploy the Worker after changes"
      $stderr.puts "  tail     Stream live Worker logs"
      $stderr.puts "  status   Check if the Worker is running"
      $stderr.puts
      $stderr.puts "The Worker intercepts MP3 downloads on your media domain and logs them"
      $stderr.puts "to Cloudflare Analytics Engine. See docs/cloudflare.md for full setup."
    end

    def setup
      unless wrangler_available?
        $stderr.puts "wrangler is not installed."
        $stderr.puts "Install with: brew install cloudflare-wrangler2"
        $stderr.puts "         or:  npm install -g wrangler"
        return 2
      end

      unless wrangler_logged_in?
        $stderr.puts "Not logged in to Cloudflare. Run: wrangler login"
        return 2
      end

      domain = prompt("Media domain (e.g. media.example.com)")
      return 2 if domain.nil? || domain.empty?

      zone = prompt("Zone name (e.g. example.com)")
      return 2 if zone.nil? || zone.empty?

      bucket = ENV["R2_BUCKET"]
      unless bucket && !bucket.empty?
        bucket = prompt("R2 bucket name")
        return 2 if bucket.nil? || bucket.empty?
      end

      puts "Creating Worker project in #{WORKER_DIR}"
      FileUtils.mkdir_p(File.join(WORKER_DIR, "src"))

      write_wrangler_toml(domain, zone, bucket)
      write_worker_js

      puts "Deploying Worker..."
      success = run_wrangler("deploy")
      return 1 unless success

      puts
      puts "Worker deployed successfully."
      puts
      puts "Next steps:"
      puts "  1. Add DNS record: Cloudflare dashboard > DNS > Records > Add record"
      puts "     Type: AAAA, Name: #{domain.split('.').first}, Content: 100::, Proxy: ON"
      puts "  2. If migrating from R2 custom domain, remove it AFTER adding DNS record:"
      puts "     R2 > #{bucket} > Settings > Custom Domains > Remove #{domain}"
      puts "  3. Verify: curl -I https://#{domain}/your_podcast/feed.xml"
      puts
      puts "Add to .env for podgen stats --downloads:"
      puts "  CLOUDFLARE_API_TOKEN=your_analytics_read_token"
      puts "  CLOUDFLARE_ACCOUNT_ID=your_account_id"
      puts
      puts "See docs/cloudflare.md for full setup details."

      0
    end

    def deploy
      unless worker_exists?
        $stderr.puts "Worker project not found at #{WORKER_DIR}"
        $stderr.puts "Run: podgen analytics setup"
        return 2
      end

      write_worker_js
      puts "Deploying Worker..."
      success = run_wrangler("deploy")
      success ? 0 : 1
    end

    def tail
      unless worker_exists?
        $stderr.puts "Worker project not found at #{WORKER_DIR}"
        $stderr.puts "Run: podgen analytics setup"
        return 2
      end

      # exec replaces the process so the user gets live streaming output
      # Strip CF_*/CLOUDFLARE_* so wrangler uses OAuth, not the analytics API token
      clean_env = WRANGLER_STRIP_VARS.to_h { |k| [k, nil] }
      Dir.chdir(WORKER_DIR) { exec(clean_env, "wrangler", "tail") }
    end

    def status
      unless worker_exists?
        puts "Worker not set up. Run: podgen analytics setup"
        return 0
      end

      toml_path = File.join(WORKER_DIR, "wrangler.toml")
      content = File.read(toml_path)

      name = content[/^name\s*=\s*"([^"]+)"/, 1] || "unknown"
      domain = content[/pattern\s*=\s*"([^"]+)"/, 1] || "unknown"
      bucket = content[/bucket_name\s*=\s*"([^"]+)"/, 1] || "unknown"

      puts "Analytics Worker"
      puts "  Project:  #{WORKER_DIR}"
      puts "  Name:     #{name}"
      puts "  Domain:   #{domain}"
      puts "  Bucket:   #{bucket}"
      puts "  Dataset:  #{DATASET}"

      0
    end

    def write_wrangler_toml(domain, zone, bucket)
      path = File.join(WORKER_DIR, "wrangler.toml")
      File.write(path, <<~TOML)
        name = "podgen-analytics"
        main = "src/index.js"
        compatibility_date = "2024-01-01"

        routes = [
          { pattern = "#{domain}/*", zone_name = "#{zone}" }
        ]

        [[r2_buckets]]
        binding = "BUCKET"
        bucket_name = "#{bucket}"

        [[analytics_engine_datasets]]
        binding = "ANALYTICS"
        dataset = "#{DATASET}"
      TOML
      puts "  wrote #{path}"
    end

    def write_worker_js
      path = File.join(WORKER_DIR, "src", "index.js")
      File.write(path, <<~'JS')
        export default {
          async fetch(request, env) {
            const url = new URL(request.url);
            const path = url.pathname;

            // Log .mp3 downloads to Analytics Engine
            if (path.endsWith(".mp3")) {
              const parts = path.split("/");
              const podcast = parts[1] || "unknown";
              const episode = parts.pop().replace(".mp3", "");

              env.ANALYTICS.writeDataPoint({
                indexes: [podcast],
                blobs: [
                  episode,
                  request.headers.get("user-agent") || "",
                  request.cf?.country || "",
                  request.headers.get("referer") || "",
                ],
                doubles: [1],
              });
            }

            // Serve the file from R2, supporting Range requests for audio seeking
            const key = path.slice(1);

            const hasRange = request.headers.has("range");
            const object = await env.BUCKET.get(key, hasRange ? { range: request.headers } : {});

            if (!object) {
              return new Response("Not Found", { status: 404 });
            }

            const headers = new Headers();
            object.writeHttpMetadata(headers);
            headers.delete("content-range");
            headers.set("etag", object.httpEtag);
            headers.set("accept-ranges", "bytes");

            const ext = path.split(".").pop();
            const types = {
              mp3: "audio/mpeg",
              xml: "application/xml; charset=utf-8",
              html: "text/html; charset=utf-8",
              css: "text/css; charset=utf-8",
              jpg: "image/jpeg",
              jpeg: "image/jpeg",
              png: "image/png",
              ico: "image/x-icon",
              svg: "image/svg+xml",
            };
            if (types[ext]) headers.set("content-type", types[ext]);

            // Short cache for feeds so podcast apps get fresh content
            if (ext === "xml") {
              headers.set("cache-control", "public, max-age=300");
            } else {
              headers.set("cache-control", "public, max-age=86400");
            }

            headers.set("access-control-allow-origin", "*");

            if (hasRange && object.range) {
              const rangeStart = object.range.offset;
              const rangeEnd = rangeStart + object.range.length - 1;
              headers.set("content-range", `bytes ${rangeStart}-${rangeEnd}/${object.size}`);
              headers.set("content-length", String(object.range.length));
              return new Response(object.body, { status: 206, headers });
            }

            headers.set("content-length", String(object.size));
            return new Response(object.body, { status: 200, headers });
          },
        };
      JS
      puts "  wrote #{path}"
    end

    def prompt(label)
      $stderr.print "#{label}: "
      $stdin.gets&.strip
    end

    def worker_exists?
      File.exist?(File.join(WORKER_DIR, "wrangler.toml"))
    end

    def wrangler_available?
      _, _, status = Open3.capture3("wrangler", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end

    def wrangler_logged_in?
      _, _, status = Open3.capture3("wrangler", "whoami")
      status.success?
    rescue Errno::ENOENT
      false
    end

    # Strip CF_*/CLOUDFLARE_* env vars so wrangler uses its OAuth login
    # instead of the analytics-read API token from .env
    WRANGLER_STRIP_VARS = %w[
      CF_API_TOKEN CF_ACCOUNT_ID
      CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
    ].freeze

    def run_wrangler(*args)
      clean_env = WRANGLER_STRIP_VARS.to_h { |k| [k, nil] }
      Dir.chdir(WORKER_DIR) do
        system(clean_env, "wrangler", *args)
      end
    end
  end
end
