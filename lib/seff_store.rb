# frozen_string_literal: true

require "fileutils"

begin
  require "sqlite3"
rescue LoadError
  # Without the sqlite3 gem the app still works: it runs seff on every
  # finished job on each visit instead.
end

module EfficiencyReporter
  # seff's reports on finished jobs, kept in an SQLite database in the user's
  # data_dir (as Slurm Composer keeps its job history), so that opening the app
  # again only runs seff on jobs it has not reported on yet.
  #
  # A finished job's accounting does not change, but seff might: each report
  # is kept with a checksum of the seff program that printed it, and reports
  # from any other seff are ignored and dropped, so a change to seff on the
  # cluster shows up straight away.
  class SeffStore
    FILE = "seff_reports.db"

    def self.available?
      defined?(::SQLite3::Database) ? true : false
    end

    attr_reader :path

    def initialize(dir)
      @dir = dir
      @path = File.join(dir, FILE)
    end

    # { job id => report } for the reports printed by the seff with this
    # checksum.
    def load(seff_version)
      return {} if seff_version.to_s.empty? || !File.exist?(@path)

      open_db do |db|
        rows = db.execute("SELECT job_id, raw_id, seff, profile, saved_at FROM seff_reports WHERE seff_version = ?",
                          [seff_version])
        rows.to_h do |row|
          [row["job_id"], { "id" => row["job_id"], "raw" => row["raw_id"], "text" => row["seff"], "rc" => 0,
                            "error" => nil, "stderr" => nil, "profile" => row["profile"],
                            "fetched_at" => row["saved_at"] }]
        end
      end
    end

    # Saves reports: hashes with "id", "raw", "text", "profile", "fp" (the seff
    # checksum) and "fetched_at".
    def save(reports)
      return if reports.empty?

      open_db do |db|
        db.transaction do
          reports.each do |r|
            db.execute("INSERT OR REPLACE INTO seff_reports (job_id, raw_id, seff, profile, seff_version, saved_at) " \
                       "VALUES (?, ?, ?, ?, ?, ?)",
                       [r["id"], r["raw"].to_s, r["text"].to_s, r["profile"], r["fp"].to_s, r["fetched_at"].to_i])
          end
        end
      end
    end

    # Drops the reports from any other seff, and those on jobs no longer in
    # the list (older than history_months), so the database stays small.
    def prune(listed_ids, seff_version)
      return unless File.exist?(@path)

      open_db do |db|
        db.transaction do
          db.execute("DELETE FROM seff_reports WHERE seff_version != ?", [seff_version.to_s])
          gone = db.execute("SELECT job_id FROM seff_reports").map { |row| row["job_id"] } - listed_ids
          gone.each_slice(500) do |ids|
            db.execute("DELETE FROM seff_reports WHERE job_id IN (#{(['?'] * ids.length).join(',')})", ids)
          end
        end
      end
    end

    def count
      return 0 unless File.exist?(@path)

      open_db { |db| db.get_first_value("SELECT COUNT(*) FROM seff_reports").to_i }
    end

    def clear
      return unless File.exist?(@path)

      open_db { |db| db.execute("DELETE FROM seff_reports") }
    end

    private

    def open_db
      FileUtils.mkdir_p(@dir, mode: 0o700)
      db = SQLite3::Database.new(@path)
      db.results_as_hash = true
      # Several requests may use the database at once.
      db.busy_timeout = 10_000
      db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS seff_reports (
          job_id       TEXT PRIMARY KEY,
          raw_id       TEXT NOT NULL,
          seff         TEXT NOT NULL,
          profile      TEXT,
          seff_version TEXT NOT NULL,
          saved_at     INTEGER NOT NULL
        );
      SQL
      yield db
    ensure
      db&.close
    end
  end
end
