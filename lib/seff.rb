# frozen_string_literal: true

module EfficiencyReporter
  # Runs seff and reads what it prints. seff is the source of truth: the app
  # never works efficiency out itself. It only picks the numbers out of seff's
  # own lines so the job list can show and sort them, and it always keeps
  # seff's text exactly as printed.
  #
  # Reading is deliberately loose, so it survives changes to seff's wording.
  # Any "Label:  NN%  detail" line is a measurement, sorted into a kind by the
  # words in its label; any other "Key: value" line is a detail. Both of
  #   Avg CPU Utilisation:   98%  00:59:20 of 01:00:16 core-walltime   (seff today)
  #   CPU Efficiency: 98.55% 00:01:08 of 00:01:09 core-walltime        (older seff)
  # are read as the "cpu" measurement.
  module Seff
    JOB_ID_LINE = /^\s*Job ID:\s*(\S+)/.freeze
    METRIC = /\A\s*(?<label>[A-Za-z][^:]*?):\s+(?<percent>-?\d+(?:\.\d+)?)\s*%\s*(?<detail>.*)\z/.freeze
    FIELD = /\A\s*(?<key>[A-Za-z][^:]*?):\s*(?<value>.*)\z/.freeze
    USED_OF_TOTAL = /\A(?<used>.+?)\s+of\s+(?<total>.+?)(?:\s+(?:time limit|core-walltime))?(?:\s+\((?<note>.*)\))?\s*\z/.freeze

    module_function

    # Splits the output of one seff call, which may cover several jobs (blank
    # line between jobs), into one text block per job.
    def blocks(text)
      found = []
      text.to_s.split(/\n[ \t]*\n/).each do |part|
        next if part.strip.empty?

        if part.match?(JOB_ID_LINE) || found.empty? || !part.each_line.any? { |l| FIELD.match?(l.chomp) }
          found << part.dup
        else
          # A later part of the same job, should seff ever put a blank line
          # inside one job's report.
          found[-1] = "#{found[-1]}\n\n#{part}"
        end
      end
      found
    end

    # The job ID a block is about: "Array Job ID" (e.g. 123_4) if given, then
    # "Job ID" (the raw ID today).
    def block_ids(block)
      info = parse(block)["info"]
      [info["Array Job ID"], info["Job ID"]].compact
    end

    # Reads one job's report.
    def parse(text)
      info = {}
      metrics = []
      text.to_s.each_line do |raw|
        line = raw.chomp
        if (m = METRIC.match(line))
          metrics << metric(m[:label].strip, m[:percent].to_f, m[:detail].strip)
        elsif (m = FIELD.match(line))
          info[m[:key].strip] ||= m[:value].strip
        end
      end
      { "info" => info, "metrics" => metrics, "state" => info["State"] }
    end

    def metric(label, percent, detail)
      found = { "label" => label, "kind" => kind(label), "percent" => percent, "detail" => detail }
      if (parts = USED_OF_TOTAL.match(detail))
        found["used"] = parts[:used]
        found["total"] = parts[:total]
      end
      found
    end

    def kind(label)
      words = label.downcase
      if words.include?("gpu")
        words.include?("mem") ? "gpu_mem" : "gpu"
      elsif words.include?("wall")
        "time"
      elsif words.include?("cpu")
        "cpu"
      elsif words.include?("mem")
        "mem"
      else
        "other"
      end
    end

    # A saved or fresh result, as the browser gets it.
    def present(entry)
      parsed = parse(entry["text"])
      {
        "text" => entry["text"].to_s,
        "rc" => entry["rc"],
        "error" => entry["error"],
        "stderr" => entry["stderr"],
        "fetched_at" => entry["fetched_at"],
        "profile" => entry["profile"],
        "state" => parsed["state"],
        "info" => parsed["info"],
        "metrics" => parsed["metrics"]
      }
    end

    # "key=value" lines -> Hash.
    def key_values(text)
      text.to_s.each_line.with_object({}) do |line, h|
        key, value = line.chomp.split("=", 2)
        h[key] = value.to_s if key && !key.empty?
      end
    end

    # A short reason from seff's stderr, e.g. the last line of a traceback.
    def error_summary(stderr, rc)
      last = stderr.to_s.lines.map(&:strip).reject(&:empty?).last
      status = rc.nil? ? "seff was stopped before it finished" : "seff exited with status #{rc}"
      last ? "#{status}: #{last}" : status
    end

    # Runs seff on a set of finished jobs with as few ssh calls as possible:
    #
    # 1. One call gives seff all the jobs at once (seff reports on each job it
    #    is given, one after another), and runs it separately on any job that
    #    ran for no time at all, which seff may not be able to report on.
    # 2. If that seff exits with an error part-way through, the jobs it had
    #    already reported on are kept (except the last, which may be cut off),
    #    and seff is run on each of the rest separately, in one more call. The
    #    same happens to jobs it printed nothing for, which also covers a seff
    #    that only reports on the first job it is given.
    class Runner
      Outcome = Struct.new(:results, :batch_supported, :calls, :seconds, :fingerprint, :transport_error,
                           keyword_init: true)

      def initialize(command_runner, config)
        @command_runner = command_runner
        @config = config
      end

      # entries: [{ "id" => "123_4", "raw" => "125", "array_id" => "123", "elapsed_s" => 60 }]
      # each_only: run seff on each job separately (the browser asks for this
      # once it has learnt that seff reports on one job per call).
      def run(entries, each_only: false)
        results = {}
        calls = []
        lookup = build_lookup(entries)
        batch, each = split(entries, each_only)
        script_ids = @config.detect_profiling? ? representatives(entries).values.map { |e| e["id"] } : []

        first = call(batch, each, script_ids)
        calls << first
        if first.transport_error
          return Outcome.new(results: {}, batch_supported: !each_only, calls: 1, seconds: first.seconds,
                             fingerprint: nil, transport_error: first.transport_error)
        end

        # A checksum of the seff program, saved with each report.
        fingerprint = Seff.key_values(first.text("about"))["seff_fingerprint"].to_s
        leftovers, batch_supported = read_batch(first, batch, lookup, results)
        batch_supported = false if each_only
        each.each { |entry| results[entry["id"]] = read_each(first, entry) }

        unless leftovers.empty?
          second = call([], leftovers, [])
          calls << second
          leftovers.each do |entry|
            results[entry["id"]] =
              if second.transport_error
                failed(entry, "Could not run seff: #{second.transport_error}")
              else
                read_each(second, entry)
              end
          end
        end

        attach_profiles(results, entries, Profiling.from_scripts(first.text("scripts"))) unless script_ids.empty?
        now = Time.now.to_i
        results.each_value do |r|
          r["fetched_at"] = now
          r["fp"] = fingerprint
        end
        Outcome.new(results: results, batch_supported: batch_supported, calls: calls.length,
                    seconds: calls.sum(&:seconds).round(2), fingerprint: fingerprint, transport_error: nil)
      end

      private

      def call(batch, each, script_ids)
        @command_runner.run("seff", [batch.map { |e| e["id"] }.join(","),
                                     each.map { |e| e["id"] }.join(","),
                                     script_ids.join(",")])
      end

      # Jobs that ran for no time go to seff one at a time.
      def split(entries, each_only)
        return [[], entries] if each_only

        entries.partition { |e| e["elapsed_s"].nil? || e["elapsed_s"].to_i.positive? }
      end

      # Both the job ID as sacct shows it (123_4) and the raw ID (125) lead to
      # the entry, so a block is found whichever one seff prints.
      def build_lookup(entries)
        lookup = {}
        entries.each do |e|
          lookup[e["id"]] = e
          lookup[e["raw"]] ||= e if e["raw"]
        end
        lookup
      end

      # Reads the single seff call. Returns [jobs still to do, whether seff
      # took several job IDs].
      def read_batch(result, batch, lookup, results)
        return [[], true] if batch.empty?

        printed = {}
        Seff.blocks(result.text("seff")).each do |block|
          entry = Seff.block_ids(block).map { |id| lookup[id] }.compact.first
          next unless entry && batch.include?(entry)

          printed[entry["id"]] = block
        end

        if result.rc("seff").to_i.zero? && !result.rc("seff").nil?
          printed.each { |id, block| results[id] = ok(lookup[id], block) }
          supported = !(batch.length >= 3 && printed.length <= 1)
        else
          # seff stopped with an error. The last job it printed is re-run on
          # its own, as its report may be the one it stopped in the middle of.
          keep = printed.keys[0...-1]
          keep.each { |id| results[id] = ok(lookup[id], printed[id]) }
          supported = true
        end
        [batch.reject { |e| results.key?(e["id"]) }, supported]
      end

      def read_each(result, entry)
        section = "seff:#{entry['id']}"
        text = result.text(section)
        return failed(entry, "seff did not finish for this job (the command was stopped).") if text.nil?

        rc = result.rc(section)
        stderr = result.text("#{section}.stderr").to_s
        block = Seff.blocks(text).find { |b| Seff.block_ids(b).any? { |id| [entry["id"], entry["raw"]].include?(id) } }
        block ||= text
        if rc.to_i.zero? && !rc.nil?
          return ok(entry, block) unless block.strip.empty?

          return failed(entry, "seff printed no report for this job.", stderr)
        end

        failed(entry, Seff.error_summary(stderr, rc), stderr, block)
      end

      def ok(entry, text)
        { "id" => entry["id"], "raw" => entry["raw"], "text" => text.to_s.strip, "rc" => 0, "error" => nil, "stderr" => nil }
      end

      def failed(entry, message, stderr = nil, text = "")
        { "id" => entry["id"], "raw" => entry["raw"], "text" => text.to_s.strip, "rc" => 1,
          "error" => message, "stderr" => stderr.to_s[0, 8000] }
      end

      # One job per job array is enough to read its batch script: every task
      # of an array runs the same script.
      def representatives(entries)
        reps = {}
        entries.each do |e|
          key = e["array_id"] ? "array:#{e['array_id']}" : e["id"]
          reps[key] ||= e
        end
        reps
      end

      def attach_profiles(results, entries, found)
        reps = representatives(entries)
        entries.each do |e|
          result = results[e["id"]]
          next unless result

          rep = reps[e["array_id"] ? "array:#{e['array_id']}" : e["id"]]
          result["profile"] = found[e["id"]] || (rep && found[rep["id"]])
        end
      end
    end
  end
end
