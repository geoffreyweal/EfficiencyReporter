# frozen_string_literal: true

require "securerandom"
require "shellwords"

module EfficiencyReporter
  # Runs the scripts in remote/ as the user. As in Slurm Composer, the
  # ssh_wrapper in conf.yml.erb (e.g. "ssh login.hpc.nesi.org.nz") is put in
  # front of the command, since the OnDemand host on Mahuika is not a Slurm
  # client; with no ssh_wrapper the script runs with bash on this host.
  #
  # Each script prints its output in marked sections (see remote/common.sh).
  # Only what is inside the sections is used, so anything the user's shell
  # start-up files print on the login node does no harm.
  class CommandRunner
    REMOTE_DIR = File.expand_path("../remote", __dir__)
    MAX_OUTPUT = 128 * 1024 * 1024

    # The outcome of one script run.
    class Result
      attr_reader :sections, :stdout, :stderr, :exit_status, :seconds, :command

      def initialize(sections:, stdout:, stderr:, exit_status:, timed_out:, seconds:, command:)
        @sections = sections
        @stdout = stdout
        @stderr = stderr
        @exit_status = exit_status
        @timed_out = timed_out
        @seconds = seconds
        @command = command
      end

      def timed_out?
        @timed_out
      end

      def section?(name)
        @sections.key?(name)
      end

      # Text of a section (nil if the script did not print it).
      def text(name)
        s = @sections[name]
        s && s[:text]
      end

      # Exit status recorded at the end of a section (nil if absent).
      def rc(name)
        s = @sections[name]
        s && s[:rc]
      end

      # Set when the script did not run at all: ssh could not connect, bash
      # was missing, and so on. Nothing in the output can be used then.
      def transport_error
        return nil unless @sections.empty?

        detail = @stderr.to_s.strip
        detail = detail.lines.last(12).join.strip unless detail.empty?
        if @timed_out
          "The command did not finish within the time allowed."
        elsif detail.empty?
          "The command failed (exit status #{@exit_status.inspect}) without printing anything."
        else
          detail
        end
      end
    end

    def initialize(config)
      @config = config
    end

    # Runs remote/<name>.sh with the given arguments and returns a Result.
    def run(name, args, timeout: nil)
      mark = "@@ER#{SecureRandom.hex(8)}"
      command = command_for(compose(name, mark), args.map(&:to_s))
      started = monotonic
      begin
        stdout, stderr, status, timed_out = capture(command, timeout || @config.command_timeout)
      rescue SystemCallError => e
        # For example ssh or bash is not installed on this host.
        stdout, stderr, status, timed_out = ["", "Could not run #{command.first}: #{e.message}", nil, false]
      end
      Result.new(
        sections: self.class.parse_sections(stdout, mark),
        stdout: stdout,
        stderr: stderr,
        exit_status: status,
        timed_out: timed_out,
        seconds: (monotonic - started).round(2),
        command: display_command(command)
      )
    end

    # Splits a script's output into its marked sections:
    #   { "name" => { text: "...", rc: 0 } }
    def self.parse_sections(output, mark)
      sections = {}
      begin_prefix = "#{mark}:BEGIN "
      end_line = /\A#{Regexp.escape(mark)}:END (.+) (-?\d+)\s*\z/
      current = nil
      buffer = nil
      output.each_line do |line|
        if line.start_with?(begin_prefix)
          current = line[begin_prefix.length..].chomp
          buffer = +""
        elsif current && (m = end_line.match(line))
          # er_end printed a newline before the marker; take it off again.
          text = buffer.end_with?("\n") ? buffer[0...-1] : buffer
          sections[current] = { text: text, rc: m[2].to_i }
          current = nil
          buffer = nil
        elsif current
          buffer << line
        end
      end
      # A section the script never closed (it was killed, or timed out) is
      # kept, with no exit status, so that partial output can still be shown.
      sections[current] = { text: buffer, rc: nil } if current
      sections
    end

    private

    def compose(name, mark)
      script = File.read(File.join(REMOTE_DIR, "#{name}.sh"))
      common = File.read(File.join(REMOTE_DIR, "common.sh"))
      header = +"#!/bin/bash\n"
      header << "ER_MARK=#{Shellwords.escape(mark)}\n"
      header << "ER_PATH_EXTRA=#{Shellwords.escape(@config.extra_path)}\n"
      header << "ER_SACCT=(#{words(@config.sacct_command)})\n"
      header << "ER_SEFF=(#{words(@config.seff_command)})\n"
      header << "ER_PROFILE_PLOT=(#{words(@config.profile_plot_command)})\n"
      "#{header}#{common}\n#{script}\ner_main \"$@\" </dev/null\n"
    end

    def words(command)
      Shellwords.split(command).map { |word| Shellwords.escape(word) }.join(" ")
    end

    def command_for(script, args)
      return ["bash", "-c", script, "efficiency-reporter", *args] unless @config.remote?

      # The script goes over as base64, so the only thing the remote login
      # shell has to parse is a simple pipeline. That works whatever the user's
      # shell is, and nothing in the script needs quoting for it. The wrapper
      # is split into words here and run directly, without a local shell.
      encoded = [script].pack("m0")
      quoted_args = args.map { |a| Shellwords.escape(a) }.join(" ")
      remote = "echo #{encoded} | base64 -d | bash -s -- #{quoted_args}"
      [*Shellwords.split(@config.ssh_wrapper), remote]
    end

    # The command as shown in diagnostics: the script itself is replaced by a
    # placeholder.
    def display_command(command)
      if @config.remote?
        command[0...-1].join(" ") + " '<script>'"
      else
        "bash -c '<script>' #{command[4..].join(' ')}"
      end
    end

    # Runs a command with a time limit. Returns [stdout, stderr, exit status,
    # timed out?]. The command gets its own process group so that ssh and
    # everything it started can be stopped together.
    def capture(command, timeout)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(*command, in: File::NULL, out: out_w, err: err_w, pgroup: true)
      out_w.close
      err_w.close
      stdout = String.new(encoding: Encoding::BINARY)
      stderr = String.new(encoding: Encoding::BINARY)
      open = { out_r => stdout, err_r => stderr }
      deadline = monotonic + timeout
      timed_out = false

      until open.empty?
        left = deadline - monotonic
        if left <= 0
          timed_out = true
          break
        end
        ready, = IO.select(open.keys, nil, nil, left)
        next unless ready

        ready.each do |io|
          begin
            open[io] << io.read_nonblock(65_536)
          rescue IO::WaitReadable
            next
          rescue EOFError
            open.delete(io)
          end
        end
        if stdout.bytesize + stderr.bytesize > MAX_OUTPUT
          timed_out = true
          break
        end
      end

      status = timed_out ? stop(pid) : Process.wait2(pid)[1]
      [utf8(stdout), utf8(stderr), status&.exitstatus, timed_out]
    ensure
      [out_r, out_w, err_r, err_w].each { |io| io.close unless io.nil? || io.closed? }
    end

    # Stops a command that ran too long: TERM to its process group, then KILL
    # if it is still there after two seconds. Returns its Process::Status.
    def stop(pid)
      signal_group("TERM", pid)
      20.times do
        reaped = Process.wait2(pid, Process::WNOHANG)
        return reaped[1] if reaped

        sleep 0.1
      end
      signal_group("KILL", pid)
      Process.wait2(pid)[1]
    rescue Errno::ECHILD
      nil
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def utf8(bytes)
      bytes.force_encoding(Encoding::UTF_8).scrub("?")
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
