---
name: sprint-resume
description: Use when re-entering a sprint that may already be running — a new or restarted driver session, a /loop heartbeat waking into a fresh context, after a crash / laptop sleep / context reset, or any time you're unsure which waves are already in flight and firing again could double-fire pods. Reconstructs authoritative wave state from GitHub labels + open PRs + live pods BEFORE any new fire, then hands off to `sprint run N`. Read it before resuming; skip it inside one continuous, uninterrupted run loop.
---

# sprint-resume

The safety gate the runner is missing. The overnight loop's only live memory is
the chat session; the moment it dies (crash, sleep, context exhaustion, a `/loop`
heartbeat firing into a fresh context), the next driver has no reliable record of
which waves are already in flight — and AUTO mode will happily re-fire a wave
whose pods are still running, burning budget and opening duplicate PRs.

This skill rebuilds the true state from the three **durable** sources and emits
exactly one safe next action.

## The Iron Law

**Never `hivectl fire` an issue that has a live pod OR an open PR — regardless of its
`status:*` label.** Labels lag reality: a worker flips `status:ready →
in-progress` only *after* its pod starts, so an issue can read `ready` while a pod
is already on it. Pods and PRs are the truth; labels are a hint.

## When to use / when NOT

- **Use it** when you're entering an active sprint and didn't just fire the
  current wave yourself: fresh `hivectl driver` session, heartbeat wake, post-crash,
  "I'm not sure what's running."
- **Skip it** inside one continuous `sprint run N` loop where you fired the live
  wave this session and the watcher is what woke you — you already know the state.

## 1. Reconstruct (the read)

Run the bundled reconciler — it's deterministic, so you don't hand-correlate 30
issues across three sources:

```bash
APP="$(hivectl config get app)" bash "$HIVE_ROOT/.claude/skills/sprint-resume/reconcile.sh" sprint-N
```

It joins, per issue: the `status:*` label, whether a non-terminal pod exists
(`agents` ns, `issue_id` label), and the `agent/issue-N` PR's state + review
decision — and prints a verdict per issue. The three sources and how each one
*lies*:

| Source | Tells you | How it can mislead |
|---|---|---|
| issue `status:*` label | intended state | lags the pod (ready while a pod runs); set by the worker, not at fire time |
| `agent/issue-N` PR | work landed / under review | merged-but-issue-still-`ready` if Action A hasn't flipped it yet |
| live pod (`issue_id`) | work in flight right now | `shutdownPolicy: Delete` removes it the instant it exits — gone ≠ succeeded |

Also load `promise.md` for the wave schedule + per-issue `deps`.

## 2. Classify

The reconciler emits one verdict per issue (Iron Law baked in):

| Verdict | Means | Safe action |
|---|---|---|
| `DONE` | PR merged or `status:done` | none |
| `SHIP` | open PR, APPROVED | driver Action A merges it |
| `REVIEW` | open PR, not approved | fire a reviewer (Action B) |
| `IN-FLIGHT` | live pod, no PR yet | **wait — do not re-fire** |
| `BLOCKED` | `status:needs-human` | driver NEEDS_HUMAN play, or surface to human |
| `REFIRE` | no pod, no PR, status not `ready` | pod died mid-flight — safe to re-fire |
| `FIREABLE` | no pod, no PR, `status:ready` | fire when its wave's deps are `DONE` |

A wave is **complete** when all its issues are `DONE`; **drainable** when none are
`IN-FLIGHT`; otherwise still running.

## 3. Decide ONE next action

Map the reconciled board to a single handoff, in priority order (mirrors the
driver's per-fire priority, but never fires already-in-flight work):

1. any `SHIP` → driver ships approved PRs.
2. any `REVIEW` → fire reviewers for those PRs.
3. any `IN-FLIGHT` → **wait** (re-arm the watcher; don't fire anything new).
4. else next wave whose every dep issue is `DONE` and whose own issues are
   `FIREABLE`/`REFIRE` → fire that wave.
5. all impl `DONE` → check QA fold-in before closing: any open `sprint-N` +
   `type:qa-feedback` issue is still in-flight sprint work, not a reason to close.
   `FIREABLE`/`REFIRE` ones fire (driver drafts their DoD+Plan); only when none
   remain OR the round/budget cap is hit → hand to `sprint close N`.
6. only `BLOCKED` left with no other progress → surface the blocked issues + their
   non-done deps; do not spin.

**Rebuild the cross-session counters** (they live outside context, so a fresh
session must reconstruct them, never reset them):
- Sprint spend + fire count — `hivectl metrics --label sprint-N` (sum `cost_usd`;
  count rows). Compare against `HIVE_SPRINT_BUDGET_USD` / `HIVE_SPRINT_MAX_AGENTS`
  and the overrun ceiling before handing off — a restart must not blow the cap.
- `qa_round` — read it from `.hive/handoff/sprint-N.md`; if the file is missing,
  infer it from how many QA→fix cycles the merged `type:qa-feedback` PRs show.
  Never reset it to 0, or the fold-in loop never terminates.

## 4. Reconcile labels (optional repair only)

If a PR is `MERGED` but its issue isn't `status:done`, repair it — respecting the
mutex (`gh issue edit <N> --add-label status:done --remove-label status:in-review
--remove-label status:ready`). **Repairs only — never advance work in this step.**

## 5. Hand off

Write the reconciled board (one line per wave: complete / running / blocked) into
`.hive/handoff/sprint-N.md` so the next session inherits it, then invoke
`sprint run N` with the decided action. End with
`RESULT: SPRINT_RESUMED N <next-action>`.

## Red flags — stop and re-check

| Thought | Reality |
|---|---|
| "the label says `ready`, so I'll fire it" | check pods + PRs first — the label lags the pod |
| "the watcher woke me, so the wave drained" | could be a 90-min **timeout** (exit 1), not a drain — re-reconcile |
| "no handoff file, so nothing's running" | pods and PRs are the truth, not the file — run the reconciler |
| "a pod is gone, so that issue is done" | `shutdownPolicy: Delete` removes pods on *any* exit — gone could mean it errored; check for a PR |

## Bundled script

- `reconcile.sh` — read-only reconciler. `APP=<app> reconcile.sh sprint-N` →
  per-issue `status / pod / pr / verdict` table. Needs `gh`, `kubectl`, `jq`.
  Exits non-zero only on missing `APP`/arg.

## Result line

- `RESULT: SPRINT_RESUMED N <next-action>` — reconciled, handed off to `run N`
- `RESULT: SPRINT_STATUS N` — reconciled to report only, no action taken
- `RESULT: IDLE` — nothing to resume (no such active sprint)
