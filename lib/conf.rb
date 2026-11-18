# frozen_string_literal: true

require "erb"
require "yaml"

module EfficiencyReporter
  VERSION = "1.0.0"
  APP_ROOT = File.expand_path("..", __dir__)

  # Site settings, from conf.yml.erb beside the app: YAML run through ERB
  # first, as in Slurm Composer, so values can use ENV. The environment
  # variable EFFICIENCY_REPORTER_CONF names another file (for testing). Every
  # setting has a default, so a partial file still works.
  class Conf
    DEFAULTS = {
      # Where sacct, seff and profile_plot run. ssh_wrapper is put in front of
      # each command, as in Slurm Composer; empty runs them on this host.
      "login_node" => "",
      "ssh_wrapper" => "",
      # Passwordless SSH to the login node, set up as Slurm Composer does.
      "ensure_ssh_key" => false,
      "ssh_key_type" => "ed25519",
      "ssh_key_name" => "opencomposer",
      # Where the saved seff reports are kept (an SQLite database).
      "data_dir" => nil,
      # The commands, as a user would type them.
      "commands" => { "sacct" => "sacct", "seff" => "seff", "profile_plot" => "profile_plot" },
      "extra_path" => "",
      "history_months" => 3,
      # How far back a user may pick a period to look at.
      "max_history_months" => 12,
      "seff_batch_size" => 100,
      "detect_profiling" => true,
      "command_timeout" => 120,
      "cluster_name" => "",
      "thresholds" => { "good" => 70, "warning" => 40, "serious" => 20 },
      # What unused resources cost, to rank jobs by what they wasted (as the
      # Grafana efficiency dashboard does).
      "waste" => { "currency" => "$", "cpu_hour" => 0.045, "memory_gb_hour" => 0.0065, "gpu_hour" => 2.0,
                   "free_memory_mb_per_cpu" => 1548 },
      "docs" => {
        "efficiency" => "https://docs.nesi.org.nz/Software/Profiling_and_Debugging/Finding_Job_Efficiency/",
        "profiling" => "https://docs.nesi.org.nz/Software/Profiling_and_Debugging/Slurm_Native_Profiling/",
        "scaling" => "https://docs.nesi.org.nz/Software/Profiling_and_Debugging/Job_Scaling_Ascertaining_job_dimensions/",
        "gpus" => "https://docs.nesi.org.nz/Batch_Computing/Using_GPUs/"
      }
    }.freeze

    # Rendering the ERB and parsing the YAML is only redone when the file
    # changes (as Slurm Composer's read_yaml_cached does).
    CACHE = { mutex: Mutex.new, path: nil, mtime: nil, raw: nil } # rubocop:disable Style/MutableConstant

    def self.path
      given = ENV["EFFICIENCY_REPORTER_CONF"].to_s
      given.empty? ? File.join(APP_ROOT, "conf.yml.erb") : given
    end

    def self.load(path = self.path)
      raw = CACHE[:mutex].synchronize do
        mtime = File.exist?(path) ? File.mtime(path).to_f : nil
        if CACHE[:path] != path || CACHE[:mtime] != mtime
          CACHE[:raw] = mtime ? read(path) : {}
          CACHE[:path] = path
          CACHE[:mtime] = mtime
        end
        CACHE[:raw]
      end
      new(raw, path)
    end

    def self.read(path)
      text = File.read(path)
      text = ERB.new(text, trim_mode: "-").result(binding) if path.end_with?(".erb")
      data = YAML.safe_load(text, aliases: true)
      data.is_a?(Hash) ? data : {}
    end

    attr_reader :values, :path

    def initialize(data, path = nil)
      @path = path
      @values = DEFAULTS.merge(data || {}) do |_key, default, given|
        default.is_a?(Hash) && given.is_a?(Hash) ? default.merge(given) : given
      end
    end

    def [](key)
      @values[key.to_s]
    end

    def ssh_wrapper
      @values["ssh_wrapper"].to_s.strip
    end

    def remote?
      !ssh_wrapper.empty?
    end

    # The host the commands run on, for messages: login_node, or the last
    # word of ssh_wrapper.
    def login_node
      given = @values["login_node"].to_s.strip
      given.empty? ? ssh_wrapper.split.last.to_s : given
    end

    def ensure_ssh_key?
      @values["ensure_ssh_key"] == true
    end

    def ssh_key_type
      @values["ssh_key_type"].to_s
    end

    def ssh_key_name
      @values["ssh_key_name"].to_s
    end

    def command(name)
      commands = @values["commands"].is_a?(Hash) ? @values["commands"] : {}
      value = commands[name].to_s.strip
      value.empty? ? DEFAULTS["commands"][name] : value
    end

    def data_dir
      given = @values["data_dir"].to_s.strip
      given.empty? ? File.join(Dir.home, "ondemand", "data", "sys", File.basename(APP_ROOT)) : given
    end

    def sacct_command
      command("sacct")
    end

    def seff_command
      command("seff")
    end

    def profile_plot_command
      command("profile_plot")
    end

    def extra_path
      @values["extra_path"].to_s
    end

    def history_months
      clamp_int(@values["history_months"], 1, 24, 3)
    end

    def max_history_months
      [clamp_int(@values["max_history_months"], 1, 120, 12), history_months].max
    end

    # Rates for costing unused resources: currency (a label) and numbers.
    def waste
      given = @values["waste"].is_a?(Hash) ? @values["waste"] : {}
      DEFAULTS["waste"].to_h do |key, default|
        value = given.fetch(key, default)
        [key, key == "currency" ? value.to_s : (Float(value, exception: false) || default)]
      end
    end

    def seff_batch_size
      clamp_int(@values["seff_batch_size"], 1, 500, 100)
    end

    def detect_profiling?
      @values["detect_profiling"] != false
    end

    def command_timeout
      clamp_int(@values["command_timeout"], 10, 600, 120)
    end

    def cluster_name
      @values["cluster_name"].to_s
    end

    def thresholds
      t = @values["thresholds"].is_a?(Hash) ? @values["thresholds"] : {}
      {
        "good" => t.fetch("good", 70).to_f,
        "warning" => t.fetch("warning", 40).to_f,
        "serious" => t.fetch("serious", 20).to_f
      }
    end

    def docs
      @values["docs"].is_a?(Hash) ? @values["docs"] : DEFAULTS["docs"]
    end

    private

    def clamp_int(value, min, max, default)
      Integer(value).clamp(min, max)
    rescue ArgumentError, TypeError
      default
    end
  end
end
