# frozen_string_literal: true

require "fileutils"

begin
  require "sqlite3"
rescue LoadError
  # Without the sqlite3 gem the app still works: it runs seff and
  # profile_plot again each time instead.
end

module EfficiencyReporter
  # What seff and profile_plot gave for finished jobs, kept in an SQLite
  # database in the user's data_dir (as Slurm Composer keeps its job history),
  # so that opening the app again does not run them again:
  #
  #   seff_reports    seff's report on each job, as printed
  #   profile_plots   the image profile_plot drew for each job
  #
  # A finished job's accounting and profile do not change, but seff and
  # profile_plot might: each row is kept with a checksum of the program that
  # made it, and rows from any other version are dropped, so a change to
  # either on the cluster shows up straight away.
  class ReportStore
    FILE = "efficiency_reporter.db"
    OLD_FILE = "seff_reports.db" # its name before profile plots were kept too

    def self.available?
      defined?(::SQLite3::Database) ? true : false
    end

    attr_reader :path

    def initialize(dir)
      @dir = dir
      @path = File.join(dir, FILE)
    end

    # ---- seff --------------------------------------------------------------

    # { job id => report } for the reports printed by the seff with this
    # checksum.
    def load_seff(seff_version)
      return {} if seff_version.to_s.empty? || !exists?

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
    def save_seff(reports)
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

    # ---- profile_plot --------------------------------------------------------

    # The saved plot for a job (by its raw ID): { "image", "type", "messages",
    # "saved_at" }, or nil.
    def load_plot(raw_id)
      return nil unless exists?

      open_db do |db|
        row = db.get_first_row("SELECT image, content_type, messages, saved_at FROM profile_plots WHERE raw_id = ?",
                               [raw_id.to_s])
        row && { "image" => row["image"].to_s.b, "type" => row["content_type"], "messages" => row["messages"],
                 "saved_at" => row["saved_at"] }
      end
    end

    def save_plot(raw_id:, job_id:, image:, type:, messages:, version:)
      open_db do |db|
        db.execute("INSERT OR REPLACE INTO profile_plots " \
                   "(raw_id, job_id, image, content_type, messages, profile_plot_version, saved_at) " \
                   "VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [raw_id.to_s, job_id.to_s, SQLite3::Blob.new(image), type.to_s, messages.to_s, version.to_s,
                    Time.now.to_i])
      end
    end

    # ---- Upkeep --------------------------------------------------------------

    # Given the whole job list, drops what is no longer needed: rows for jobs
    # that have left the list (older than history_months), and rows made by a
    # different seff or profile_plot.
    def prune(job_ids:, raw_ids:, seff_version:, plot_version:)
      return unless exists?

      open_db do |db|
        db.transaction do
          db.execute("DELETE FROM seff_reports WHERE seff_version != ?", [seff_version.to_s]) unless seff_version.to_s.empty?
          db.execute("DELETE FROM profile_plots WHERE profile_plot_version != ?", [plot_version.to_s]) unless plot_version.to_s.empty?
          delete_missing(db, "seff_reports", "job_id", job_ids)
          delete_missing(db, "profile_plots", "raw_id", raw_ids)
        end
      end
    end

    # { "seff_reports" => n, "profile_plots" => n }
    def counts
      return { "seff_reports" => 0, "profile_plots" => 0 } unless exists?

      open_db do |db|
        %w[seff_reports profile_plots].to_h { |table| [table, db.get_first_value("SELECT COUNT(*) FROM #{table}").to_i] }
      end
    end

    def clear
      return unless exists?

      open_db do |db|
        db.transaction do
          db.execute("DELETE FROM seff_reports")
          db.execute("DELETE FROM profile_plots")
        end
      end
    end

    private

    def exists?
      adopt_old_file
      File.exist?(@path)
    end

    # Keeps the seff reports saved by earlier versions of the app.
    def adopt_old_file
      old = File.join(@dir, OLD_FILE)
      File.rename(old, @path) if File.exist?(old) && !File.exist?(@path)
    rescue SystemCallError
      nil
    end

    def delete_missing(db, table, column, keep)
      keep = keep.map(&:to_s)
      gone = db.execute("SELECT #{column} FROM #{table}").map { |row| row[column] } - keep
      gone.each_slice(500) do |ids|
        db.execute("DELETE FROM #{table} WHERE #{column} IN (#{(['?'] * ids.length).join(',')})", ids)
      end
    end

    def open_db
      FileUtils.mkdir_p(@dir, mode: 0o700)
      adopt_old_file
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
        CREATE TABLE IF NOT EXISTS profile_plots (
          raw_id               TEXT PRIMARY KEY,
          job_id               TEXT NOT NULL,
          image                BLOB NOT NULL,
          content_type         TEXT NOT NULL,
          messages             TEXT,
          profile_plot_version TEXT NOT NULL,
          saved_at             INTEGER NOT NULL
        );
      SQL
      yield db
    ensure
      db&.close
    end
  end
end
