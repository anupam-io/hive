#!/usr/bin/env bash
# PreCompact (auto) hook for the autonomous driver. Fires the moment the headless
# session hits the context-compaction threshold — i.e. "tokens are getting full".
#
# We do NOT want in-place compaction: a silently-summarised driver mid-sprint is
# exactly the degradation we're avoiding. Instead we drop a .restart sentinel and
# `exit 2` to BLOCK compaction, which ends the session. The supervisor
# (ops/driver-loop.sh) then relaunches a fresh session that rebuilds state from
# GitHub + the handoff via sprint-resume.
#
# Safe because the driver keeps .hive/handoff/sprint-N.md current after every
# action, so an abrupt restart loses at most the last in-flight action — which
# sprint-resume reconstructs from GitHub labels + open PRs + live pods anyway.
set -uo pipefail
dir="${CLAUDE_DRIVER_RUNDIR:-$PWD/.hive/runs/driver}"
mkdir -p "$dir"
touch "$dir/.restart"
echo "[driver] context limit reached — blocking compaction, handing off for a fresh restart" >&2
exit 2
