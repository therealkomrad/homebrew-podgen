# frozen_string_literal: true

require "open3"
require_relative "loggable"

# Creates an MP4 video from a static cover image and audio file.
# Output is YouTube-optimized: 1920x1080 HD, H.264 + AAC, faststart.
class VideoGenerator
  include Loggable

  def initialize(logger: nil)
    @logger = logger
  end

  # Generate an MP4 video from an image and audio file.
  # Returns the output path.
  def generate(audio_path, image_path, output_path)
    cmd = ffmpeg_command(image_path, audio_path, output_path)
    log("Generating video: #{output_path}")

    _, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "ffmpeg video generation failed (exit #{status.exitstatus}): #{stderr.lines.last(3).join}"
    end

    log("Video created: #{output_path} (#{format_size(File.size(output_path))})")
    output_path
  end

  private

  def ffmpeg_command(image_path, audio_path, output_path)
    [
      "ffmpeg", "-y",
      "-loop", "1", "-framerate", "1", "-i", image_path,
      "-i", audio_path,
      "-c:v", "libx264", "-tune", "stillimage", "-preset", "ultrafast",
      "-r", "1",
      "-c:a", "aac", "-b:a", "192k",
      "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black",
      "-pix_fmt", "yuv420p",
      "-shortest",
      "-movflags", "+faststart",
      output_path
    ]
  end

  def format_size(bytes)
    mb = bytes / (1024.0 * 1024)
    "#{mb.round(1)} MB"
  end
end
