# frozen_string_literal: true

# Efficiency Reporter: an Open OnDemand app that shows how well a user's Slurm
# jobs used what they asked for, as reported by seff, with profile_plot's chart
# for jobs run with --profile task.
#
# It is built like Slurm Composer: a Sinatra app whose settings are in
# conf.yml.erb, which runs Slurm's commands on a login node through
# ssh_wrapper, and which sets up passwordless SSH the same way (lib/ssh_key.rb).
# Every request runs as the logged-in user (OnDemand starts a web server per
# user), so the commands see exactly what the user would see in a terminal.
#
#   GET  /               the page (views/index.erb, public/assets/app.js)
#   GET  /api/jobs       the user's jobs over the last history_months (sacct)
#   POST /api/seff       seff reports for a batch of finished jobs
#   GET  /api/job        sacct, seff and the batch script for one job
#   GET  /api/profile    profile_plot's image for one job
#   DELETE /api/reports  forget the saved seff reports
#
# seff's reports on finished jobs are kept in an SQLite database in data_dir
# (lib/seff_store.rb), as Slurm Composer keeps its job history, so opening the
# app again only runs seff on jobs it has not reported on yet.

require "sinatra"
require "sinatra/reloader" if ENV.fetch("RACK_ENV", "production") == "development"
require "date"
require "erb"
require "json"
require "time"

require_relative "lib/conf"
require_relative "lib/command_runner"
require_relative "lib/ssh_key"
require_relative "lib/profiling"
require_relative "lib/sacct"
require_relative "lib/seff"
require_relative "lib/seff_store"

set :environment, ENV.fetch("RACK_ENV", "production").to_sym
set :host_authorization, { permitted_hosts: [] } if ENV.fetch("RACK_ENV", "production") == "development"
set :erb, trim: "-"

# Behind OnDemand's nginx, TLS ends upstream and X-Forwarded-Proto says https.
before do
  request.env["rack.url_scheme"] = "https" if request.env["HTTP_X_FORWARDED_PROTO"] == "https"
end

configure :development do
  register Sinatra::Reloader
  also_reload "./lib/**/*.rb"
end

module EfficiencyReporter
  JOB_ID = /\A\d+(?:_\d+)?(?:\+\d+)?\z/.freeze
  RAW_ID = /\A\d+\z/.freeze
  MAX_JOBS_PER_SEFF_REQUEST = 500
  # A seff report is saved only once the job has been over for this long, so
  # that the last of its accounting has reached Slurm's database.
  SETTLE_SECONDS = 600
end

helpers do
  def conf
    @conf ||= EfficiencyReporter::Conf.load
  end

  # Makes sure passwordless SSH to the login node works (as Slurm Composer
  # does on every page view), then returns a runner for the remote/ scripts.
  def runner
    @ssh_key = EfficiencyReporter::SshKey.ensure_access(conf)
    EfficiencyReporter::CommandRunner.new(conf)
  end

  def json_reply(value, code = 200)
    status code
    content_type :json
    headers "cache-control" => "no-store"
    JSON.generate(value)
  end

  def command_failed(result)
    where = conf.remote? ? " on #{conf.login_node}" : ""
    json_reply({ "error" => "Could not run commands#{where}.", "detail" => result.transport_error,
                 "command" => result.command }, 502)
  end

  def sacct_time(time)
    time.strftime("%Y-%m-%dT%H:%M:%S")
  end

  def parse_json(text)
    value = JSON.parse(text.to_s)
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  # JSON that is safe inside a <script> element.
  def script_json(value)
    JSON.generate(value).gsub("</", "<\\/").gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
  end

  # A header value: printable ASCII on one line, with the lines of the
  # original joined by " | ", and not too long.
  def header_safe(text)
    text.to_s.lines.map { |line| line.gsub(/[^\x20-\x7e]+/, " ").strip }.reject(&:empty?).join(" | ")[0, 1000]
  end

  def image_type(file, bytes)
    case File.extname(file.to_s).downcase
    when ".png" then "image/png"
    when ".svg" then "image/svg+xml"
    when ".pdf" then "application/pdf"
    when ".html", ".htm" then "text/html; charset=utf-8"
    when ".json" then "application/json"
    else bytes.start_with?("\x89PNG".b) ? "image/png" : "application/octet-stream"
    end
  end

  # The saved seff reports, or nil if the sqlite3 gem is not installed.
  def store
    EfficiencyReporter::SeffStore.available? ? EfficiencyReporter::SeffStore.new(conf.data_dir) : nil
  end

  # Puts the saved seff reports on the jobs they belong to, and drops the
  # ones no longer needed.
  def attach_saved_reports(jobs, seff_version)
    return unless store

    saved = store.load(seff_version)
    jobs.each do |job|
      entry = saved[job["id"]]
      job["seff"] = EfficiencyReporter::Seff.present(entry) if entry && entry["raw"].to_s == job["raw"].to_s
    end
    store.prune(jobs.map { |job| job["id"] }, seff_version) unless seff_version.to_s.empty?
  rescue StandardError => e
    warn "[Efficiency Reporter] could not read the saved seff reports: #{e.class}: #{e.message}"
  end

  # Saves the reports that will not change: seff ran cleanly, it found the
  # numbers, and the job finished a while ago.
  def save_reports(reports, entries)
    return unless store

    ends = entries.to_h { |e| [e["id"], e["end"]] }
    settled_before = Time.now - EfficiencyReporter::SETTLE_SECONDS
    keep = reports.select do |r|
      finished = ends[r["id"]] && (Time.strptime(ends[r["id"]], "%Y-%m-%dT%H:%M:%S") rescue nil)
      r["rc"].to_i.zero? && r["error"].nil? && !r["fp"].to_s.empty? &&
        !EfficiencyReporter::Seff.parse(r["text"])["metrics"].empty? && finished && finished < settled_before
    end
    store.save(keep)
  rescue StandardError => e
    warn "[Efficiency Reporter] could not save seff reports: #{e.class}: #{e.message}"
  end

  # A job as the browser sends it to /api/seff, checked.
  def seff_entry(job)
    return nil unless job.is_a?(Hash)

    id = job["id"].to_s
    raw = job["raw"].to_s
    return nil unless id.match?(EfficiencyReporter::JOB_ID) && raw.match?(EfficiencyReporter::RAW_ID)

    array_id = job["array_id"].to_s
    {
      "id" => id,
      "raw" => raw,
      "array_id" => array_id.match?(EfficiencyReporter::RAW_ID) ? array_id : nil,
      "elapsed_s" => job["elapsed_s"].is_a?(Integer) ? job["elapsed_s"] : nil,
      "end" => EfficiencyReporter::Sacct.time(job["end"])
    }
  end

  def seff_report(result, id, raw, seff_version)
    text = result.text("seff")
    rc = result.rc("seff")
    stderr = result.text("seff.stderr").to_s
    report = { "id" => id, "raw" => raw, "text" => text.to_s.strip, "rc" => rc,
               "error" => nil, "stderr" => nil, "fetched_at" => Time.now.to_i, "fp" => seff_version }
    if text.nil?
      report["error"] = "seff did not finish (the command was stopped)."
    elsif !rc&.zero?
      report["error"] = EfficiencyReporter::Seff.error_summary(stderr, rc)
      report["stderr"] = stderr[0, 8000]
    elsif text.strip.empty?
      report["error"] = "seff printed no report for this job."
    end
    report
  end

  def batch_script(result)
    text = result.text("script").to_s
    lines = text.lines
    # Drop sacct's "Batch Script for <id>" header and its rule of dashes.
    lines.shift if lines.first&.start_with?("Batch Script for ")
    lines.shift if lines.first&.match?(/\A-+\s*\z/)
    body = lines.join
    {
      "text" => body,
      "truncated" => text.bytesize >= 262_144,
      "available" => !body.strip.empty? && body.strip != "NONE" && result.rc("script").to_i.zero?
    }
  end
end

# ---- The page -----------------------------------------------------------------

get "/" do
  # Set up SSH on the first page view, before anything needs it.
  EfficiencyReporter::SshKey.ensure_access(conf)
  @base = request.script_name.to_s
  @version = EfficiencyReporter::VERSION
  @cluster_name = conf.cluster_name
  @ui_json = script_json(
    "version" => EfficiencyReporter::VERSION,
    "historyMonths" => conf.history_months,
    "batchSize" => conf.seff_batch_size,
    "thresholds" => conf.thresholds,
    "docs" => conf.docs,
    "clusterName" => conf.cluster_name,
    "loginNode" => conf.remote? ? conf.login_node : "",
    "commands" => { "sacct" => conf.sacct_command, "seff" => conf.seff_command,
                    "profilePlot" => conf.profile_plot_command }
  )
  headers "cache-control" => "no-store"
  erb :index
end

# ---- API ------------------------------------------------------------------------

get "/api/jobs" do
  finish = Time.now
  start = (Date.today << conf.history_months).to_time
  result = runner.run("list_jobs", [sacct_time(start), sacct_time(finish)])
  return command_failed(result) if result.transport_error

  about = EfficiencyReporter::Seff.key_values(result.text("about"))
  unless result.rc("jobs")&.zero?
    detail = [result.text("jobs.stderr"), result.text("jobs")].compact.join("\n").strip
    return json_reply({ "error" => "sacct could not list your jobs.", "detail" => detail, "about" => about }, 502)
  end

  jobs = EfficiencyReporter::Sacct.parse_jobs(result.text("jobs"))
  attach_saved_reports(jobs, about["seff_fingerprint"])

  json_reply({
    "jobs" => jobs,
    "about" => about.merge(
      "login_node" => conf.remote? ? conf.login_node : "",
      "ssh_key" => @ssh_key.to_s,
      "command" => result.command,
      "seconds" => result.seconds,
      "saved_reports" => store ? store.path : "",
      "warnings" => Array(result.text("jobs.stderr")).reject { |w| w.strip.empty? }
    ),
    "range" => { "start" => sacct_time(start), "end" => sacct_time(finish) }
  })
end

post "/api/seff" do
  return json_reply({ "error" => "Send the jobs as JSON." }, 415) unless request.media_type == "application/json"

  body = parse_json(request.body&.read)
  entries = Array(body["jobs"]).first(EfficiencyReporter::MAX_JOBS_PER_SEFF_REQUEST).filter_map { |j| seff_entry(j) }
  return json_reply({ "results" => {}, "batch_supported" => true }) if entries.empty?

  outcome = EfficiencyReporter::Seff::Runner.new(runner, conf).run(entries, each_only: body["mode"] == "each")
  return json_reply({ "error" => "Could not run seff.", "detail" => outcome.transport_error }, 502) if outcome.transport_error

  save_reports(outcome.results.values, entries)
  json_reply({
    "results" => outcome.results.transform_values { |r| EfficiencyReporter::Seff.present(r) },
    "batch_supported" => outcome.batch_supported,
    "calls" => outcome.calls,
    "seconds" => outcome.seconds
  })
end

get "/api/job" do
  id = params["id"].to_s
  raw = params["raw"].to_s
  unless id.match?(EfficiencyReporter::JOB_ID) && (raw.empty? || raw.match?(EfficiencyReporter::RAW_ID))
    return json_reply({ "error" => "That is not a job ID." }, 400)
  end

  result = runner.run("job_details", [id])
  return command_failed(result) if result.transport_error

  _cols, job_rows = EfficiencyReporter::Sacct.parse_table(result.text("job"))
  step_columns, step_rows = EfficiencyReporter::Sacct.parse_table(result.text("steps"))
  job_row = job_rows.first || {}
  script = batch_script(result)
  profile = script["text"].each_line.filter_map { |line| EfficiencyReporter::Profiling.from_script_line(line) }.join(",")
  profile = EfficiencyReporter::Profiling.from_submit_line(job_row["SubmitLine"]) if profile.empty?

  seff_version = EfficiencyReporter::Seff.key_values(result.text("about"))["seff_fingerprint"].to_s
  report = seff_report(result, id, raw, seff_version)
  report["profile"] = profile
  save_reports([report], [{ "id" => id, "end" => EfficiencyReporter::Sacct.time(job_row["End"]) }])

  steps_error = result.rc("steps")&.zero? ? nil : result.text("steps.stderr").to_s.strip
  json_reply({
    "job" => job_row,
    "steps" => { "columns" => step_columns, "rows" => step_rows, "error" => steps_error },
    "seff" => EfficiencyReporter::Seff.present(report),
    "script" => script,
    "profile" => profile,
    "seconds" => result.seconds
  })
end

get "/api/profile" do
  raw = params["raw"].to_s
  return json_reply({ "error" => "That is not a job ID." }, 400) unless raw.match?(EfficiencyReporter::RAW_ID)

  result = runner.run("profile_plot", [raw], timeout: [conf.command_timeout, 180].max)
  return command_failed(result) if result.transport_error

  info = EfficiencyReporter::Seff.key_values(result.text("result"))
  stderr = result.text("stderr").to_s
  encoded = result.text("image").to_s
  if encoded.strip.empty?
    return json_reply({ "error" => "profile_plot did not produce a plot for this job.", "rc" => info["rc"],
                        "detail" => (info["error"] || stderr).to_s.strip }, 404)
  end

  bytes = encoded.unpack1("m")
  type = image_type(info["file"], bytes)
  content_type type
  headers "cache-control" => "private, max-age=600",
          "x-content-type-options" => "nosniff",
          "x-profile-plot-messages" => header_safe(stderr)
  unless type.start_with?("image/png", "image/jpeg", "image/gif", "image/webp")
    headers "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
  end
  bytes
end

delete "/api/reports" do
  store&.clear
  json_reply({ "ok" => true })
end

# Sinatra runs this for every 404, including /api/profile's own answer when
# profile_plot made no plot; that JSON answer is left as it is.
not_found do
  next if response.content_type.to_s.start_with?("application/json")

  json_reply({ "error" => "Not found" }, 404)
end

error do
  e = env["sinatra.error"]
  warn "[Efficiency Reporter] #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(8).join("\n  ")}"
  json_reply({ "error" => "Something went wrong in the app: #{e.message}" }, 500)
end
