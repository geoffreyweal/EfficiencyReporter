# Runs profile_plot for one job, exactly as a user would ("profile_plot JOBID"),
# in an empty temporary directory, and sends back the image it writes there.
#
# Usage: profile_plot.sh JOBID
#
# Sections:
#   result   rc=<profile_plot's exit status> and file=<the file it wrote>
#   stderr   what profile_plot printed on stderr (its messages and errors)
#   image    the file it wrote, base64-encoded (only if it wrote one)

er_main() {
  local id=$1 dir rc file="" candidate

  # Inside the script's temporary directory (see common.sh), so it is
  # removed even if profile_plot is stopped part-way.
  if [ -z "$ER_TMP" ] || ! dir=$(mktemp -d "$ER_TMP/profile.XXXXXX" 2>/dev/null); then
    er_begin result
    printf 'rc=1\nerror=could not make a temporary directory\n'
    er_end result 1
    return 1
  fi

  (cd "$dir" && "${ER_PROFILE_PLOT[@]}" "$id") >"$dir/.stdout" 2>"$dir/.stderr"
  rc=$?

  # profile_plot names the file after the job (<JOBID>_profile.png today).
  # Take whatever it wrote rather than relying on that name.
  for candidate in "$dir"/*; do
    if [ -f "$candidate" ]; then
      file=$candidate
      break
    fi
  done

  er_begin result
  printf 'rc=%s\nfile=%s\n' "$rc" "${file##*/}"
  er_end result "$rc"

  er_begin stderr
  cat "$dir/.stderr"
  er_end stderr 0

  if [ -n "$file" ]; then
    er_begin image
    base64 <"$file"
    er_end image 0
  elif [ "$rc" -eq 0 ] && [ -s "$dir/.stdout" ]; then
    # A profile_plot set up to write to stdout ("-o -") still works.
    er_begin image
    base64 <"$dir/.stdout"
    er_end image 0
  fi
}
