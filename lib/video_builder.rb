# frozen_string_literal: true

require_relative "video_generator"

# Shared runner for the "render <mp3> + <cover> into <mp4>" step.
# Used by youtube_publisher's upload loop and `podgen regen --video`.
#
# Pure value: returns a Result describing what happened (or didn't) and
# leaves printing/logging to the caller.
module VideoBuilder
  # status values:
  #   :built       — VideoGenerator ran, mp4 written
  #   :exists      — mp4 already present and force is false
  #   :no_cover    — cover_path was nil or did not point to an existing file
  #   :no_audio    — mp3_path did not exist
  #   :failed      — VideoGenerator raised; message holds the cause
  Result = Struct.new(:status, :video_path, :message, keyword_init: true)

  module_function

  def build(mp3_path:, cover_path:, video_path:, force: false, logger: nil)
    return Result.new(status: :no_audio, message: "no audio at #{mp3_path}") unless File.exist?(mp3_path)

    if File.exist?(video_path) && !force
      return Result.new(status: :exists, video_path: video_path, message: "mp4 already exists")
    end

    if cover_path.nil? || !File.exist?(cover_path)
      return Result.new(status: :no_cover, message: "no cover image#{cover_path ? " at #{cover_path}" : ""}")
    end

    VideoGenerator.new(logger: logger).generate(mp3_path, cover_path, video_path)
    Result.new(status: :built, video_path: video_path, message: "mp4 built")
  rescue => e
    Result.new(status: :failed, message: e.message)
  end
end
