# frozen_string_literal: true

require "digest"

# Holds uploaded bytes on a dedicated volume path until a read consumes them,
# so an upload is never silently lost (spec §7, §8.1). Files are named by the
# row id, so a client-supplied filename can never reach the path.
class DocumentLink::Staging
  MAX_BYTES = 25.megabytes
  READ_CHUNK = 64.kilobytes

  class TooLargeError < StandardError; end

  def self.root
    Pathname.new(ENV["SURE_DOCUMENT_STORE_DIR"].presence || "/rails/storage/document-store")
  end

  def self.write(io:, id:)
    root.mkpath
    path = root.join(id.to_s)
    bytes = 0
    File.open(path, "wb") do |file|
      while (chunk = io.read(READ_CHUNK))
        bytes += chunk.bytesize
        raise TooLargeError if bytes > MAX_BYTES
        file.write(chunk)
      end
    end
    io.rewind if io.respond_to?(:rewind)
    path.to_s
  end

  def self.open(path)
    return unless path.present?
    absolute = resolve!(path)
    return unless absolute.file?
    File.open(absolute, "rb") { |file| yield file }
  end

  def self.exists?(path)
    path.present? && resolve!(path).file?
  rescue ArgumentError
    false
  end

  def self.delete(path)
    return if path.blank?
    absolute = resolve!(path)
    File.delete(absolute) if absolute.file?
  end

  # Refuses anything outside `root` (defence in depth; ids are uuids).
  def self.resolve!(path)
    candidate = Pathname.new(path.to_s)
    candidate = root.join(candidate) unless candidate.absolute?
    raise ArgumentError, "staged path escapes the staging root" unless candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
    candidate
  end
end
