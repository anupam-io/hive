# k8s-sandbox (generalized, one-shot)

A generic company coding agent. Point it at **any repo** + a **GitHub issue**;
it does the work the issue describes, obeying the repo's own `CLAUDE.md`, then
exits and emits its status. One issue = one sandbox = one run.

This directory hosts the per-fire bits: the launcher (`run.sh`), the Sandbox
manifest, and the pod-side image. Day-to-day, you don't invoke `run.sh`
directly — you go through `hivectl fire <ISSUE> --type=<T>` (see `../bin/hivectl`),
which wraps it.

## Design

| Concern | How |
|---|---|
| **What to do** | read from the GH issue (`gh issue view <N> --json title,body,labels`) |
| **The rules / guardrails** | the target repo's `CLAUDE.md` (Claude auto-loads it) |
| **Where Claude runs** | `image/agent.sh` step 3 — `claude -p ... --dangerously-skip-permissions` |
| **Lifecycle** | one-shot: `restartPolicy: Never`, `shutdownPolicy: Delete`, run once, exit |
| **Status** | `SUCCEEDED` / `NEEDS_HUMAN` / `FAILED`, emitted 3 ways (below) |

## Status emission

Every run emits its outcome three ways so anything downstream can read it:

1. **k8s termination message** — `printf "$STATUS" > /dev/termination-log`, surfaced at:
   `kubectl -n agents get pod <pod> -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'`
2. **Mac-side run.log** — `<project>/.hive/runs/<issue-N>-<ts>/run.log` (the full kubectl-logs stream, including the trailing `METRICS: {...}` line).
3. **Stdout line** — `STATUS: <X>` (in `kubectl logs`).

Pod phase also helps: `Succeeded` = SUCCEEDED or NEEDS_HUMAN; `Failed` = FAILED.
(NEEDS_HUMAN exits 0 on purpose — it didn't fail; check the termination message
for the tri-state.)

## Files

| File | What |
|---|---|
| `run.sh` | per-fire launcher (called by `hivectl fire`). Tags + imports the image, sed-substitutes the Sandbox CR, applies, tails logs to the project's `.hive/runs/`. |
| `manifests/namespace.yaml` | `agents` namespace |
| `manifests/secret.example.yaml` | `coding-agent-creds`: Claude + GitHub keys |
| `manifests/sandbox.yaml` | the one-shot Sandbox (sed template) |
| `image/Dockerfile` | image: Claude Code + git + gh + jq + playwright + chromium |
| `image/entrypoint.sh` | auth wiring → `exec agent` or `exec qa-agent` (one-shot) |
| `image/agent.sh` | worker flow (incl. the gating in-pod review): GH issue → clone → claude → PR/comments → review → status. (Merge is a local `hivectl merge`, not a pod fire.) |
| `image/qa-agent.sh` + `qa-capture.mjs` | qa role: playwright capture + claude vision + orphan-branch artifact push + `gh issue create` feedback issue |
| `image/.dev/Dockerfile.delta` | per-session fast-rebuild shortcut. Not in the published image. |

## Setup

Prereq: agent-sandbox controller + CRDs installed (`hivectl setup` does this).

```bash
docker build -t coding-agent:latest ./image

kubectl -n agents create secret generic coding-agent-creds \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-xxxx \
  --from-literal=GH_AUTH_TOKEN=ghp_xxxx
kubectl apply -f manifests/namespace.yaml
```

(Or just: `hivectl agent-setup` — reads `<project>/.env`, builds + imports the
image, creates the secret named in `.hive/config.yaml`.)

## Run one issue

```bash
# via hivectl (recommended)
hivectl fire 42 --type=feature-implementation

# or directly
ISSUE_NUMBER=42 REPO_URL=https://github.com/org/repo ./run.sh 42 "" feature-implementation

# watch
kubectl -n agents logs -f <pod>

# read status after it completes
kubectl -n agents get pod -l issue_id=issue-42 \
  -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.message}'

# cleanup (auto-cleaned by `shutdownPolicy: Delete` + the hive-gc CronJob,
# but you can force it):
kubectl -n agents delete sandbox coding-agent-<app>-issue-42-<ts>
# or: hivectl gc --age=0s
```

## Flow

```
agent (ISSUE_NUMBER, REPO_URL)
  ├─ gh issue view <N> --json title,body,labels   (the task)
  ├─ git clone REPO_URL                           (CLAUDE.md = guardrails)
  ├─ claude -p "<task>; end RESULT: SUCCEEDED|NEEDS_HUMAN" --dangerously-skip-permissions
  │    ├─ SUCCEEDED   -> commit + push + gh pr create + gh issue edit --add-label status:in-review
  │    └─ NEEDS_HUMAN -> gh pr comment (questions) + gh issue edit --add-label status:needs-human
  └─ emit status -> /dev/termination-log + STATUS: line + METRICS: line

qa-agent (WEB_URL, REPO_URL, QA_TARGET)
  ├─ playwright baseline capture (screenshots, console, network)
  ├─ claude + @playwright/mcp drives the browser, produces a UX report
  ├─ git push to orphan branch qa-artifacts/issue-<target>/<ts>/  (no main history)
  └─ gh issue create --label type:qa-feedback   (cross-links #target + artifact branch)
```

## GitHub Issues — what the agent reads and writes

Workers expect the project's repo to follow the canonical label
dictionary (`hivectl labels sync` against `$HIVE_ROOT/.claude/labels.md`):

- `status:*` — exactly one per issue. A worker moves `status:ready` → `status:in-progress`, then its in-pod review sets `status:in-review` (PASS) or `status:changes-requested` (rework); the driver ships `status:in-review` → `status:done`. NEEDS_HUMAN goes to `status:needs-human`.
- `type:*` — exactly one per issue: `feature`, `bug`, `improvement`, `research`, `qa-feedback`.
- `sprint-N` — 0 or 1 per issue. Driver/sprint skill adds these.

Status transitions are enforced as a **mutex**: `gh issue edit <N>
--add-label status:X --remove-label status:Y --remove-label status:Z ...` for
every other status label. See `gh_issue_set_status` in `image/agent.sh`.

## Production notes (later)

- Triggering is manual (`hivectl fire <N>` per issue). To auto-pull work, add a
  webhook receiver that calls `hivectl fire` per new `status:ready` issue.
- Per-fire logs land on the operator's Mac under `<project>/.hive/runs/` —
  fine for one-operator dev, swap to object storage for multi-operator
  deployments.
