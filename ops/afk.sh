#!/usr/bin/env bash
# AFK driver loop — runs the driver non-interactively in a for-loop.
# Sleeps 5 min between iterations. The driver is told via system prompt
# that this is an AFK run and to advance one wave per iteration.
#
# Usage:  bash ops/afk.sh [iterations]    # default 10
# Env:    SLEEP_SEC=300  HIVE_STATE_DIR=$HOME/.hive
# Logs:   $HIVE_STATE_DIR/.agents/afk-<unix-ts>/iter-N.log
# Exit:   early if driver prints <promise>SPRINT_COMPLETE</promise>

set -u

N="${1:-10}"
SLEEP_SEC="${SLEEP_SEC:-300}"

HIVE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HIVE_STATE_DIR="${HIVE_STATE_DIR:-${HIVE_STATE_DIR:-$HOME/.hive}}"
STATE_DIR="$HIVE_STATE_DIR/.agents/afk-$(date +%s)"
DRIVER_MD="$HIVE_ROOT/.claude/agents/driver.md"

[[ -f "$DRIVER_MD" ]] || { echo "afk: driver.md not found at $DRIVER_MD" >&2; exit 1; }
command -v claude >/dev/null || { echo "afk: claude CLI not on PATH" >&2; exit 1; }

mkdir -p "$STATE_DIR"
echo "afk: $N iters, ${SLEEP_SEC}s between → $STATE_DIR"

for ((i=1; i<=N; i++)); do
  echo "--- iter $i/$N $(date +%H:%M:%S) ---"
  log="$STATE_DIR/iter-$i.log"

  claude -p \
    --add-dir "$HIVE_ROOT" \
    --permission-mode bypassPermissions \
    --append-system-prompt "$(cat "$DRIVER_MD")

# AFK MODE
You are running in an AFK driver loop (iteration $i of $N). The user is NOT at the keyboard — no clarifying questions, no waiting for approval. Read state.md, advance the sprint by ONE concrete step (fire / merge / qa / triage / triage-needs-human), update state.md with what changed and what's next, then exit. Skills under \$HIVE_ROOT/.claude/skills/ are available. If the active sprint is fully done (no Ready issues on the sprint label, no open agent/* PRs), print the exact sentinel <promise>SPRINT_COMPLETE</promise> and exit." \
    "Advance the sprint one step. You are in AFK loop iter $i/$N." 2>&1 | tee "$log"

  if grep -q "<promise>SPRINT_COMPLETE</promise>" "$log"; then
    echo "afk: sprint complete at iter $i"
    exit 0
  fi

  if [[ $i -lt $N ]]; then
    echo "afk: sleeping ${SLEEP_SEC}s..."
    sleep "$SLEEP_SEC"
  fi
done

echo "afk: $N iterations done"
