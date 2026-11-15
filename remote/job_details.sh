# Collects what the app shows when a job is opened.
#
# Usage: job_details.sh JOBID
#
# Sections:
#   job      sacct for the job allocation, with a header line
#   steps    sacct for the job and each of its steps, with a header line
#   about    seff's fingerprint
#   seff     seff's report on the job
#   script   sacct --batch-script for the job (first 256 KiB)

er_main() {
  local id=$1 fields

  fields=$(er_sacct_fields JobID JobIDRaw JobName User Account Partition QOS \
    State Reason ExitCode Submit Start End Elapsed Timelimit AllocCPUS NNodes \
    ReqMem AllocTRES NodeList WorkDir SubmitLine)
  er_run job "${ER_SACCT[@]}" --allocations --parsable2 --delimiter="$ER_DELIM" \
    --jobs="$id" --format="$fields"

  # The fields the "Using sacct" section of NeSI's Finding Job Efficiency page uses.
  fields=$(er_sacct_fields JobID JobName State ExitCode Elapsed AllocCPUS NTasks \
    NNodes TotalCPU AveCPU MinCPU MaxRSS AveRSS MaxDiskRead MaxDiskWrite NodeList)
  er_run steps "${ER_SACCT[@]}" --parsable2 --delimiter="$ER_DELIM" \
    --jobs="$id" --format="$fields"

  er_begin about
  printf 'seff_fingerprint=%s\n' "$(er_fingerprint "${ER_SEFF[0]}")"
  er_end about 0

  er_run seff "${ER_SEFF[@]}" "$id"

  er_begin script
  "${ER_SACCT[@]}" --batch-script --jobs="$id" 2>&1 | head -c 262144
  er_end script "${PIPESTATUS[0]}"
}
