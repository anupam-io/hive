#!/bin/bash
# Sprint pod-drain watcher (label-based).
#
# Exits 0 when no non-terminal coding-agent pod remains for this project. The
# driver runs it in the background (Bash run_in_background=true) after firing a
# wave; when it exits, the harness emits a task-notification that wakes the
# driver to drive the next wave.
#
# Selects pods by LABEL (`app.kubernetes.io/name=coding-agent` [+ `app=$APP`]),
# NOT by parsing the pod name. The Sandbox controller appends a random suffix to
# pod names, so the old "last dash-segment is the fire timestamp" parse silently
# scored running pods as "drained" in ~60s and fired the next wave too early.
#
# Usage:
#   APP=<app> bash watcher.sh                       # poll every 30s, cap 90 min
#   APP=<app> SLEEP=15 MAX_MIN=30 bash watcher.sh
# Env: NS (default agents), SLEEP, MAX_MIN, APP (project scope; recommended).
#
# The watcher must OBSERVE pods appear (count>0) at least once before it may
# declare "drained", so a slow-to-schedule pod isn't mistaken for an instant
# drain. If pods never appear (a failed fire), it runs to the cap and exits 1.
#
# Exit codes:
#   0  — drained (all wave pods reached a terminal phase / were deleted)
#   1  — timed out (cap hit) OR pods never appeared — investigate, do NOT assume drained

set -u
NS="${NS:-agents}"
SLEEP="${SLEEP:-30}"
MAX_MIN="${MAX_MIN:-90}"
SEL="app.kubernetes.io/name=coding-agent"
[ -n "${APP:-}" ] && SEL="$SEL,app=$APP"

MAX_ITER=$(( MAX_MIN * 60 / SLEEP ))
iter=0
seen=0

while [ $iter -lt $MAX_ITER ]; do
  iter=$((iter + 1))
  active=$(kubectl -n "$NS" get pods -l "$SEL" --no-headers 2>/dev/null \
    | awk '$3!="Completed" && $3!="Error" && $3!="Failed" && $3!="Succeeded" { print $1, $3 }')
  count=$(printf "%s\n" "$active" | grep -c . || true)
  ts_now=$(date +%H:%M:%S)
  echo "[$ts_now iter=$iter] active coding-agent pods ($SEL): $count"
  if [ "$count" -gt 0 ]; then
    seen=1
    printf "%s\n" "$active" | head -10
  fi
  if [ "$count" -eq 0 ] && [ "$seen" -eq 1 ]; then
    echo "[$ts_now] wave drained after ~$((iter * SLEEP))s"
    exit 0
  fi
  sleep "$SLEEP"
done

echo "watcher timed out after ${MAX_MIN}m (seen=$seen) — pods still non-terminal or never appeared; investigate, do NOT assume drained"
exit 1
