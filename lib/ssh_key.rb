# frozen_string_literal: true

require "fileutils"
require "open3"

module EfficiencyReporter
  # Passwordless SSH to the login node, set up the same way as Slurm Composer
  # (its ensure_ssh_access and ensure_user_ssh_key), with the same settings in
  # conf.yml.erb: ensure_ssh_key, ssh_key_type and ssh_key_name. With the same
  # key name ("opencomposer"), the two apps share one key.
  #
  # Home directories are shared between the OnDemand host and the login nodes,
  # so a key added to ~/.ssh/authorized_keys here is authorised there. If the
  # user already has a key that is in authorized_keys, nothing is done.
  # Otherwise a passphrase-less key of the app's own is made
  # (~/.ssh/<ssh_key_name>_<ssh_key_type>), authorised, and an IdentityFile line
  # for it is added to ~/.ssh/config so that ssh offers it. A key the user
  # already owns is never authorised on their behalf.
  module SshKey
    # Per-process memo of the check, keyed by user. Only successes are kept,
    # so a failure is tried again on the next request.
    STATE = {} # rubocop:disable Style/MutableConstant
    MUTEX = Mutex.new

    module_function

    # Returns :disabled, :exists, :authorized, :created or :failed.
    def ensure_access(conf)
      return :disabled unless conf.remote? && conf.ensure_ssh_key?

      user = ENV["USER"].to_s
      MUTEX.synchronize do
        return STATE[user] if STATE.key?(user) && still_valid?

        result = begin
          ensure_user_key(conf.ssh_key_type, conf.ssh_key_name)
        rescue StandardError => e
          warn "[Efficiency Reporter] SSH key setup failed for #{user}: #{e.class}: #{e.message}"
          :failed
        end
        STATE[user] = result unless result == :failed
        result
      end
    end

    # A remembered result is trusted only while the files it stands for are
    # still there, so a wiped ~/.ssh is set up again without a restart.
    def still_valid?
      ssh_dir = File.join(Dir.home, ".ssh")
      File.directory?(ssh_dir) && File.exist?(File.join(ssh_dir, "authorized_keys"))
    end

    def ensure_user_key(key_type = "ed25519", key_name = "opencomposer")
      ssh_dir = File.join(Dir.home, ".ssh")
      FileUtils.mkdir_p(ssh_dir)
      File.chmod(0o700, ssh_dir)

      key_type = "ed25519" unless %w[ed25519 rsa ecdsa].include?(key_type.to_s)
      key_name = key_name.to_s.gsub(/[^A-Za-z0-9_.-]/, "")
      key_name = "opencomposer" if key_name.empty?
      base = "#{key_name}_#{key_type}"

      auth = File.join(ssh_dir, "authorized_keys")
      authorized = File.exist?(auth) ? File.read(auth) : ""

      # Having a key is not the same as having a usable one: it must also be
      # in authorized_keys.
      candidates = (%w[id_ed25519 id_rsa id_ecdsa id_dsa] +
                    %w[ed25519 rsa ecdsa dsa].map { |t| "#{key_name}_#{t}" })
                   .map { |k| File.join(ssh_dir, k) }
                   .select { |k| File.exist?(k) }
      usable = candidates.find do |k|
        pub = public_key_for(k)
        pub && !pub.empty? && authorized.include?(pub)
      end
      return :exists if usable

      key_path = File.join(ssh_dir, base)
      result = File.exist?(key_path) ? :authorized : :created
      unless File.exist?(key_path)
        args = ["ssh-keygen", "-t", key_type, "-N", "", "-f", key_path, "-C", "Open OnDemand auto-generated key"]
        args += ["-b", "4096"] if key_type == "rsa"
        _out, _err, status = Open3.capture3(*args)
        return :failed unless status.success? && File.exist?(key_path)
      end

      File.chmod(0o600, key_path)
      File.chmod(0o644, "#{key_path}.pub") if File.exist?("#{key_path}.pub")

      pub = public_key_for(key_path)
      return :failed if pub.nil? || pub.empty?

      File.open(auth, "a") { |f| f.puts(pub) } unless authorized.include?(pub)
      File.chmod(0o600, auth) if File.exist?(auth)

      # ssh only offers id_* keys by itself, so point it at this one.
      cfg = File.join(ssh_dir, "config")
      unless File.exist?(cfg) && File.read(cfg).include?(base)
        File.open(cfg, "a") do |f|
          f.write("\n# Added by Open OnDemand so ssh offers its auto-generated key\nHost *\n    IdentityFile ~/.ssh/#{base}\n")
        end
      end
      File.chmod(0o600, cfg) if File.exist?(cfg)
      result
    end

    # The public half of a private key: the .pub beside it, else derived with
    # ssh-keygen -y. nil for a key with a passphrase, which ssh could not use
    # unattended anyway, or a key that cannot be read.
    def public_key_for(key_path)
      pub_path = "#{key_path}.pub"
      return File.read(pub_path).strip if File.exist?(pub_path)

      out, _err, status = Open3.capture3("ssh-keygen", "-y", "-P", "", "-f", key_path)
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end
  end
end
