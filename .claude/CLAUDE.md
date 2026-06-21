# hive

A generic, **one-shot coding agent** that runs Claude Code against any repo
from a **GitHub issue**. **Per-project** by design — you run `hivectl` inside
an app repo and it scopes everything (pods, secrets, logs, ui) to that
project. One cluster can host fleets for many projects at once via the
`app=` label.

## What this repo is (and is not)

- **Is:** infra — the k8s manifests, Docker image, bash glue, ops scripts,
  config scaffolding, and CLI that turn `hivectl fire <ISSUE>` into one pod
  that opens a PR.
- **Is not:** application code. Target apps (e.g. `chain-monitor`) live in
  separate repos. Each app keeps its own rules in `<app>/.claude/CLAUDE.md`
  + `.claude/skills/<TASK_TYPE>/SKILL.md` — the agent auto-loads those.

## Issue tracker

**The tracker is GitHub Issues in the same repo as the code.** There is no
separate ticket system, no Linear, no kanban dirs, nothing else.

- A "fire" is `hivectl fire <ISSUE> --type=<T>`, where `<ISSUE>` is a GH issue
  number (`42`) or the canonical id (`issue-42`).
- The branch is `agent/issue-N`; the PR targets `base_branch` (default `main`).
- Lifecycle is tracked with labels: exactly one `status:*` and one `type:*`
  per issue, plus an optional `sprint-N`. Pods enforce the mutex via
  `gh issue edit --add-label X --remove-label Y`.
- The canonical label dictionary lives at `$HIVE_ROOT/.claude/labels.md`;
  sync into a project's repo with `hivectl labels sync` (idempotent).

## The per-project model

Run `hivectl init` inside an app repo. It scaffolds `.hive/` from
`assets/hive/` with placeholder substitution (app name, repo URL, kubectl
context). After that, every `hivectl` invocation reads `.hive/config.yaml`
and tags everything it creates with `app=<that app>` so multiple projects
sharing one cluster never collide.

| Location | Owner | What lives there |
|---|---|---|
| `$HIVE_ROOT` (package install dir) | read-only | `bin/hivectl`, `Makefile`, `assets/`, `manifests/`, `ops/`, `.claude/agents/driver.md`, `.claude/labels.md` |
| `$HIVE_STATE_DIR` (default `$HOME/.hive`) | global per-user | the fallback `.env`, machine-wide bookkeeping |
| `<project>/.hive/` | per-project | `config.yaml`, `runs/<issue-N>-<ts>/run.log`, `handoff/sprint-N.md` — always gitignored |

Project-scoped commands (`fire`, `qa`, `merge`, `tail`, `logs`, `metrics`,
`ui`, `driver`, `agent-setup`, `labels`, `gc`) **bail** with "run `hivectl init`
first" if the cwd has no `.hive/config.yaml`. Cluster-wide commands
(`setup`, `local-cluster-up`/`-down`, `init`, `config`, `doctor`, `root`,
`help`) do not.

## Layout

| Path | What |
|---|---|
| `bin/hivectl` | the `hivectl` CLI — config loader, project resolver, dispatcher. Shells into the Makefile for the heavy targets. |
| `assets/hive/` | the project-config template `hivectl init` scaffolds: `config.yaml` (the `.gitignore` is written by `hivectl init` in code, not shipped here). |
| `.claude/agents/driver.md` | driver agent definition. Loaded into the local claude session by `hivectl driver` via `--append-system-prompt`. Source of truth for driver behaviour — app repos no longer hold a copy. |
| `.claude/skills/sprint-plan/SKILL.md` | sprint **coordinator** — decomposes a thesis into 20–30 right-sized issues, assigns file ownership, builds the dependency DAG, topo-sorts into parallel waves, renders the graph (Mermaid + `dag.html`) for human review, writes `promise.md` on approval. Ships `wave-sort.mjs` (deterministic wave layering). |
| `.claude/skills/sprint/SKILL.md` | sprint **runner** — `run / fire / status / close` sub-actions. `run N` fires the precomputed waves to completion unattended; release is delegated to the driver. Sprint = labelled batch of issues (`sprint-N`) delivered through dependency-ordered waves. |
| `.claude/skills/sprint-resume/SKILL.md` | sprint **resume gate** — re-entering a running sprint (fresh session, heartbeat wake, post-crash) reconstructs true wave state from GH labels + open PRs + live pods before any new fire, so AUTO mode can't double-fire in-flight pods. Ships `reconcile.sh` (deterministic per-issue classifier). |
| `.claude/labels.md` | canonical label dictionary (`status:*`, `type:*`, `sprint-N`). `hivectl labels sync` reads it. |
| `Makefile` | underlying targets `hivectl` wraps. |
| `ops/` | install scripts (`install.sh`, `metrics-server.sh`, `prometheus.sh`, `agent-sandbox.sh`, `headlamp.yaml`), local cluster (`local-cluster-up.sh`, `local-cluster-down.sh`), per-fire setup (`claude-code-setup.sh`), helpers (`agent-metrics.sh`, `agents-logs.sh`, `afk.sh`), GC CronJob (`hive-gc.yaml`). |
| `ops-ui/` | the agent run-analytics UI (Python http.server + SSR). Reads from the active project's `.hive/runs/`. |
| `k8s-sandbox/run.sh` | per-fire launcher: builds image, imports into the local cluster (auto-detects minikube/kind/k3d/dd), sed-substitutes the manifest, applies, exits. |
| `k8s-sandbox/manifests/sandbox.yaml` | the per-fire Sandbox CR template — placeholders for `${APP}`, `${AGENT_NAME}`, `${SECRET_NAME}`, `${AGENTS_NAMESPACE}`, `${ISSUE_ID}`, etc. |
| `k8s-sandbox/image/Dockerfile` | base image `coding-agent`: node22 + bun + claude-code + git + gh + jq, runs as uid 1000 (worker). |
| `k8s-sandbox/image/Dockerfile.qa` | `web-qa-agent`: `FROM coding-agent` + playwright + chromium for the qa role only (keeps the ~1.18GB browser off the worker fire). |
| `k8s-sandbox/image/{entrypoint,agent,qa-agent}.sh` | pod-side flows. `agent.sh` is the worker issue loop; `qa-agent.sh` is the qa role; `entrypoint.sh` wires auth. |
| `k8s-sandbox/image/qa-capture.mjs` | playwright Stage-0 capture for the qa role. |
| `package.json` | npm package `hive`. `files:` whitelist controls what `npm publish` ships. Per-project `.hive/` is NEVER inside the package. |

## How to operate

The operator surface is the `hivectl` CLI. `hivectl` wraps the Makefile — both
work, prefer `hivectl`. Workers and qa run inside pods; they have
no docker socket, no kubectl, no `hivectl`. They only edit files → push →
comment-on-PR → update-issue-via-`gh`.

```bash
# one-time, per machine
hivectl bootstrap                                 # one-shot: doctor → local-cluster-up → setup
hivectl local-cluster-up                          # minikube + vfkit, profile=local-cluster
hivectl doctor                                    # check host CLIs
hivectl setup                                     # metrics-server + prom + sandbox CRDs + headlamp + hive-gc

# one-time, per project
cd ~/my-app
hivectl init                                      # scaffolds .hive/config.yaml
hivectl labels sync                               # push status:*/type:* labels into the repo
hivectl agent-setup                               # builds image + creates <app>-creds secret

# fleet (must be inside a project dir)
hivectl fire 42 --type=research                   # one worker against GH issue #42
hivectl qa --url=http://web.my-app.svc.cluster.local:3000 --target=40
hivectl merge 42                                  # rebase + merge agent/issue-42's open PR
hivectl status 42 in-review                       # set the issue's status:* label (mutex-enforced)
hivectl tail 42                                   # live-tail (filtered by app=)
hivectl logs                                      # this project's run dirs
hivectl metrics [42]                              # cost/tokens/duration table
hivectl ui                                        # analytics UI (auto-picks free port from 8001)
hivectl expose                                    # port-forward prom+headlamp+app and start ui (one process)
hivectl gc                                        # delete this project's Sandbox CRs > 30m old

# driver — a local claude session inside the project
hivectl driver                                    # opens `claude` in cwd with driver.md appended

# misc
hivectl config                                    # show resolved project config
hivectl config set <k>=<v>                        # edit one key
hivectl root                                      # print install dir
hivectl help
make headlamp-token                            # mint a 10-year admin token (make only)
```

`--type` (one of): `feature-implementation | bug-fix | improvement |
research`. The target repo's `.claude/CLAUDE.md` owns the
routing; the sandbox passes it as a hint via env. (`pr-review` and
`pr-merge` are retired — the worker reviews and gates its own PR in-pod,
and the merge is a local `hivectl merge` (no pod), never raw `gh pr merge`.)

## Cluster facts (local dev)

Default local cluster is **minikube + vfkit** on macOS (`hivectl local-cluster-up`).
Single-node, profile name = `local-cluster` (= kubectl context name). Apple's
Virtualization framework — no docker, no Docker Desktop, no qemu wrapper.

- **Image flow:** two images, both `:latest`, built + imported into the
  local cluster **once** by `hivectl agent-setup` (`ops/claude-code-setup.sh`,
  steps 2-3): `coding-agent` (worker — lean, no browser) and
  `web-qa-agent` (qa only — `FROM coding-agent` + playwright + chromium, the
  ~1.18GB the other roles never open). `run.sh` selects the image by `$ROLE`.
  Import auto-detects the cluster: `docker-desktop` (auto-visible),
  `kind-*` (`kind load`), `k3d-*` (`k3d image import`), minikube
  (`minikube image load`) — done per image. A fire does **not** build, re-tag,
  or re-load — it just references the image already in the cluster
  (`imagePullPolicy: IfNotPresent`). So the images share the secret's lifecycle:
  recreate the cluster → re-run `hivectl agent-setup` to restore them, else the pod
  ImagePullBackOffs.
- **LoadBalancer:** minikube has no built-in LB. Run `minikube tunnel -p local-cluster`
  in a separate terminal to expose LB services on Mac, or `kubectl port-forward`
  per service.
- **Pods can't see Mac filesystem.** Only path pod → Mac is `kubectl logs -f`.
- **Agent pool namespace:** `agents` (cluster-shared). Per-project secrets
  named `<app>-creds` live there.
- **Pod auto-cleanup:** `shutdownPolicy: Delete` removes the pod the moment
  its container exits. The Sandbox CR itself is GC'd by the `hive-gc`
  CronJob (every 10 min, ages > 30 min), or run `hivectl gc` manually.
- **Monitoring:** `monitoring` ns runs Prometheus + kube-state-metrics +
  node-exporter + pushgateway. Pod cost/token gauges are pushed to
  `pushgateway.monitoring.svc.cluster.local:9091`. The Prometheus Service
  is `prometheus` — Headlamp auto-detects it.

## Conventions

### `## Definition of Done` (every issue, every fire)

Every GitHub issue the fleet works on carries a `## Definition of Done`
H2 section in its body, with at least one `- [ ]` checklist line of
verifiable predicates (a command that exits 0, an endpoint that returns
a known shape, files staying inside a scope). The driver refuses to
fire a worker on an issue without one and posts a comment asking for it
— **no auto-stub**, because an LLM-written DoD that's subtly wrong is
worse than no DoD (the review passes work that doesn't match human
intent). On success the worker runs an **independent in-pod review**
(a fresh `claude` process — `run_review` in `agent.sh`) that grades each
checklist line and ends with a `**DoD verdict**` table + a
`REVIEW: PASS | CHANGES_REQUESTED` verdict; `CHANGES_REQUESTED` flips the
issue to `status:changes-requested` (the driver re-fires a worker), `PASS`
flips it to `status:in-review` (the driver merges). There is **no separate
reviewer pod** — review and merge are split between the worker (gates) and
the driver (merges), so the pod that wrote the code never ships it. The
worker pod is told the checklist is the authoritative success criterion.
The worker addendum + the in-pod review live in
`k8s-sandbox/image/agent.sh`; the driver pre-fire check + merge
orchestration live in `.claude/agents/driver.md`.

**One exception — `type:qa-feedback` issues.** These are filed by the qa
role against already-shipped work, so the finding text *is* the human
intent. For these only, the driver drafts the DoD (one verifiable line per
concrete defect in the finding) rather than refusing — the in-pod review
still grades each line and the release PR stays human-visible, so the agent
isn't unilaterally grading its own homework. Every other type keeps the
no-auto-stub rule. See the `type:qa-feedback` carve-out in
`.claude/agents/driver.md`.

### Communication templates (every harness-posted body, every model-filled brief/review)

Every PR body, every issue status comment, every NEEDS_HUMAN PR comment, and
every per-task brief / in-pod review the fleet posts is rendered from a markdown
template in `k8s-sandbox/image/templates/` so the formatting doesn't
drift between agents, fires, or roles.

| Template | Used by | Filled by |
|---|---|---|
| `pr-body.md` | `ensure_pr_exists` on `gh pr create` | harness — issue link, DoD pointer, commit body, run metadata |
| `issue-status.md` | `gh_issue_status_comment` | harness — status, chatid, branch, PR, model, hammers, cost |
| `pr-needs-human.md` | `pr_needs_human_comment` (unified for worker/merge) | harness — reason, next-step hint, optional open-questions block |
| `review-brief.md` | the worker's in-pod review (`run_review`) | model — verdict, DoD table, plan adherence, risks |
| `<type>-brief.md` | the worker, wrapped in `<!--HIVE_BRIEF-->` markers | model — per-task-type summary of the work |

Rendering uses `envsubst` with a strict variable whitelist (see
`TEMPLATE_VARS` in `agent.sh`) so a template can include literal `$foo`
or shell-escape sequences without losing them. The image installs
`gettext-base` for `envsubst` and copies the templates to
`/opt/hive/templates/`. To add a placeholder, add the env var to the
whitelist; to add a template, drop it in the directory and call
`render_template <name>.md`.

The in-pod review skeleton (`review-brief.md`) is fed to the review process
verbatim, and the review's verdict line (`REVIEW: PASS | CHANGES_REQUESTED`)
plus the `**coding-agent review** — <VERDICT>` comment header are load-bearing:
the driver reads the verdict to decide merge-vs-re-fire, and a re-fired worker
reads the review's `**Changes requested:**` block.

### `## Plan` (every issue, every fire)

Every issue also carries a `## Plan` H2 section: goal, constraints,
format of done, failure mode, files likely touched. The worker reads
it as authoritative scope; the in-pod review flags any out-of-Plan diff as
an issue even if the code is otherwise good. Unlike DoD, the driver IS
empowered to draft Plans — that's what action C does. When the driver
encounters an existing issue without a Plan, it appends a
`## Plan (proposed by driver)` block (note the exact parenthetical),
flips status to `needs-human`, and waits. A human renames the heading
to plain `## Plan` to approve and flips status back to `ready`. The
exact heading text matters: `## Plan` fires, `## Plan (proposed by driver)`
does not — `agent.sh` double-checks at pod startup so a misconfigured
driver can't bypass the gate.

## Hard rules

- **Never read `.env`.** Persona-level — no `cat`, `Read`, `grep`. Only `kubectl create secret --from-env-file` ever touches it.
- **Never commit/push without explicit USER approval** (`commit`, `push`, `/cnp`). USER handles all git ops.
- **Never add initContainers, sidecars, or hostPath mounts** to `manifests/sandbox.yaml`. The manifest stays minimal: emptyDir for workspace, no `/logs`.
- **Model policy.** Every ephemeral pod (worker in all modes, qa) runs **Sonnet**; the worker's in-pod gating review also runs Sonnet (`REVIEW_MODEL`). Only the local **driver** runs **Opus 4.8** (`claude-opus-4-8`, overridable via `HIVE_DRIVER_MODEL`) — never Fable 5, never Haiku. Pod model is set in `run.sh` (`MODEL`, default `sonnet`); the driver model in `bin/hivectl` + `ops/driver-loop.sh`.
- **Per-role resource ceilings are guardrails, not budgets.** `run.sh` sets pod `limits` from `$ROLE`: worker → `cpu=1, memory=2Gi`; qa → `cpu=2, memory=4Gi`. Override per-fire with `CPU_LIMIT=… MEM_LIMIT=… hivectl fire …`. Requests stay modest (`250m / 512Mi`); k8s OOM-kills past memory and throttles past CPU.
- **Per-task $USD spend cap.** Per task type, not flat (set in `run.sh`): the three coding modes + research → `$5`, qa → `$2`. Precedence: `COST_LIMIT_USD` env > project config (`defaults.cost_limit_usd` → `HIVE_DEFAULT_COST_LIMIT_USD`, a flat override) > the per-task default. Plumbed to claude code's native `--max-budget-usd`; `agent.sh` passes the REMAINING budget across hammers so the cap is per-fire, not per-hammer. The worker's independent **in-pod review** sub-run (the gating review, `run_review`) carries its OWN `$2` budget (`REVIEW_COST_LIMIT_USD`, model `REVIEW_MODEL`=`sonnet`) ON TOP of the task cap; reported `cost_usd` combines both (= `primary_cost_usd` + `selfreview_cost_usd`, where `selfreview_cost_usd` now carries the in-pod review's cost). Override per-fire with `COST_LIMIT_USD=… hivectl fire …`. Cap-hit shows as `cost_cap_hit:true` in the `METRICS:` line. This is a per-fire CEILING (headroom for a hard task), not expected spend — actual aggregate is bounded per-sprint by `sprint_budget_usd`.
- **The qa role NEVER reads source code.** A qa fire never `git clone`s the code tree and never checks out `main`. It does have a GH token — but only to (a) push QA artifacts (screenshots, logs) to an ORPHAN branch `qa-artifacts/issue-<N>/<ts>/*` (orphan = no shared history with `main`), and (b) `gh issue create` a `type:qa-feedback` issue cross-linking the verified issue. qa never edits existing issues, never opens a PR, never pushes to any branch other than `qa-artifacts/*`.
- **`.hive/` is gitignored**, always. Templates ship from `assets/hive/` — never read user state from there.
- **Status mutex.** Every issue and PR carries exactly one `status:*` label. When transitioning, ALWAYS remove the previous status label in the same `gh issue edit` / `gh pr edit` call.
- **Don't write new docs / new make targets / new hivectl subcommands / new ops scripts unless asked.** Minimal-change default.

## Metrics

Every agent run emits a single `METRICS: {json}` line to its `run.log` after claude finishes, capturing: `issue_id, issue_number, task_type, repo, repo_slug, role, model, wall_s, cost_usd, primary_cost_usd, selfreview_cost_usd, duration_ms, num_turns, input_tokens, output_tokens, cache_read, cache_creation, hammers, hammer_max, cost_cap_hit`. The aggregator (`ops/agent-metrics.sh`, `hivectl metrics`) greps `^METRICS:` across `<project>/.hive/runs/*/run.log` to produce a table + totals.

## Pointers

- Driver agent (orchestrator role, lives in hive): `$HIVE_ROOT/.claude/agents/driver.md`
- Sprint coordinator (plan → DAG → waves): `$HIVE_ROOT/.claude/skills/sprint-plan/SKILL.md`
- Sprint runner (fire waves → close): `$HIVE_ROOT/.claude/skills/sprint/SKILL.md`
- Sprint resume gate (reconcile before re-firing): `$HIVE_ROOT/.claude/skills/sprint-resume/SKILL.md`
- Label dictionary: `$HIVE_ROOT/.claude/labels.md`
- Target repo's per-role agents (in-pod, app-specific): `<app>/.claude/agents/worker.md`
- Target repo's per-type skills: `<app>/.claude/skills/<TASK_TYPE>/SKILL.md`
- Headlamp UI: `kubectl -n headlamp port-forward svc/headlamp 4001:4001` → `http://localhost:4001` (token via `make headlamp-token`)
- Prometheus UI: `kubectl -n monitoring port-forward svc/prometheus 9090:9090` → `http://localhost:9090`
- Agent analytics UI: `hivectl ui` → `http://localhost:8001` (or next free port)

---

## Resume protocol

In-flight work for the active project lives in `<project>/.hive/handoff/sprint-N.md`
— one file per sprint, the latest one is the active handoff. The directory
is the driver's working scratch; it freely writes here. The driver also writes
**committed sprint artifacts** under `<project>/.claude/sprints/sprint-N/` (`promise.md`,
`dag.mmd`, `dag.html`, `result.md` — reviewable alongside the work). Those two
paths aside, it does NOT write anywhere else in the project. **At session start,
before suggesting any action:**

1. Confirm cwd has `.hive/config.yaml` — if not, the user is outside any project; ask which to switch to.
2. `git status` + `git log --oneline -10` — what's committed, what's in-flight.
3. Read the latest `.hive/handoff/sprint-*.md` — latest checkpoint, locked decisions, what's pending.
4. Issue board check: `gh issue list --label sprint-<active> --state all --json number,title,labels` (or omit the sprint filter on the very first read). Bucket by `status:*` label.
5. Read `<project>/.claude/agents/{driver,worker}.md` if the next step touches role behaviour.
6. Surface a short status, then **ask USER which step to advance**. Don't pick the next step alone.

When work advances or decisions change, update the current `sprint-N.md` —
it's the source of truth for "where are we now". `CLAUDE.md` only changes
when stable project rules change.
