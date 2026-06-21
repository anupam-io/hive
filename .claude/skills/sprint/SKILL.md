---
name: sprint
description: Run and report on a sprint — fire its waves to completion, check state, close it out. A sprint is a dependency-ordered batch of GitHub issues planned by the `sprint-plan` skill and tagged `sprint-N`. Use when the user says "fire sprint-N", "run sprint-N overnight", "what's the state of sprint-N", "close sprint-N", or "we're on sprint-N". To PLAN a sprint (decompose + DAG), use `sprint-plan` instead — this skill executes a plan that already exists.
---

# sprint

The **runner**. Planning happens in the `sprint-plan` skill, which leaves a
`promise.md` with a precomputed wave schedule. This skill executes that schedule:
fire wave after wave until every issue is merged, then close out. The headline use
is **`run N`** — kick it off and the fleet finishes the sprint unattended (overnight).

- **Sprint** = the labelled batch of issues (`sprint-N` on issue + PR).
- **Wave** = one parallel fan-out of pods. Waves are precomputed in `promise.md`
  (the `wave` column), not guessed at fire time.

## Identity & tagging

- `sprint-N` (next integer, never reused) labels every issue and every PR. The
  driver adds the label to a PR when it ships — workers don't know their sprint.
- A sprint is scoped **by label**, not branch or milestone. Filter everywhere with
  `--label sprint-N`.
- `promise.md` / `result.md` / `dag.html` live in the app repo under
  `.claude/sprints/sprint-N/`, committed to git.

## Sub-actions

### run N — fire to completion (the overnight loop)

The autonomous driver loop. Requires an approved `promise.md` for sprint N. Runs
until the sprint is done or hits a wall it can't recover. **Safe to re-enter** —
every iteration reconciles real state before firing, so a restart never double-fires.

```
load promise.md → wave schedule + per-issue deps + budget_usd
loop:
  0. RECONCILE — if re-entering after a wake/restart, run `sprint-resume` first so
     you never fire an issue that already has a live pod or open PR (the Iron Law).
  1. BUDGET gate (SOFT, not a wall) — sum pod spend + fire count from
     `hivectl metrics --label sprint-N`. Cap = promise.md `budget_usd` if set, else
     `HIVE_SPRINT_BUDGET_USD` (200); fire-cap = `HIVE_SPRINT_MAX_AGENTS` (100);
     hard ceiling = cap × (1 + `HIVE_SPRINT_BUDGET_OVERRUN_PCT`/100). Under the
     cap: fire freely. In the overrun band (cap→ceiling): keep going but only
     close-out waves (ship/review/QA), no big new impl waves. Past the ceiling:
     STOP firing new work, let in-flight finish, report (AUTO: don't ask). Check
     before every wave AND every re-fire.
  2. pick the next unfired wave whose every dep issue is status:done AND PR merged
  3. fire it — per issue: flip status:ready→in-progress, then `hivectl fire` (see
     "fire N"); append `WAVE k FIRED <ts> issues: …` to .hive/handoff/sprint-N.md
  4. start the drain watcher; end the turn
  -- on wake (watcher exit 0, watcher exit 1/timeout, or heartbeat) --
  5. ship APPROVED PRs (Action A); fire reviewers for unreviewed sprint PRs (Action B)
  6. handle NEEDS_HUMAN per driver.md; on a watcher exit-1, reconcile + reap stuck
     pods — do NOT assume the wave drained
  7. not done? → loop (back to 0)
terminate when: every sprint-N issue is status:done AND every sprint-N PR merged
  AND QA fold-in is drained or capped (no open `sprint-N` + `type:qa-feedback`
  issues, OR the `HIVE_QA_FOLD_ROUNDS` / budget ceiling was hit) — see driver.md
  "Fold QA findings back into the sprint"
  → run `close N`
```

Fire the **whole** wave at once — the planner already capped wave width to cluster
headroom (`--max-wave-width`, default 16) and guaranteed file-disjointness, so the
wave is safe to fan out in one shot. Flipping each issue to `status:in-progress` at
fire time is what stops a crash-and-resume from re-reading it as `ready` and
double-firing.

**Heartbeat — make it advance, not just report.** The first time `run N` fires a
wave, start `/loop 5m /sprint run N` (NOT `status N`). The watcher catches the fast
drain; the heartbeat re-enters the *drive* loop on a fixed cadence so a pod that
hangs without draining still gets shipped / reviewed / reaped instead of merely
narrated. Both wakes re-enter `run N`, which reconciles before firing — so they
can't double-fire. Start it once per sprint; `close N` stops it.

QA firing is owned by the driver's Action A (it fires the QA bucket when the last
impl PR merges) — the run loop does not fire QA independently.

### fire N — one wave

Fire a single wave (used by `run N`, or manually to step through):

1. From `promise.md`, pick the lowest-numbered wave not yet fired whose deps are
   all `status:done`. List its issues.
2. **Resource sanity check** — how many sprint pods are live
   (`kubectl -n agents get pods | grep coding-agent | wc -l`)? Will this wave keep
   the cluster under headroom and the sprint under its cost budget? If tight,
   shrink or hold.
3. For each issue: flip it to in-progress, then fire (background, parallel):
   `gh issue edit <N> --add-label status:in-progress --remove-label status:ready`,
   then `hivectl fire <N> --type=<hive-type>`. The `promise.md` `type:*` label maps to
   the `hivectl fire --type=` value:

   | issue label | `hivectl fire --type=` |
   |---|---|
   | `type:feature` | `feature-implementation` |
   | `type:bug` | `bug-fix` |
   | `type:improvement` | `improvement` |
   | `type:research` | `research` |

   There are no reviewer waves — each worker reviews and gates its own PR in-pod
   (status flips to `in-review` on review PASS, `changes-requested` on rework).
   Re-fire workers on `status:changes-requested` issues (driver Action B).
   (QA is fired by the driver's Action A via `hivectl qa`, not here.)
4. **Start the drain watcher**, then end the turn (see below).
5. Report: issues fired this wave, what's still queued and why, pod count, rough
   resource posture. End with `RESULT: SPRINT_FIRED N <count>`.

### Waiting between waves

`hivectl fire` is fire-and-forget. After firing, sleep on the watcher so the next
turn wakes when the wave drains:

```bash
APP="$(hivectl config get app)" bash "$HIVE_ROOT/.claude/skills/sprint/watcher.sh"   # Bash run_in_background=true
```

It selects pods by **label** (`app.kubernetes.io/name=coding-agent,app=<app>`) —
not by parsing the pod name — and exits **0** when no non-terminal coding-agent pod
remains. On exit the harness emits a task-notification and the driver wakes. It
exits **1** on a 90-min timeout or if pods never appeared: treat a non-zero wake as
"investigate" — reconcile via `sprint-resume`, reap/re-fire stuck pods, and do NOT
assume the wave drained. Override poll/cap with `SLEEP=` / `MAX_MIN=`.

The watcher catches the **fast happy path** (pods finish, wake in seconds); the
5-minute `run N` heartbeat catches the **slow/stuck path** (pod hung in Init,
reviewer looping on cost cap, manual `kubectl` change). Run both — both re-enter
`run N`, which reconciles before firing, so they can't double-fire.

### status N

| Slice | Query |
|---|---|
| Issues | `gh issue list --label sprint-N --state all --json number,title,labels` (bucket by `status:*`) |
| Open PRs | `gh pr list --label sprint-N --state open --json number,title,labels` (review verdict is the issue's `status:in-review` / `status:changes-requested`) |
| Merged PRs | `gh pr list --label sprint-N --state merged --json number,title,mergedAt` |
| Fleet | `hivectl logs` filtered to the sprint's issue numbers |

Output: elapsed since `promise.md`'s plan timestamp (`2d 4h 12m`; omit if the file
is missing) · ready / in-review / done counts · open PRs split approved /
waiting-review / draft · merged count + which waves remain · **one-line direction
call** ("fire wave 3" / "fire reviewers" / "fire qa" / "ship approved" / "sprint
done — close"). End with `RESULT: SPRINT_STATUS N`.

### close N — retro

Writes `result.md`, the close-time artifact that pairs with `promise.md`. The
**release itself (tag + deploy + verify) is the driver's job** — see the "Release"
section of `driver.md`. This action produces the retro and triggers that release;
it does not re-implement it.

1. **Verify done** — all `sprint-N` issues `status:done`, all `sprint-N` PRs
   merged. If anything is open, bail with the list and suggest `run N` / `status N`.
   Never close a sprint with open work.
2. **Load `promise.md`** — the result is judged against it (promised vs delivered,
   in scope vs drifted). If missing, note that and skip the diff.
3. **Aggregate metrics** via `hivectl metrics` filtered to the sprint's issue numbers:
   total cost / tokens / wall time, cost-per-issue avg, slowest + highest-cost
   issue, breakdown by role (research / impl / reviewer / qa).
4. **Trigger the release** — hand off to the driver's Release flow (semver bump
   from what landed → `release/<version>` PR → self-merge → tag → `ops/deploy.sh`
   → verify the cluster serves the tagged HEAD). Record the chosen version + deploy
   outcome for `result.md`.
5. **Write `result.md`** to `.claude/sprints/sprint-N/`:
   - Header: sprint N, close timestamp (ISO-8601 with time), released version,
     one-line outcome.
   - **Promise vs delivered** table: each promised issue ✅ merged / ⚠️ partial /
     ❌ dropped / ➕ added-mid-sprint.
   - **Release**: version + one-sentence bump justification + deploy outcome.
   - **Metrics**: total cost / tokens / agent wall time / **sprint wall time**
     (close − plan timestamp) / issue count / merged PR count / **wave count**.
   - **What shipped (Good)**: 3-7 capability highlights (the *capability* a PR
     added, not its title verbatim).
   - **What missed (Bad)**: reviewer multi-round pushbacks, NEEDS_INFO bails,
     cost-cap overruns — what the next sprint should avoid.
   - **Future plan (Sprint N+1)**: 3-5 bullets — a *proposal*, not a commitment.
   - **By the numbers**: per-issue cost / wall / tokens / role table.
6. Stop the sprint's heartbeat loop. **Don't auto-plan N+1** — the future-plan
   section seeds the user's next `sprint-plan` call.
7. End with `RESULT: SPRINT_CLOSED N <version>`.

> HTML/PDF report: `close` produces `result.md` only. A Range-branded shareable
> render via `create-html-report` is planned, not yet wired — don't attempt it.

## Coordination with the driver

When a sprint is active the driver's per-fire loop still runs, scoped by
`--label sprint-N`:

| Driver action | Sprint form |
|---|---|
| A. Ship reviewed | merge only sprint PRs at `status:in-review` (review PASS); flip issue to `status:done` |
| B. Resolver loop | re-fire workers on sprint issues at `status:changes-requested` |
| C. Plan issues | don't plan inside a running sprint — `sprint-plan` owns planning |
| D. Course-correct | comment on the sprint; don't open a wide new issue mid-sprint |

If the user hasn't named the active sprint, **ask** — don't default to the
highest-numbered label that happens to exist.

## State

Active sprint lives in the session conversation (no persistent active-sprint file).
Persistent artifacts are the per-sprint files in the app repo under
`.claude/sprints/sprint-N/`: `promise.md` (from `sprint-plan`), `dag.mmd` + `dag.html`
(the graph), `result.md` (from `close N`).

## Result line

End every run with exactly one of:
- `RESULT: SPRINT_FIRED N <count>` — fired a wave (`<count>` = pods this wave)
- `RESULT: SPRINT_STATUS N` — after `status`
- `RESULT: SPRINT_CLOSED N <version>` — after `close`
- `RESULT: SPRINT_ACTIVE N` — user just set the active sprint; no other action
- `RESULT: IDLE` — nothing to do this turn

When the underlying action was a per-fire driver action (ship/review/correct),
emit the driver's result (`SHIPPED` / `PAUSED` / `COURSE_CORRECTED`) instead.
