#!/bin/bash
# Efficiency Reporter: checks the commands the app runs on the cluster.
#
# Run it on a Mahuika login node, as yourself, from a copy of the app:
#
#     bash tools/check_on_mahuika.sh              # uses some of your recent jobs
#     bash tools/check_on_mahuika.sh 12345678     # also opens this job, e.g. one
#                                                 # you ran with --profile task
#
# It runs the scripts in remote/ exactly as the app does (the same text, piped
# into "bash -s"), with the settings in conf.yml.erb for Mahuika, and prints a
# short summary of what each one returned. It only reads: sacct, seff and
# profile_plot are run as you, and profile_plot writes into a temporary
# directory that is removed. Nothing is installed or changed.

set -u

app=$(cd "$(dirname "$0")/.." && pwd)
want=${1:-}
mark='@@ERCHECK'
us=$'\x1f'

# The script the app would send: settings, common.sh, the script, the call.
compose() {
  printf '%s\n' '#!/bin/bash' "ER_MARK=$mark" 'ER_PATH_EXTRA=/opt/nesi/bin' \
    'ER_SACCT=(sacct)' 'ER_SEFF=(seff)' 'ER_PROFILE_PLOT=(profile_plot)'
  cat "$app/remote/common.sh"
  echo
  cat "$app/remote/$1.sh"
  echo
  echo 'er_main "$@" </dev/null'
}

run_remote() {
  local script=$1
  shift
  compose "$script" | bash -s -- "$@"
}

# section NAME: the lines of one section of the output on stdin
section() {
  awk -v b="$mark:BEGIN $1" -v e="$mark:END $1 " 'index($0, e) == 1 { p = 0 } p { print } $0 == b { p = 1 }'
}

# rc NAME: the exit status recorded for a section
rc() {
  awk -v e="$mark:END $1 " 'index($0, e) == 1 { print $NF; exit }'
}

indent() {
  sed 's/^/    /' | tr "$us" '|' | cut -c1-220
}

echo "== Efficiency Reporter check: $(hostname -s) $(date '+%F %T') as $(id -un), shell $SHELL"
echo "== Where the commands are (PATH plus /opt/nesi/bin)"
for tool in sacct seff profile_plot base64 mktemp cksum; do
  printf '    %-13s %s\n' "$tool" "$(PATH="$PATH:/opt/nesi/bin" command -v "$tool" || echo 'NOT FOUND')"
done
echo "    seff is: $(PATH="$PATH:/opt/nesi/bin" readlink -f "$(PATH="$PATH:/opt/nesi/bin" command -v seff)" 2>/dev/null)"

start=$(date -d '3 months ago' +%Y-%m-%dT00:00:00)
end=$(date +%Y-%m-%dT%H:%M:%S)
t0=$SECONDS
out=$(run_remote list_jobs "$start" "$end")
jobs=$(section jobs <<<"$out")
echo
echo "== list_jobs.sh $start $end   ($((SECONDS - t0)) s)"
section about <<<"$out" | indent
count=$(awk -F"$us" 'NR > 1 && $1 ~ /^[0-9]/' <<<"$jobs" | wc -l | tr -d ' ')
echo "    sacct exit status $(rc jobs <<<"$out"); $count jobs. Header and first 3:"
head -4 <<<"$jobs" | indent
section jobs.stderr <<<"$out" | head -5 | indent

# Up to 6 finished jobs that started, the newest last, by column name.
pick=$(awk -F"$us" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
  $c["AllocCPUS"] > 0 && $c["State"] !~ /RUNNING|PENDING/ { print $c["JobID"] }' <<<"$jobs" | tail -6)
batch=$(paste -sd, - <<<"$pick")
if [ -z "$batch" ]; then
  echo
  echo "== No finished jobs in the last 3 months, so seff and profile_plot were not tried."
  exit 0
fi

t0=$SECONDS
out=$(run_remote seff "$batch" "" "$batch")
echo
echo "== seff.sh: one seff call for $batch   ($((SECONDS - t0)) s)"
echo "    seff exit status $(rc seff <<<"$out"):"
section seff <<<"$out" | head -60 | indent
section seff.stderr <<<"$out" | tail -5 | indent
echo "    --profile lines in their batch scripts (sacct --batch-script, exit $(rc scripts <<<"$out")):"
section scripts <<<"$out" | head -20 | indent

first=$(head -1 <<<"$pick")
out=$(run_remote seff "" "$first" "")
echo
echo "== seff.sh: seff on one job at a time ($first), exit $(rc "seff:$first" <<<"$out")"
section "seff:$first" <<<"$out" | head -15 | indent

job=${want:-$(tail -1 <<<"$pick")}
t0=$SECONDS
out=$(run_remote job_details "$job")
echo
echo "== job_details.sh $job   ($((SECONDS - t0)) s)"
for name in job steps seff; do
  echo "  -- $name (exit $(rc "$name" <<<"$out"))"
  section "$name" <<<"$out" | head -12 | indent
  section "$name.stderr" <<<"$out" | tail -3 | indent
done
echo "  -- batch script: $(section script <<<"$out" | wc -l) lines (exit $(rc script <<<"$out")); --profile lines:"
section script <<<"$out" | grep -e '--profile' | indent

raw=$(section job <<<"$out" | awk -F"$us" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { print $c["JobIDRaw"]; exit }')
t0=$SECONDS
out=$(run_remote profile_plot "${raw:-$job}")
echo
echo "== profile_plot.sh ${raw:-$job}   ($((SECONDS - t0)) s)"
section result <<<"$out" | indent
echo "    its stderr:"
section stderr <<<"$out" | head -10 | indent
if [ -n "$(section image <<<"$out")" ]; then
  bytes=$(section image <<<"$out" | base64 -d | wc -c)
  kind=$(section image <<<"$out" | base64 -d | head -c 4 | od -An -c | tr -s ' ')
  echo "    image: $bytes bytes, starting with:$kind"
else
  echo "    no image (expected unless the job ran with --profile task in the last 30 days)"
fi

echo
echo "== Done. Please paste everything above back."
