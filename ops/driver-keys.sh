#!/usr/bin/env bash
# Interactive control layer for the AUTO driver loop (ops/driver-loop.sh).
#
# Runs the supervisor loop in the BACKGROUND — its output still streams to your
# terminal — while this script reads single keypresses in the FOREGROUND (only
# the foreground process group may read the tty, which is why the loop has to be
# backgrounded):
#
#   h   hand off NOW and exit — kills the in-flight session immediately. The
#       handoff doc is kept current after every action and sprint-resume rebuilds
#       true state from GitHub labels/PRs/pods, so nothing is lost, just cut short.
#   m   mute / unmute the spoken driver narration.
#   ↑ / +   voice faster        ↓ / -   voice slower   (macOS `say -r` wpm)
#
# The mute flag and voice rate live as files in $RUNDIR and are read LIVE by
# ops/driver-pretty.py's speak() on each message. The terminal is always
# restored on exit (trap). With no tty (piped / cron) it just runs the loop.
set -uo pipefail

REPO="${1:?usage: driver-keys.sh <repo-dir>}"
ROOT="${HIVE_ROOT:?HIVE_ROOT unset — run via the hivectl CLI}"
RUNDIR="$REPO/.hive/runs/driver"
mkdir -p "$RUNDIR"
export CLAUDE_DRIVER_RUNDIR="$RUNDIR"

MUTE_FILE="$RUNDIR/.mute"
RATE_FILE="$RUNDIR/.voice-rate"
RATE_MIN=80; RATE_MAX=320; RATE_STEP=25; RATE_DEFAULT=175

# Start from a clean, predictable default each run (no stale mute/rate carried over).
rm -f "$MUTE_FILE" "$RATE_FILE"

status() { printf '  ‹driver-keys› %s\n' "$1"; }

cur_rate() { [ -r "$RATE_FILE" ] && cat "$RATE_FILE" 2>/dev/null || echo "$RATE_DEFAULT"; }
set_rate() {
  local r="$1"
  [ "$r" -lt "$RATE_MIN" ] && r="$RATE_MIN"
  [ "$r" -gt "$RATE_MAX" ] && r="$RATE_MAX"
  echo "$r" > "$RATE_FILE"
  status "voice rate ${r} wpm"
}

# No terminal to read from (piped / headless / cron) → just run the loop plainly.
if [ ! -t 0 ]; then
  exec bash "$ROOT/ops/driver-loop.sh" "$REPO"
fi

# Launch the loop in the background; its stdout stays on our terminal, but its
# stdin is /dev/null so it never swallows the keys we're reading.
bash "$ROOT/ops/driver-loop.sh" "$REPO" </dev/null &
LOOP_PID=$!

OLD_STTY="$(stty -g 2>/dev/null || true)"
cleanup() {
  if [ -n "$OLD_STTY" ]; then stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true
  else stty sane 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM
stty -echo -icanon 2>/dev/null || true

# Collect a pid's full descendant tree WHILE it's still alive (after the parent
# dies its children reparent to launchd and pgrep -P can't find them).
collect_descendants() {
  local pid="$1" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    echo "$c"
    collect_descendants "$c"
  done
}
kill_loop() {
  local pids; pids="$LOOP_PID $(collect_descendants "$LOOP_PID")"
  kill -TERM $pids 2>/dev/null || true
  pkill -x say 2>/dev/null || true
  sleep 1
  kill -KILL $pids 2>/dev/null || true
}

status "controls: [h] handoff+exit   [m] mute/unmute   [↑/↓ or +/-] voice speed"

while kill -0 "$LOOP_PID" 2>/dev/null; do
  IFS= read -rsn1 -t 1 key || continue
  [ -z "$key" ] && continue
  case "$key" in
    h|H)
      status "handing off now — stopping the driver."
      kill_loop
      break
      ;;
    m|M)
      if [ -e "$MUTE_FILE" ]; then rm -f "$MUTE_FILE"; status "unmuted"
      else : > "$MUTE_FILE"; status "muted"; fi
      ;;
    +|=) set_rate "$(( $(cur_rate) + RATE_STEP ))" ;;   # faster
    -|_) set_rate "$(( $(cur_rate) - RATE_STEP ))" ;;   # slower
    $'\e')  # arrow keys arrive as ESC [ A/B — grab the next two bytes
      IFS= read -rsn2 -t 1 seq || seq=""
      case "$seq" in
        '[A') set_rate "$(( $(cur_rate) + RATE_STEP ))" ;;  # up   = faster
        '[B') set_rate "$(( $(cur_rate) - RATE_STEP ))" ;;  # down = slower
      esac
      ;;
  esac
done

cleanup
wait "$LOOP_PID" 2>/dev/null || true
