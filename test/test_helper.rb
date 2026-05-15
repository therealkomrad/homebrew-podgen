# frozen_string_literal: true

require "bundler/setup"
require "dotenv/load"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

def skip_unless_env(*keys)
  missing = keys.reject { |k| ENV[k] && !ENV[k].empty? }
  skip "Missing env: #{missing.join(', ')}" unless missing.empty?
end

def skip_unless_command(cmd)
  skip "#{cmd} not found" unless system("which #{cmd} > /dev/null 2>&1")
end

# Reset the ambient logger between tests so a logger that points at a
# tmpdir-backed log path can't leak into the next test (which may have
# already torn down the tmpdir).
require_relative "../lib/logger"
module ResetAmbientLogger
  def before_setup
    super
    PodcastAgent.logger = nil
  end
end
Minitest::Test.include(ResetAmbientLogger)
