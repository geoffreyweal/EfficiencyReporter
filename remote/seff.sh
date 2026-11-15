# Runs seff on finished jobs, and looks for --profile in their batch scripts.
#
# Usage: seff.sh BATCH_IDS EACH_IDS SCRIPT_IDS
#   BATCH_IDS    comma-separated job IDs to give to a single seff call
#                (seff reports on every job it is given, one after another)
#   EACH_IDS     comma-separated job IDs to run seff on one at a time, so that
#                one job seff cannot report on cannot hide the others
#   SCRIPT_IDS   comma-separated job IDs whose batch scripts to search for
#                --profile
# Any of them may be empty.
#
# Sections:
#   about        seff's fingerprint
#   seff         output of the single seff call
#   seff:<id>    output of seff for job <id>, for each of EACH_IDS
#   scripts      the "Batch Script for <id>" headers and --profile lines of
#                sacct --batch-script

er_main() {
  local batch_ids=$1 each_ids=$2 script_ids=$3 id
  local -a ids

  er_begin about
  printf 'seff_fingerprint=%s\n' "$(er_fingerprint "${ER_SEFF[0]}")"
  er_end about 0

  if [ -n "$batch_ids" ]; then
    IFS=, read -r -a ids <<<"$batch_ids"
    er_run seff "${ER_SEFF[@]}" "${ids[@]}"
  fi

  if [ -n "$each_ids" ]; then
    IFS=, read -r -a ids <<<"$each_ids"
    for id in "${ids[@]}"; do
      er_run "seff:$id" "${ER_SEFF[@]}" "$id"
    done
  fi

  if [ -n "$script_ids" ]; then
    # Only the header and --profile lines are sent back, not whole scripts.
    er_begin scripts
    "${ER_SACCT[@]}" --batch-script --jobs="$script_ids" 2>/dev/null |
      grep -a -e '^Batch Script for ' -e '--profile'
    er_end scripts "${PIPESTATUS[0]}"
  fi
}
