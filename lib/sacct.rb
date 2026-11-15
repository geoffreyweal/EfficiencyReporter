# frozen_string_literal: true

module EfficiencyReporter
  # Reads sacct's --parsable2 output (with its header line) as written by the
  # scripts in remote/, which separate fields with the ASCII unit separator.
  module Sacct
    DELIMITER = "\x1f"

    # States in which a job has not finished yet, so seff has nothing to say.
    ACTIVE_STATES = %w[
      PENDING RUNNING REQUEUED REQUEUE_FED REQUEUE_HOLD RESIZING SUSPENDED
      COMPLETING CONFIGURING STAGE_OUT SIGNALING SPECIAL_EXIT STOPPED
    ].freeze

    module_function

    # Returns [columns, rows], each row a Hash of column => value.
    def parse_table(text)
      lines = text.to_s.split("\n")
      header = lines.shift
      return [[], []] if header.nil? || header.strip.empty?

      columns = header.split(DELIMITER, -1).map(&:strip)
      rows = []
      lines.each do |line|
        cells = line.split(DELIMITER, -1)
        if cells.length < columns.length && !rows.empty?
          # The rest of a value that held a newline (only SubmitLine can, and
          # it is the last column).
          last = columns.last
          rows.last[last] = "#{rows.last[last]}\n#{line}"
          next
        end
        next if line.strip.empty?

        if cells.length > columns.length
          cells = cells[0...(columns.length - 1)] + [cells[(columns.length - 1)..].join(DELIMITER)]
        end
        rows << columns.zip(cells).to_h
      end
      [columns, rows]
    end

    # The jobs from list_jobs.sh, as the browser gets them.
    def parse_jobs(text)
      _columns, rows = parse_table(text)
      rows.map { |row| job_from_row(row) }
    end

    def job_from_row(row)
      id = row["JobID"].to_s.strip
      state_detail = row["State"].to_s.strip
      {
        "id" => id,
        "raw" => presence(row["JobIDRaw"]) || id,
        "array_id" => id[/\A(\d+)_/, 1],
        "name" => row["JobName"].to_s,
        "state" => state_word(state_detail),
        "state_detail" => state_detail,
        "partition" => row["Partition"].to_s,
        "account" => row["Account"].to_s,
        "qos" => row["QOS"].to_s,
        "cpus" => integer(row["AllocCPUS"]),
        "gpus" => gpus(row["AllocTRES"]),
        "req_mem" => row["ReqMem"].to_s,
        "nodes" => integer(row["NNodes"]),
        "submit" => time(row["Submit"]),
        "start" => time(row["Start"]),
        "end" => time(row["End"]),
        "elapsed" => row["Elapsed"].to_s,
        "elapsed_s" => integer(row["ElapsedRaw"]),
        "timelimit" => row["Timelimit"].to_s,
        "exit_code" => row["ExitCode"].to_s,
        "profile_submit" => Profiling.from_submit_line(row["SubmitLine"])
      }
    end

    # "CANCELLED by 12345" -> "CANCELLED"
    def state_word(state)
      state.to_s.strip.split(/\s+/).first.to_s.upcase
    end

    def active?(state)
      ACTIVE_STATES.include?(state_word(state))
    end

    # GPUs from AllocTRES, e.g. "cpu=8,gres/gpu:a100=2,gres/gpu=2,mem=32G"
    # -> [{"type" => "a100", "count" => 2}]. An untyped count is kept only
    # when no typed one is given.
    def gpus(tres)
      typed = []
      untyped = 0
      tres.to_s.split(",").each do |item|
        key, value = item.split("=", 2)
        next unless key && value

        if (m = key.match(%r{\Agres/gpu:([^:]+)\z}))
          typed << { "type" => m[1], "count" => value.to_i }
        elsif key == "gres/gpu"
          untyped = value.to_i
        end
      end
      return typed unless typed.empty?

      untyped.positive? ? [{ "type" => "", "count" => untyped }] : []
    end

    def time(value)
      value = value.to_s.strip
      value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\z/) ? value : nil
    end

    def integer(value)
      Integer(value.to_s.strip, 10)
    rescue ArgumentError
      nil
    end

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
