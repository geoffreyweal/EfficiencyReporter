#!/bin/bash
# Runs the app on your own computer against a mock cluster, so it can be tried
# and changed without OnDemand or Slurm:
#
#   - sacct and profile_plot are the mocks in test/mock_cluster/bin, serving
#     the made-up jobs in test/mock_cluster/jobs.py;
#   - seff is NeSI's real one (nn_seff), fetched from GitHub on first use and
#     run against the mock sacct.
#
# Needs Ruby with the gems in misc/Gemfile (sinatra, sinatra-contrib, rackup,
# sqlite3, webrick), python3 and curl. The seff reports it saves go in
# test/.cache/data. It runs in Sinatra's development mode, so
# changes to lib/ are picked up without a restart (as with Slurm Composer).
#
# Usage: test/run_local.sh [PORT]      then open http://localhost:PORT/

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
app=$(dirname "$here")
cache="$here/.cache"
port=${1:-9393}

mkdir -p "$cache"
if [ ! -f "$cache/nn_seff" ]; then
  echo "Fetching NeSI's seff (nn_seff) from github.com/nesi/opt-nesi-bin..."
  curl -fsSL https://raw.githubusercontent.com/nesi/opt-nesi-bin/main/nn_seff -o "$cache/nn_seff"
fi

export PATH="$here/mock_cluster/bin:$PATH"
export EFFICIENCY_REPORTER_CONF="$here/conf.local.yml.erb"
export EFFICIENCY_REPORTER_DATA="$cache/data"
export RACK_ENV="${RACK_ENV:-development}"

echo "Efficiency Reporter on http://localhost:$port/ (Ctrl-C to stop)"
cd "$app"
exec rackup --host 127.0.0.1 --port "$port" config.ru
