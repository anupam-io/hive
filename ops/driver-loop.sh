#!/usr/bin/env bash
# Autonomous driver supervisor (the engine behind `sp driver` / `hivectl driver`).
#
# Runs the driver headless (claude -p), streams ALL of its output to the
# terminal, and relaunches a FRESH session whenever the previous one ends — on
# the per-session budget cap, on a context-limit handoff (the PreCompact hook in
# ops/driver-settings.json), or any crash.
#
# Why a fresh session each time instead of one long one: durable state lives
# OUTSIDE the context window — GitHub issue labels + open PRs + live pods +
# .hive/handoff/sprint-N.md. Every fresh session runs sprint-resume to rebuild
# exactly where it was. Context therefore never accumulates across sessions, so
# the driver cannot exhaust its tokens no matter how long the sprint runs.
set -uo pipefail

REPO="${1:?usage: driver-loop.sh <repo-dir>}"
ROOT="${HIVE_ROOT:?HIVE_ROOT unset — run via the hivectl CLI}"
cd "$REPO"

DRIVER_MD="$ROOT/.claude/agents/driver.md"
SETTINGS="$ROOT/ops/driver-settings.json"
BUDGET="${SP_DRIVER_BUDGET_USD:-10}"      # per-session $ cap (the hard bound)
SLEEP_OVERRIDE="${SP_DRIVER_SLEEP:-}"     # set = fixed pause between sessions; empty = the driver self-paces via NEXT_WAIT_S
ONCE="${SP_DRIVER_ONCE:-0}"              # 1 = single session, no relaunch
MAX_SESSIONS="${SP_DRIVER_MAX_SESSIONS:-30}"  # runaway-cost backstop

RUNDIR="$REPO/.hive/runs/driver"
mkdir -p "$RUNDIR" "$REPO/.hive/handoff"
export CLAUDE_DRIVER_RUNDIR="$RUNDIR"

# What the driver does every session: rebuild state, pick the current sprint,
# drive it to completion. Single-quoted so $HIVE_ROOT stays literal for the
# driver (which resolves it from its own env / `hivectl root`).
AUTO_PROMPT='AUTO MODE — you are the driver running unattended in a restart loop. The human gives you a PLAN; you take it all the way to a released, screenshot-verified product. Do not ask the user anything; act.
1. Run the sprint-resume skill ($HIVE_ROOT/.claude/skills/sprint-resume/SKILL.md) to reconstruct the active sprint'\''s true wave state from GitHub labels + open PRs + live pods + the latest .hive/handoff/sprint-*.md. This prevents double-firing in-flight pods after a restart.
2. Pick THE CURRENT SPRINT — the highest sprint-N not yet released. If it has a .claude/sprints/sprint-N/plan.md but NO sprint-N issues exist yet, the plan IS the approval: load the sprint-plan skill in AUTO mode, decompose plan.md into the wave-ordered issues, and create them all (sprint-N + status:ready + type:* labels). Do NOT report IDLE just because issues do not exist yet — create them from the plan first.
3. Drive the sprint to completion via the sprint skill: fire each ready wave, ship approved PRs, unblock review, fire QA when impl lands.
4. Release: pick the semver bump, open+merge the release PR, tag, run ops/deploy.sh, verify the rollout, and VERIFY THE WORKING UI WITH SCREENSHOTS of the key pages against the deployed URL (qa capture or the playwright skill), saved under .claude/sprints/sprint-N/screenshots/ and referenced in result.md. A sprint is NOT done without visual proof the UI renders real content.
5. Fold QA findings back in (bounded): after the screenshot gate, label open type:qa-feedback issues for this sprint sprint-N, draft their DoD+Plan from the finding text (the qa-feedback DoD exception), drive the fixes to merge, redeploy + re-screenshot. Loop at most HIVE_QA_FOLD_ROUNDS rounds (default 2; track qa_round in the handoff); past the cap or the sprint budget hard ceiling, spill remaining NEW findings to next-sprint backlog and close.
6. Respect the SPRINT BUDGET every wave (driver.md "Sprint budget"): pod-fire spend/count from `hivectl metrics --label sprint-N` vs HIVE_SPRINT_BUDGET_USD / HIVE_SPRINT_MAX_AGENTS. Soft cap = bias toward closing out; hard ceiling (×(1+HIVE_SPRINT_BUDGET_OVERRUN_PCT/100)) = stop firing new work, let in-flight finish, report — do not ask, just stop.
7. Keep .hive/handoff/sprint-N.md current after EVERY action — a restarted session reads it to resume.
8. Print exactly "RESULT: SPRINT_CLOSED" ONLY after release + screenshot verification AND QA fold-in is drained or capped. Print exactly "RESULT: IDLE" ONLY if there is genuinely no plan and no issues to act on. Otherwise keep driving — and when you end a tick with work still in flight, add a "NEXT_WAIT_S: <60-600>" line right after your RESULT line to set how long the supervisor waits before relaunching (big wave just fired -> ~600; a review or two pending -> ~120-300; idle poll -> 60). See driver.md "Self-paced wait between ticks".'

session=0
while true; do
  session=$((session+1))
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$RUNDIR/session-$session-$ts.jsonl"
  rm -f "$RUNDIR/.restart"

  printf '────────────────────────────────────────────────────────\n'
  printf 'sp driver · session #%s · %s · per-session cap $%s\n' "$session" "$(date -u +%H:%M:%SZ)" "$BUDGET"
  printf '────────────────────────────────────────────────────────\n'

  claude -p \
    --dangerously-skip-permissions \
    --model "${HIVE_DRIVER_MODEL:-claude-opus-4-8}" \
    --add-dir "$ROOT" \
    --settings "$SETTINGS" \
    --append-system-prompt "$(cat "$DRIVER_MD")" \
    --max-budget-usd "$BUDGET" \
    --verbose --output-format stream-json \
    "$AUTO_PROMPT" \
    | tee "$log" \
    | python3 "$ROOT/ops/driver-pretty.py" || true

  # Stop only when the driver's OWN final message reports a released sprint.
  # The tokens also appear in tool-result content (the driver reads sprint/
  # driver docs that quote them), so a whole-log grep false-stops on the first
  # session that reads them. Scope the check to the final result event; IDLE or
  # a missing token means "nothing this tick" → relaunch (MAX_SESSIONS bounds it).
  final_msg="$(python3 - "$log" <<'PY'
import json, sys
txt = ""
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if o.get("type") == "result":
        txt = o.get("result", "")
print(txt)
PY
)"
  if printf '%s' "$final_msg" | grep -q 'RESULT: SPRINT_CLOSED'; then
    printf 'sp driver · sprint released (session #%s). stopping.\n' "$session"
    break
  fi
  if [[ "$ONCE" == "1" ]]; then
    printf 'sp driver · --once set — single session done. stopping.\n'
    break
  fi
  if (( session >= MAX_SESSIONS )); then
    printf 'sp driver · hit SP_DRIVER_MAX_SESSIONS=%s without a SPRINT_CLOSED — stopping (raise the cap to continue).\n' "$MAX_SESSIONS" >&2
    break
  fi

  reason="session ended (budget cap or completion)"
  [[ -f "$RUNDIR/.restart" ]] && reason="context limit reached → handed off"
  # Self-paced wait: the driver emits `NEXT_WAIT_S: <n>` based on how much work
  # is in flight (see driver.md "Self-paced wait between ticks"). Clamp [60,600];
  # default 60 if it didn't say; an explicit SP_DRIVER_SLEEP forces a fixed value.
  if [[ -n "$SLEEP_OVERRIDE" ]]; then
    wait_s="$SLEEP_OVERRIDE"
  else
    wait_s="$(printf '%s' "$final_msg" | grep -oE 'NEXT_WAIT_S:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1)"
    wait_s="${wait_s:-60}"
    (( wait_s < 60 ))  && wait_s=60
    (( wait_s > 600 )) && wait_s=600
  fi
  printf 'sp driver · %s — relaunching a fresh session in %ss (Ctrl-C to stop)\n' "$reason" "$wait_s"
  sleep "$wait_s"
done
