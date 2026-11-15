# Helpers shared by the Efficiency Reporter remote scripts.
#
# The app runs each script in remote/ as the user, on a login node through
# ssh_wrapper (or on the OnDemand host itself when there is no ssh_wrapper).
# Before this file it puts a few variables, taken from conf.yml.erb:
#
#   ER_MARK           marker that fences each section of output (random per run)
#   ER_PATH_EXTRA     directories to add to the end of PATH (e.g. /opt/nesi/bin)
#   ER_SACCT          the sacct command, as a bash array
#   ER_SEFF           the seff command, as a bash array
#   ER_PROFILE_PLOT   the profile_plot command, as a bash array
#
# and after the script it calls er_main with the arguments, with stdin from
# /dev/null so that nothing the script runs can read the script itself.
#
# Everything the app needs is printed in sections:
#
#   <ER_MARK>:BEGIN <name>
#   ...whatever the command printed...
#   <ER_MARK>:END <name> <exit status>
#
# so that anything the user's shell start-up files print is ignored, and each
# command's output, stderr and exit status reach the app separately.

if [ -n "${ER_PATH_EXTRA:-}" ]; then
  PATH="${PATH:+$PATH:}$ER_PATH_EXTRA"
  export PATH
fi

# Field separator for sacct --parsable2. The ASCII unit separator cannot appear
# in a job name, a path or a submit line, unlike sacct's default "|".
ER_DELIM=$'\x1f'

# Every temporary file a script makes goes in this one directory, which is
# removed however the script ends: when it finishes, or when it is stopped
# part-way (the app's time limit, a dropped connection, the app's web server
# being restarted), so nothing is left behind in /tmp on the login node.
ER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/efficiency_reporter.XXXXXX" 2>/dev/null) || ER_TMP=""

er_cleanup() {
  if [ -n "$ER_TMP" ]; then
    rm -rf "$ER_TMP"
  fi
}

trap er_cleanup EXIT
# These signals end the script through exit, so that the EXIT trap runs.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 141' PIPE
trap 'exit 143' TERM

er_begin() {
  printf '%s:BEGIN %s\n' "$ER_MARK" "$1"
}

er_end() {
  # The leading newline puts the marker on a line of its own even when the
  # output did not end with one. The app removes it again.
  printf '\n%s:END %s %s\n' "$ER_MARK" "$1" "$2"
}

# er_run NAME COMMAND [ARGUMENT...]
# Runs COMMAND. Its stdout goes in section NAME and, if it wrote any, its
# stderr in section NAME.stderr. Returns the command's exit status.
er_run() {
  local name=$1 errfile="" rc
  shift
  if [ -n "$ER_TMP" ]; then
    errfile=$(mktemp "$ER_TMP/stderr.XXXXXX" 2>/dev/null) || errfile=""
  fi
  er_begin "$name"
  if [ -n "$errfile" ]; then
    "$@" 2>"$errfile"
  else
    "$@" 2>/dev/null
  fi
  rc=$?
  er_end "$name" "$rc"
  if [ -n "$errfile" ]; then
    if [ -s "$errfile" ]; then
      er_begin "$name.stderr"
      cat "$errfile"
      er_end "$name.stderr" 0
    fi
    rm -f "$errfile"
  fi
  return "$rc"
}

# er_sacct_fields FIELD...
# Prints, comma-separated, those FIELDs this sacct knows about, so that a field
# a Slurm upgrade renames or drops cannot break the whole query. If sacct cannot
# list its fields, all of them are printed and sacct is left to complain.
er_sacct_fields() {
  local known field lower out=""
  known=$("${ER_SACCT[@]}" --helpformat 2>/dev/null | tr -s ' \t' '\n\n' | tr '[:upper:]' '[:lower:]')
  for field in "$@"; do
    lower=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')
    if [ -z "$known" ] || printf '%s\n' "$known" | grep -qxF "$lower"; then
      out="$out,$field"
    fi
  done
  printf '%s' "${out#,}"
}

# er_fingerprint COMMAND
# Prints a checksum of the file that COMMAND runs. The app keeps the seff
# reports it has saved only while this stays the same, so that a change to
# seff on the cluster shows up straight away.
er_fingerprint() {
  local path
  path=$(command -v "$1" 2>/dev/null) || return 0
  case $path in
    /*) ;;
    *) return 0 ;;
  esac
  path=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
  if [ -f "$path" ]; then
    cksum <"$path" 2>/dev/null | awk '{print $1 "-" $2}'
  fi
}
