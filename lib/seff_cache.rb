# frozen_string_literal: true

require "fileutils"
require "json"

module EfficiencyReporter
  # Keeps seff's reports on finished jobs, so that opening the app again only
  # runs seff on jobs it has not seen. A finished job's accounting does not
  # change, but seff might: each report is saved with seff's fingerprint (a
  # checksum of the seff program), and reports from a different seff are
  # ignored. The cache is one line of JSON per report in the user's OnDemand
  # data directory; new reports are appended, and the file is rewritten without
  # stale lines once enough of them build up.
  class SeffCache
    FILE = "seff_cache.jsonl"

    def initialize(dir)
      @dir = dir
      @path = File.join(dir, FILE)
      @lock_path = File.join(dir, "#{FILE}.lock")
    end

    attr_reader :path

    # Returns [{ job id => saved report }, number of lines in the file].
    # Only reports from the seff with this fingerprint are returned.
    def load(fingerprint)
      return [{}, 0] if fingerprint.to_s.empty? || !File.exist?(@path)

      entries = {}
      lines = 0
      with_lock(File::LOCK_SH) do
        File.foreach(@path) do |line|
          lines += 1
          entry = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          next unless entry.is_a?(Hash) && entry["id"] && entry["fp"] == fingerprint

          entries[entry["id"]] = entry
        end
      end
      [entries, lines]
    end

    def append(entries)
      return if entries.empty?

      with_lock(File::LOCK_EX) do
        File.open(@path, "a", 0o600) do |f|
          entries.each { |entry| f.write(JSON.generate(entry), "\n") }
        end
      end
    end

    # Rewrites the file with only these entries.
    def rewrite(entries)
      with_lock(File::LOCK_EX) do
        tmp = "#{@path}.#{Process.pid}.tmp"
        File.open(tmp, "w", 0o600) do |f|
          entries.each { |entry| f.write(JSON.generate(entry), "\n") }
        end
        File.rename(tmp, @path)
      end
    end

    def clear
      with_lock(File::LOCK_EX) { FileUtils.rm_f(@path) }
    end

    private

    def with_lock(mode)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(mode)
        yield
      end
    end
  end
end
