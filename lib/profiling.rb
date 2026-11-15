# frozen_string_literal: true

module EfficiencyReporter
  # Works out whether a job asked Slurm to profile it (--profile task), so the
  # job list can say which jobs should have a profile_plot.
  #
  # This only flags jobs for the list. Whether there is a plot is always decided
  # by running profile_plot itself when a job is opened.
  module Profiling
    OPTION = /--profile(?:=|\s+)([A-Za-z,]+)/.freeze

    module_function

    # From a submit line such as "sbatch --profile=task job.sl".
    # Returns the requested profile types ("task", "all,energy", "none") or nil.
    def from_submit_line(line)
      m = OPTION.match(line.to_s)
      m && m[1].downcase
    end

    # From the output of remote/seff.sh's "scripts" section: the
    # "Batch Script for <id>" headers of sacct --batch-script, each followed
    # by the lines of that script that mention --profile.
    # Returns { job id => profile types or nil }.
    def from_scripts(text)
      found = {}
      current = nil
      text.to_s.each_line do |line|
        if (m = line.match(/\ABatch Script for (\S+)/))
          current = m[1]
          found[current] ||= nil
        elsif current
          value = from_script_line(line)
          found[current] = [found[current], value].compact.join(",") if value
        end
      end
      found
    end

    # A #SBATCH directive, or an srun/sbatch/salloc command in the script.
    # Other comment lines are ignored, as Slurm ignores them.
    def from_script_line(line)
      text = line.strip
      return nil if text.start_with?("#") && !text.start_with?("#SBATCH")

      m = OPTION.match(text)
      m && m[1].downcase
    end

    # True when the profile types include task profiling ("task" or "all").
    def task?(types)
      types.to_s.split(",").any? { |t| %w[task all].include?(t.strip) }
    end
  end
end
