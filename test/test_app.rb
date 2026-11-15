# frozen_string_literal: true

# Tests for the Efficiency Reporter app.
#
#   ruby test/test_app.rb
#
# The unit tests need only Ruby (and ssh-keygen). The API tests at the end run
# the whole Sinatra app against the mock cluster in test/mock_cluster (with
# NeSI's real seff, which test/run_local.sh fetches into test/.cache), and need
# the gems in misc/Gemfile; they are skipped if either is missing.

require "minitest/autorun"
require "json"
require "tmpdir"

APP_DIR = File.expand_path("..", __dir__)
require File.join(APP_DIR, "lib/conf")
require File.join(APP_DIR, "lib/command_runner")
require File.join(APP_DIR, "lib/ssh_key")
require File.join(APP_DIR, "lib/profiling")
require File.join(APP_DIR, "lib/sacct")
require File.join(APP_DIR, "lib/seff")
require File.join(APP_DIR, "lib/seff_store")

module EfficiencyReporter
  # seff's output today (from REANNZ's GPU workshop), as seff prints it.
  SEFF_GPU = <<~TEXT
    Job ID: 1234567
    State: TIMEOUT
    Tasks: 1
    Cores: 4
    Job Wall-time:        100%  00:15:04 of 00:15:00 time limit
    Avg CPU Utilisation:   98%  00:59:20 of 01:00:16 core-walltime
    Peak Mem Utilisation:   1%  284.46 MB of 32.00 GB
    Peak GPU Utilisation:  43%
    Peak GPU Memory Util:   2%  510.00 MB of 23 GB
  TEXT

  # An older seff, from NeSI's Finding Job Efficiency page.
  SEFF_OLD = <<~TEXT
    Job ID: 1936245
    Cluster: mahuika
    User/Group: user/group
    State: COMPLETED (exit code 0)
    Cores: 1
    Tasks: 1
    Nodes: 1
    Job Wall-time: 7.67% 00:01:09 of 00:15:00 time limit
    CPU Efficiency: 98.55% 00:01:08 of 00:01:09 core-walltime
    Mem Efficiency: 10.84% 111.00 MB of 1.00 GB
  TEXT

  # Slurm's own contrib seff, for comparison.
  SEFF_SLURM = <<~TEXT
    Job ID: 12345
    Cluster: example
    User/Group: user/group
    State: COMPLETED (exit code 0)
    Cores: 1
    CPU Utilized: 00:00:01
    CPU Efficiency: 25.00% of 00:00:04 core-walltime
    Job Wall-clock time: 00:00:04
    Memory Utilized: 1.01 MB
    Memory Efficiency: 0.10% of 1.00 GB (1.00 GB/node)
  TEXT

  class SectionsTest < Minitest::Test
    # Each section holds exactly what the command printed: er_end's own
    # newline before the END marker is taken off again.
    def test_sections_with_and_without_a_final_newline
      out = "noise from .bashrc\nM:BEGIN a\nline 1\nline 2\n\nM:END a 0\nM:BEGIN b\nno newline\nM:END b 3\n"
      sections = CommandRunner.parse_sections(out, "M")
      assert_equal({ text: "line 1\nline 2\n", rc: 0 }, sections["a"])
      assert_equal({ text: "no newline", rc: 3 }, sections["b"])
    end

    def test_names_with_colons_and_unclosed_sections
      out = "M:BEGIN seff:123_4\nJob ID: 125\n\nM:END seff:123_4 1\nM:BEGIN image\nabc\n"
      sections = CommandRunner.parse_sections(out, "M")
      assert_equal 1, sections["seff:123_4"][:rc]
      assert_equal "Job ID: 125\n", sections["seff:123_4"][:text]
      assert_nil sections["image"][:rc]
    end
  end

  class SacctTest < Minitest::Test
    D = Sacct::DELIMITER

    def test_rows_and_a_submit_line_with_a_newline
      text = ["JobID#{D}JobName#{D}State#{D}SubmitLine",
              "123_4#{D}a|b#{D}CANCELLED by 999#{D}sbatch --wrap 'echo 1",
              "echo 2'",
              "130#{D}x#{D}COMPLETED#{D}sbatch x.sl"].join("\n")
      columns, rows = Sacct.parse_table(text)
      assert_equal %w[JobID JobName State SubmitLine], columns
      assert_equal 2, rows.length
      assert_equal "sbatch --wrap 'echo 1\necho 2'", rows[0]["SubmitLine"]
      assert_equal "a|b", rows[0]["JobName"]
      assert_equal "CANCELLED", Sacct.state_word(rows[0]["State"])
    end

    def test_gpus
      assert_equal [{ "type" => "a100", "count" => 2 }], Sacct.gpus("cpu=8,gres/gpu:a100=2,gres/gpu=2,mem=32G")
      assert_equal [{ "type" => "", "count" => 1 }], Sacct.gpus("cpu=8,gres/gpu=1")
      assert_equal [], Sacct.gpus("cpu=8,mem=4G")
    end

    def test_times
      assert_equal "2026-11-14T10:23:45", Sacct.time("2026-11-14T10:23:45")
      assert_nil Sacct.time("Unknown")
      assert_nil Sacct.time("None")
    end
  end

  class SeffTest < Minitest::Test
    def metrics(text)
      Seff.parse(text)["metrics"].to_h { |m| [m["kind"], m] }
    end

    def test_seff_today
      m = metrics(SEFF_GPU)
      assert_equal 100.0, m["time"]["percent"]
      assert_equal 98.0, m["cpu"]["percent"]
      assert_equal "00:59:20", m["cpu"]["used"]
      assert_equal "01:00:16", m["cpu"]["total"]
      assert_equal "284.46 MB", m["mem"]["used"]
      assert_equal "32.00 GB", m["mem"]["total"]
      assert_equal 43.0, m["gpu"]["percent"]
      assert_equal 2.0, m["gpu_mem"]["percent"]
      assert_equal "TIMEOUT", Seff.parse(SEFF_GPU)["state"]
      assert_equal "4", Seff.parse(SEFF_GPU)["info"]["Cores"]
    end

    def test_older_and_other_seffs
      old = metrics(SEFF_OLD)
      assert_in_delta 98.55, old["cpu"]["percent"]
      assert_in_delta 10.84, old["mem"]["percent"]
      assert_in_delta 7.67, old["time"]["percent"]
      slurm = metrics(SEFF_SLURM)
      assert_in_delta 25.0, slurm["cpu"]["percent"]
      assert_in_delta 0.1, slurm["mem"]["percent"]
      assert_nil slurm["time"], "Slurm's seff gives wall-clock time without a percentage"
    end

    def test_per_task_memory_detail
      line = "Peak Mem Utilisation:  21%  860.26 MB of 4.00 GB (781.25 kB to 945.24 MB in each of 2 tasks from 2 job steps)"
      m = metrics(line)["mem"]
      assert_equal "860.26 MB", m["used"]
      assert_equal "4.00 GB", m["total"]
    end

    def test_blocks_of_a_multi_job_call
      text = "#{SEFF_GPU}\n#{SEFF_OLD}\nEfficiency not available for RUNNING jobs.\n\n#{SEFF_SLURM}"
      blocks = Seff.blocks(text)
      assert_equal 4, blocks.length
      assert_equal %w[1234567], Seff.block_ids(blocks[0])
      assert_equal "Efficiency not available for RUNNING jobs.", blocks[2].strip
      assert_equal %w[12345], Seff.block_ids(blocks[3])
    end

    def test_array_ids
      block = "Job ID: 125\nArray Job ID: 123_3\nState: COMPLETED"
      assert_equal %w[123_3 125], Seff.block_ids(block)
    end
  end

  class ProfilingTest < Minitest::Test
    def test_scripts
      text = <<~TEXT
        Batch Script for 100
        #SBATCH --profile task
        Batch Script for 101
        # #SBATCH --profile task
        Batch Script for 102_3
        srun --profile=task,energy ./a.out
        Batch Script for 103
        #SBATCH --profile=None
      TEXT
      found = Profiling.from_scripts(text)
      assert_equal "task", found["100"]
      assert_nil found["101"], "a commented-out directive does not count"
      assert Profiling.task?(found["102_3"])
      refute Profiling.task?(found["103"])
      assert_equal "task", Profiling.from_submit_line("sbatch --profile=task job.sl")
      assert_nil Profiling.from_submit_line("sbatch job.sl")
    end
  end

  # Stands in for CommandRunner: replays canned output for the seff script.
  class FakeRunner
    attr_reader :calls

    def initialize(&block)
      @block = block
      @calls = []
    end

    def run(name, args, timeout: nil)
      @calls << [name, args]
      sections = @block.call(*args)
      CommandRunner::Result.new(sections: sections, stdout: "", stderr: "", exit_status: 0, timed_out: false,
                                seconds: 0.1, command: "fake")
    end
  end

  class RunnerTest < Minitest::Test
    def config
      Conf.new({ "detect_profiling" => false })
    end

    def entries(*ids)
      ids.map { |id| { "id" => id.to_s, "raw" => id.to_s, "array_id" => nil, "elapsed_s" => 60 } }
    end

    def report(id)
      "Job ID: #{id}\nState: COMPLETED\nCores: 1\nAvg CPU Utilisation:   50%  00:00:30 of 00:01:00 core-walltime"
    end

    def test_one_call_for_many_jobs
      fake = FakeRunner.new do |batch, _each, _scripts|
        { "about" => { text: "seff_fingerprint=1-2", rc: 0 },
          "seff" => { text: batch.split(",").map { |id| report(id) }.join("\n\n"), rc: 0 } }
      end
      outcome = Seff::Runner.new(fake, config).run(entries(1, 2, 3))
      assert_equal 1, fake.calls.length
      assert_equal %w[1 2 3], outcome.results.keys.sort
      assert(outcome.results.values.all? { |r| r["error"].nil? && r["fetched_at"].is_a?(Integer) && r["fp"] == "1-2" })
      assert outcome.batch_supported
    end

    def test_seff_stopping_part_way_through
      # seff reports on 1, stops in the middle of 2 and never reaches 3.
      fake = FakeRunner.new do |batch, each, _scripts|
        if batch.empty?
          each.split(",").to_h do |id|
            id == "2" ? ["seff:2", { text: "Job ID: 2\nState: FAILED", rc: 1 }] : ["seff:#{id}", { text: report(id), rc: 0 }]
          end.merge("about" => { text: "", rc: 0 }, "seff:2.stderr" => { text: "Traceback...\nKeyError: 'mem'", rc: 0 })
        else
          { "about" => { text: "", rc: 0 }, "seff" => { text: "#{report(1)}\n\nJob ID: 2\nState: FAILED", rc: 1 } }
        end
      end
      outcome = Seff::Runner.new(fake, config).run(entries(1, 2, 3))
      assert_equal 2, fake.calls.length, "the jobs after the failure are run one at a time, in one more call"
      assert_equal "2,3", fake.calls[1][1][1]
      assert_nil outcome.results["1"]["error"]
      assert_nil outcome.results["3"]["error"]
      assert_match(/KeyError: 'mem'/, outcome.results["2"]["error"])
      assert_equal "Job ID: 2\nState: FAILED", outcome.results["2"]["text"]
    end

    def test_a_seff_that_takes_one_job_at_a_time
      fake = FakeRunner.new do |batch, each, _scripts|
        if batch.empty?
          each.split(",").to_h { |id| ["seff:#{id}", { text: report(id), rc: 0 }] }.merge("about" => { text: "", rc: 0 })
        else
          { "about" => { text: "", rc: 0 }, "seff" => { text: report(batch.split(",").first), rc: 0 } }
        end
      end
      outcome = Seff::Runner.new(fake, config).run(entries(1, 2, 3, 4))
      refute outcome.batch_supported
      assert_equal %w[1 2 3 4], outcome.results.keys.sort
      assert(outcome.results.values.all? { |r| r["error"].nil? })
    end

    def test_jobs_that_ran_for_no_time_go_one_at_a_time
      fake = FakeRunner.new do |batch, each, _scripts|
        sections = { "about" => { text: "", rc: 0 } }
        sections["seff"] = { text: batch.split(",").map { |id| report(id) }.join("\n\n"), rc: 0 } unless batch.empty?
        each.split(",").each { |id| sections["seff:#{id}"] = { text: report(id), rc: 0 } }
        sections
      end
      jobs = entries(1, 2)
      jobs[1]["elapsed_s"] = 0
      Seff::Runner.new(fake, config).run(jobs)
      assert_equal ["1", "2", ""], fake.calls[0][1]
    end
  end

  class SeffStoreTest < Minitest::Test
    def setup
      skip "the sqlite3 gem is not installed" unless SeffStore.available?
      @dir = Dir.mktmpdir
      @store = SeffStore.new(File.join(@dir, "data"))
    end

    def teardown
      FileUtils.rm_rf(@dir) if @dir
    end

    def report(id, version, text = "Job ID: #{id}")
      { "id" => id, "raw" => id, "text" => text, "profile" => nil, "fp" => version, "fetched_at" => 1_700_000_000 }
    end

    def test_saves_and_loads_by_seff_version
      assert_equal({}, @store.load("v1"))
      @store.save([report("1", "v1"), report("2", "v1"), report("3", "v2")])
      @store.save([report("1", "v1", "Job ID: 1 again")])
      saved = @store.load("v1")
      assert_equal %w[1 2], saved.keys.sort
      assert_equal "Job ID: 1 again", saved["1"]["text"]
      assert_equal 1_700_000_000, saved["1"]["fetched_at"]
      assert_equal %w[3], @store.load("v2").keys
      assert_equal 3, @store.count
    end

    def test_prune_and_clear
      @store.save([report("1", "v1"), report("2", "v1"), report("3", "v2")])
      @store.prune(%w[1 3], "v1")
      assert_equal %w[1], @store.load("v1").keys, "job 2 is no longer listed; job 3 is from another seff"
      assert_equal 1, @store.count
      @store.clear
      assert_equal 0, @store.count
    end
  end

  # The SSH key set-up, which must behave as Slurm Composer's does.
  class SshKeyTest < Minitest::Test
    def setup
      skip "ssh-keygen is not installed" unless system("command -v ssh-keygen >/dev/null 2>&1")
      @home = Dir.mktmpdir
      @old_home = ENV["HOME"]
      ENV["HOME"] = @home
    end

    def teardown
      ENV["HOME"] = @old_home if @old_home
      FileUtils.rm_rf(@home) if @home
    end

    def test_makes_authorises_and_then_finds_its_own_key
      assert_equal :created, SshKey.ensure_user_key("ed25519", "opencomposer")
      ssh = File.join(@home, ".ssh")
      key = File.join(ssh, "opencomposer_ed25519")
      assert File.exist?(key)
      assert_equal 0o600, File.stat(key).mode & 0o777
      assert_includes File.read(File.join(ssh, "authorized_keys")), File.read("#{key}.pub").strip
      assert_includes File.read(File.join(ssh, "config")), "IdentityFile ~/.ssh/opencomposer_ed25519"
      assert_equal :exists, SshKey.ensure_user_key("ed25519", "opencomposer")
      assert_equal 1, File.read(File.join(ssh, "config")).scan("opencomposer_ed25519").length
    end

    def test_never_authorises_a_key_the_user_owns
      ssh = File.join(@home, ".ssh")
      FileUtils.mkdir_p(ssh)
      system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", File.join(ssh, "id_ed25519"))
      assert_equal :created, SshKey.ensure_user_key("ed25519", "opencomposer")
      refute_includes File.read(File.join(ssh, "authorized_keys")), File.read(File.join(ssh, "id_ed25519.pub")).strip
    end

    def test_only_when_asked_and_commands_go_over_ssh
      assert_equal :disabled, SshKey.ensure_access(Conf.new({ "ssh_wrapper" => "", "ensure_ssh_key" => true }))
      assert_equal :disabled, SshKey.ensure_access(Conf.new({ "ssh_wrapper" => "ssh login", "ensure_ssh_key" => false }))
      refute File.exist?(File.join(@home, ".ssh"))
    end
  end

  class ConfTest < Minitest::Test
    def test_the_site_settings
      conf = Conf.load(File.join(APP_DIR, "conf.yml.erb"))
      assert conf.remote?
      assert_equal "login.hpc.nesi.org.nz", conf.login_node
      assert conf.ensure_ssh_key?
      assert_equal "opencomposer", conf.ssh_key_name
      assert_equal "seff", conf.seff_command
      assert_equal 100, conf.seff_batch_size
    end

    def test_defaults
      conf = Conf.new({})
      refute conf.remote?
      assert_equal "profile_plot", conf.profile_plot_command
      assert_equal 3, conf.history_months
    end
  end

  # The whole Sinatra app, against the mock cluster.
  class ApiTest < Minitest::Test
    MOCK_BIN = File.join(APP_DIR, "test/mock_cluster/bin")
    NN_SEFF = ENV.fetch("ER_TEST_NN_SEFF", File.join(APP_DIR, "test/.cache/nn_seff"))

    def setup
      begin
        require "rack"
        require "rack/mock"
        require "sinatra/base"
      rescue LoadError
        skip "the gems in misc/Gemfile are not installed"
      end
      skip "NeSI's seff is not in test/.cache (run test/run_local.sh once)" unless File.exist?(NN_SEFF)
      require File.join(APP_DIR, "run")
      Sinatra::Application.set :run, false
      @data = Dir.mktmpdir
      @old_env = ENV.to_h.slice("PATH", "EFFICIENCY_REPORTER_CONF", "EFFICIENCY_REPORTER_DATA")
      ENV["PATH"] = "#{MOCK_BIN}:#{ENV['PATH']}"
      ENV["EFFICIENCY_REPORTER_CONF"] = File.join(APP_DIR, "test/conf.local.yml.erb")
      ENV["EFFICIENCY_REPORTER_DATA"] = @data
      Conf::CACHE[:path] = nil # read the settings again, with this test's data_dir
      @app = Rack::MockRequest.new(Sinatra::Application)
    end

    def teardown
      %w[PATH EFFICIENCY_REPORTER_CONF EFFICIENCY_REPORTER_DATA].each { |k| ENV[k] = @old_env[k] } if @old_env
      FileUtils.rm_rf(@data) if @data
    end

    def get_json(path)
      response = @app.get(path)
      [response.status, JSON.parse(response.body)]
    end

    def post_json(path, body)
      response = @app.post(path, input: JSON.generate(body), "CONTENT_TYPE" => "application/json")
      [response.status, JSON.parse(response.body)]
    end

    def jobs
      status, data = get_json("/api/jobs")
      assert_equal 200, status, data.inspect
      data["jobs"]
    end

    def test_page
      response = @app.get("/", "SCRIPT_NAME" => "/pun/sys/efficiency_reporter")
      assert_equal 200, response.status
      assert_includes response.body, "/pun/sys/efficiency_reporter/assets/app.js"
      assert_includes response.body, '"historyMonths":3'
    end

    def test_jobs_and_seff
      list = jobs
      assert_operator list.length, :>, 150
      byname = list.group_by { |j| j["name"] }
      assert_equal "café | naïve run", byname["café | naïve run"].first["name"]
      assert_includes byname["café | naïve run"].first.to_s, "naïve"
      assert_equal "task", byname["profile_cli"].first["profile_submit"]

      finished = list.select { |j| j["cpus"].to_i.positive? && !Sacct::ACTIVE_STATES.include?(j["state"]) }
      wanted = finished.reject { |j| j["name"] == "still_running" }.first(60)
      wanted += finished.select { |j| %w[node_glitch typo_in_script profile_me].include?(j["name"]) }
      body = { "jobs" => wanted.map { |j| j.slice("id", "raw", "array_id", "elapsed_s", "end") } }
      status, data = post_json("/api/seff", body)
      assert_equal 200, status, data.inspect
      results = data["results"]
      assert_equal wanted.map { |j| j["id"] }.sort, results.keys.sort

      glitch = results[byname["node_glitch"].first["id"]]
      assert_match(/KeyError/, glitch["error"].to_s, "seff's failure on this job is reported, not hidden")
      good = results[byname["profile_me"].first["id"]]
      assert_nil good["error"]
      assert_equal "task", good["profile"]
      assert_equal %w[cpu mem time], good["metrics"].map { |m| m["kind"] }.uniq.sort

      # The clean reports come back with the job list next time, from the
      # SQLite database, so seff does not have to run on them again.
      skip "the sqlite3 gem is not installed" unless SeffStore.available?
      assert File.exist?(File.join(@data, SeffStore::FILE))
      again = jobs.select { |j| j["seff"] }
      assert_operator again.length, :>=, 50
      refute(again.any? { |j| j["name"] == "node_glitch" }, "a failed report is not saved")
      assert_equal "task", again.find { |j| j["name"] == "profile_me" }["seff"]["profile"]

      # Forgetting them means seff runs on every job again.
      response = @app.delete("/api/reports")
      assert_equal 200, response.status
      refute(jobs.any? { |j| j.key?("seff") })
    end

    def test_one_job
      job = jobs.find { |j| j["name"] == "lammps_scaling" }
      status, data = get_json("/api/job?id=#{job['id']}&raw=#{job['raw']}")
      assert_equal 200, status, data.inspect
      assert_includes data["steps"]["columns"], "MaxRSS"
      # The job itself, then its extern, batch, 0, 1 and 2 steps.
      assert_equal 6, data["steps"]["rows"].length
      assert_match(/\AJob ID: #{job['raw']}/, data["seff"]["text"])
      assert data["script"]["available"]
      assert_includes data["script"]["text"], "srun python simulate.py"
    end

    def test_profile_plot
      list = jobs
      profiled = list.find { |j| j["name"] == "profile_me" }
      response = @app.get("/api/profile?raw=#{profiled['raw']}")
      assert_equal 200, response.status
      assert_equal "image/png", response.headers["content-type"]
      assert response.body.b.start_with?("\x89PNG".b)
      assert_includes response.headers["x-profile-plot-messages"], "rendering remotely"

      plain = list.find { |j| j["name"] == "postprocess" }
      status, data = get_json("/api/profile?raw=#{plain['raw']}")
      assert_equal 404, status
      assert_includes data["detail"], "No profile data"
    end

    def test_bad_input
      assert_equal 400, get_json("/api/job?id=1;rm%20-rf&raw=1")[0]
      assert_equal 400, get_json("/api/profile?raw=1%202")[0]
      assert_equal 415, @app.post("/api/seff", input: "{}").status
      assert_equal 404, get_json("/nope")[0]
    end
  end
end
