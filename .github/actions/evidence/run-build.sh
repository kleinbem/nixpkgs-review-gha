#!/usr/bin/env bash
# Runs `nix build --keep-going --keep-failed -L <installables>` with its output in
# $EVIDENCE_DIR/build.log. When the log stays silent for STALL_MINUTES, the build's
# processes are sampled into $EVIDENCE_DIR/hang/, so a hung build leaves stack traces.
set -uo pipefail

evidence="${EVIDENCE_DIR:?}"
stall=$(( ${STALL_MINUTES:-15} * 60 ))
mkdir -p "$evidence/hang"
log="$evidence/build.log"
date +%s > "$evidence/.build-start"
touch "$log"

mtime() { stat -c %Y "$1" 2> /dev/null || stat -f %m "$1"; }

nix build --keep-going --keep-failed -L "$@" > >(tee "$log") 2>&1 &
build=$!

sample_builders() {
  local stamp
  stamp=$(date -u +%H%M%S)
  ps -A -o pid,ppid,user,etime,command > "$evidence/hang/ps-$stamp.txt" 2>&1
  [[ $(uname) == Darwin ]] || return 0
  # Builds run as the _nixbld users; sample each of their processes.
  ps -A -o pid= -o user= | awk '$2 ~ /nixbld/ {print $1}' | while read -r pid; do
    sudo sample "$pid" 3 -file "$evidence/hang/sample-$stamp-$pid.txt" > /dev/null 2>&1
  done
}

last_sample=0
while kill -0 "$build" 2> /dev/null; do
  sleep 60
  now=$(date +%s)
  if (( now - $(mtime "$log") >= stall && now - last_sample >= 2 * stall )); then
    echo "::warning::no build output for $((stall / 60)) min, sampling the build processes"
    sample_builders
    last_sample=$now
  fi
done
wait "$build"
