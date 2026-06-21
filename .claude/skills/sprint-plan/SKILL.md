---
name: sprint-plan
description: Plan one sprint as a dependency-ordered wave DAG so the fleet can run it to completion unattended (overnight). Decomposes a goal into 20-30 right-sized GitHub issues, assigns file ownership, builds the dependency graph, topologically sorts it into parallel waves, renders the DAG (Mermaid + HTML) for human review, and on approval creates the issues + writes promise.md. Use when the user says "plan a sprint", "plan sprint-N", "let's build the next sprint", or wants to scope a big batch of autonomous work. This is the coordinator; the `sprint` skill is the runner that fires the waves.
---

# sprint-plan

The **coordinator**. You collaborate with the user to turn one thesis into a
dependency-ordered wave plan the fleet can execute unattended. You do the hard
upfront thinking — decompose, size, map file ownership, build the DAG, sort into
waves — so that once the user approves, the `sprint` runner can fire wave after
wave to completion without a human in the loop.

Plan-time is the only human gate. Get it right here and the overnight run is
boring; get it wrong and 30 pods collide or build on code that doesn't exist yet.

## What you produce

1. **`promise.md`** — the canonical sprint commitment (schema below), with the
   wave schedule and the embedded Mermaid DAG.
2. **`dag.html`** — a self-contained rendered graph the user opens in a browser
   to eyeball the waves before approving.
3. **GitHub issues** — one per node, each with `## Plan` + `## Definition of Done`,
   the `sprint-N` label, and its wave recorded in `promise.md`. Created **only
   after the user approves the draft.**

## The pipeline

Run these in order. Steps 1-5 are drafting (no writes to GitHub); step 6 is the
human gate; step 7 commits.

### 1. Ground the direction

- Read the app repo's `CLAUDE.md` (the thesis) + last 10 merged PRs.
- Count existing `status:ready` issues by type — some of the sprint may already
  be queued; don't re-create what exists.
- Pick the next sprint integer `N` (highest existing `sprint-*` label + 1).

### 2. Decompose into atomic issues

This is the highest-leverage step and the one LLMs get wrong. **Resist writing a
few fat issues.** Each issue must fit in **one pod's context window = roughly one
PR**: one migration, one component, one endpoint, one refactor of one module.

- Hard cap **~300 LOC per issue.** Anything you expect to be bigger gets split
  *now*, at plan time — never at PR-review time.
- Aim for **20-30 issues.** If the thesis only yields 8, it's a small sprint —
  say so; don't pad. If it yields 50, it's two sprints — split and plan the
  first.
- Tag each with a `type`: `research | feature | bug | improvement | qa`.

Composition target (a default, not a rule — drop research if the path is
obvious, drop qa if there's no UI):

| Bucket | Count | Role |
|---|---|---|
| Research | 4-6 | discovery/spec; cheap, parallel; usually unblocks impl |
| Implementation | 14-20 | the meat — each produces one PR |
| QA | 3-5 | fired against the deployed UI after impl lands |

Set a **`budget_usd` ceiling** for the sprint now — it's the only real overnight
cost guard (per-fire caps don't bound the total across re-fires). Heuristic:
`~$2 × impl + ~$1 × (research + qa)`, +30% for re-fires. The runner sums
`hivectl metrics --label sprint-N` before each wave and stops to ask if cumulative
cost crosses it.

### 3. Assign file ownership

For each issue, list the **paths/globs it will own**. Best-effort, but load-bearing:
two issues in the same wave must touch **no file in common** (one file, one
owner). This is what makes 20-30 pods run in parallel without merge wars. Be
concrete — `api/transfers/*.ts`, `db/schema/transfers.ts` — not `src/`.

### 4. Build the dependency graph

Issue B depends on A iff B genuinely cannot start until A's output exists (B
imports A's schema, calls A's endpoint, extends A's component). **Default to
independent** — only add a dep when it's real. Over-declaring deps serialises the
sprint and kills the overnight throughput.

### 5. Topologically sort into waves + render

Write the issues to a temp JSON and run the deterministic sorter — don't hand-sort
20+ nodes:

```bash
# issues.json: [{ "id": 1, "title": "...", "type": "feature", "deps": [], "files": ["..."] }, ...]
# (use sequential placeholder ids 1..N at draft time; remap to real GH numbers after creation)
node "$HIVE_ROOT/.claude/skills/sprint-plan/wave-sort.mjs" issues.json \
  --max-wave-width 16 --out "$(git rev-parse --show-toplevel)/.claude/sprints/sprint-N/"
```

It computes waves (deps satisfied + file-disjoint), splits same-file pairs across
waves, **splits any over-wide wave into ordered sub-waves** so none exceeds cluster
headroom (`--max-wave-width`, default 16), **errors on a dependency cycle**, and
writes `dag.mmd` + `dag.html`. A sprint typically lands in **4-6 waves**.

> **AUTO / driver mode — skip this gate.** When the **driver** invokes this
> skill in AUTO mode and a `.claude/sprints/sprint-N/plan.md` already exists, that plan
> file **IS** the human approval. Skip step 6 entirely: run steps 1-5 to
> decompose the plan into wave-ordered issues, then go straight to step 7
> (create the issues + write `promise.md`), using the plan's thesis,
> composition, wave architecture, and out-of-scope as the decomposition source.
> Do not pause for chat approval — the human approved by writing the plan. The
> driver then fires the waves.

### 6. Show the user — the human gate

Present, in chat:
- the composition table (counts vs target),
- the wave table (the sorter's text output),
- the Mermaid DAG block, and
- a pointer to open `.claude/sprints/sprint-N/dag.html` for the visual.

Then **stop and wait for explicit approval.** Do not create a single GitHub issue
before the user says go. This is a deliberate gate — 20-30 issues is high-leverage
and an LLM-drafted plan that's subtly wrong wastes a whole overnight run.

Iterate with the user here: re-split a fat issue, break a false dependency, move a
collision. Re-run the sorter after edits.

### 7. On approval — create issues + write promise.md

- Create the `sprint-N` label if absent:
  `gh label create sprint-N --color BFD4F2 --description "Sprint N" --force`
- For each issue, in dependency order, `gh issue create` with:
  - first body line `TASK_TYPE: <type>` (the worker's routing hint),
  - `## Plan` (plain heading — you are planner of record, so it's pre-approved
    scope) covering goal / constraints / format of done / failure mode / files
    owned,
  - `## Definition of Done` — `- [ ]` checklist of verifiable predicates the
    reviewer grades pass/fail (always include `- [ ] PR opens against <base>`,
    `- [ ] gh pr checks all pass`),
  - labels `type:<type>`, `status:ready`, `sprint-N`.
- Remap the placeholder ids in `promise.md`'s table to the real GH issue numbers,
  re-run `wave-sort.mjs` with the real ids so `dag.html` shows real numbers.
- Write **`promise.md`** (schema below) and leave it for the user to commit.

End with `RESULT: SPRINT_PLANNED N <count>`.

## promise.md schema

```markdown
# Sprint N — <one-line thesis>

Planned: <ISO-8601 with time, e.g. 2026-06-10T17:30:00Z>
Waves: <count>   Issues: <count>   Budget: $<ceiling>

## Composition
| Bucket | Planned | Target |
|---|---|---|
| Research | … | 4-6 |
| Impl | … | 14-20 |
| QA | … | 3-5 |

## Issues
| # | type | title | files-owned | deps | wave | why |
|---|------|-------|-------------|------|------|-----|
| 12 | feature | transfers schema | db/schema/transfers.ts | - | 1 | … |
| 18 | feature | transfers API | api/transfers/*.ts | 12 | 2 | … |

## Wave DAG
```mermaid
<contents of dag.mmd>
```

## Out of scope
- <3-5 bullets explicitly deferred, so scope creep can be pushed back on later>

## Definition of done (sprint)
- All sprint-N issues status:done + all PRs merged
- Deployed URL reachable on the released tag
- result.md written by `close N`
```

The `deps` and `wave` columns are the contract the `sprint` runner reads to fire
each wave. `files-owned` is why the waves are collision-free. Commit `promise.md`,
`dag.mmd`, `dag.html` to git alongside the work — they're reviewable artifacts.

## Boundaries

- **No in-flight inheritance.** Plan from zero open PRs on the app repo. If PRs
  are open, close them in a pre-sprint sweep or carry the work as fresh issues —
  never list a pre-existing PR as a sprint node.
- **You don't fire pods.** Planning only. Handing off to the runner (`sprint fire
  N` / `sprint run N`) is a separate, post-approval step.
- **You don't draft DoD the user can't verify.** A wrong DoD is worse than none —
  keep each checklist line mechanical (a command that exits 0, an endpoint shape).

## Result line

End with exactly one of:
- `RESULT: SPRINT_PLANNED N <count>` — after approval + issue creation + promise.md
- `RESULT: SPRINT_DRAFTED N <count>` — draft shown, waiting on the user's approval
- `RESULT: IDLE` — nothing to plan (thesis unclear; ask the user to sharpen it)
