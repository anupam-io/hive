# Hive label dictionary

Source of truth for every GitHub issue label hive manages. `hivectl labels sync`
reads this file and calls `gh label create --force` against the project's repo
so the labels exist and have consistent color + description.

**Invariants** (driver enforces; CLAUDE.md documents):

- Exactly one `status:*` label per issue at any time.
- Exactly one `type:*` label per issue at any time.
- At most one `sprint-N` label per issue.

The dictionary below is the FULL set hive writes. Anything else is project-local
and outside hive's authority — hive won't create, change, or remove it.

## Status (workflow state — mutually exclusive)

| Label | Color | Description |
|---|---|---|
| `status:ready` | `#0E8A16` | Triaged, scoped, ready for a worker to pick up |
| `status:in-progress` | `#1D76DB` | A worker pod is actively firing on this |
| `status:in-review` | `#FBCA04` | Worker opened a PR and its in-pod review returned PASS; awaiting merge by the driver |
| `status:changes-requested` | `#E99695` | Worker's in-pod review returned CHANGES_REQUESTED; the driver re-fires a worker to address the findings |
| `status:needs-human` | `#D93F0B` | Blocked on a human decision; agent posted questions on the PR/issue |
| `status:done` | `#5319E7` | Closed: PR merged or issue resolved without code change |

## Type (task type — mutually exclusive; replaces TASK_TYPE env)

| Label | Color | Description |
|---|---|---|
| `type:feature` | `#1D76DB` | New feature implementation |
| `type:bug` | `#D93F0B` | Bug fix |
| `type:improvement` | `#0E8A16` | Refactor, polish, or quality work on existing code |
| `type:research` | `#5319E7` | Investigation / write-up only; no PR expected |
| `type:qa-feedback` | `#E99695` | Filed by the QA role; cross-links the target issue |

## Sprint (batch tag — at most one per issue)

`sprint-N` where N is the sprint number. `hivectl labels sync` creates the labels
that exist in `.hive/handoff/sprint-*.md`; it never deletes old sprint labels
(history is useful). Color `#C5DEF5` (light blue) for all.

## Not managed by hive

Anything outside the three namespaces above is project-local. Hive reads it but
never writes it. Common examples:

- `area:*` — per-app area tags (frontend, backend, infra). Owned by the project.
- `priority:*` — per-team priority scheme. Owned by the project.
- `good-first-issue`, `help-wanted` — GitHub built-ins. Owned by the project.
