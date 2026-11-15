# Lists the user's jobs between two times with sacct, one line per job.
#
# Usage: list_jobs.sh START END
#   START, END   times sacct understands, e.g. 2026-08-15T00:00:00
#
# Sections:
#   about   user, host, where sacct/seff/profile_plot are, seff's fingerprint
#   jobs    sacct --allocations --parsable2 output, with a header line

er_main() {
  local start=$1 end=$2 user fields
  user=$(id -un)

  er_begin about
  printf 'user=%s\n' "$user"
  printf 'host=%s\n' "$(hostname -s 2>/dev/null || hostname)"
  printf 'sacct=%s\n' "$(command -v "${ER_SACCT[0]}" 2>/dev/null)"
  printf 'seff=%s\n' "$(command -v "${ER_SEFF[0]}" 2>/dev/null)"
  printf 'profile_plot=%s\n' "$(command -v "${ER_PROFILE_PLOT[0]}" 2>/dev/null)"
  printf 'seff_fingerprint=%s\n' "$(er_fingerprint "${ER_SEFF[0]}")"
  printf 'slurm=%s\n' "$("${ER_SACCT[@]}" --version 2>/dev/null)"
  er_end about 0

  # SubmitLine stays last: it is the one field that can hold a newline (from
  # sbatch --wrap), and the app joins such a line back onto the job it belongs to.
  fields=$(er_sacct_fields JobID JobIDRaw JobName State Partition Account QOS \
    AllocCPUS AllocTRES ReqMem NNodes Submit Start End Elapsed ElapsedRaw \
    Timelimit ExitCode SubmitLine)

  er_run jobs "${ER_SACCT[@]}" --allocations --parsable2 --delimiter="$ER_DELIM" \
    --user="$user" --starttime="$start" --endtime="$end" --format="$fields"
}
