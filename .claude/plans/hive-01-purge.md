# Phase 1 — Purge dead layers

Goal: remove the spidey/sp-core control-plane experiment and dev scratch so
only the live `hive` system remains.

## Why
The repo has three historical layers; only the heiv/hive one is live.
`sp-core/`, `spidey-runtime/`, `bin/sp` are referenced by nothing in the
running system (confirmed: only old plan docs + a `"sp": "bin/sp"` package
entry pointed at them).

## Delete (working tree)
```
spidey-runtime/            sp-core/            bin/sp
docs/                      kanban/             handoff.md
.claude/handoff.md
.claude/findings/   .claude/todos/   .claude/scheduled_tasks.lock
.claude/plans/*            (KEEP the hive-*.md plan files)
```

## Keep
- Live system: `bin/`, `Makefile`, `assets/`, `claude-code-sandbox/`, `ops/`,
  `ops-ui/`, `package.json`, `CLAUDE.md`.
- `.claude/{agents,skills,labels.md}` and the `hive-*.md` plan files.
- Local creds `auth.json`, `service-account-token.txt`, `.env` — gitignored +
  npmignored, user-owned. Do NOT delete or read.

## Gate
- `grep -rli 'spidey\|sp-core' . --exclude-dir=.git` → only the plan files.
- `package.json` no longer lists `bin/sp` (handled in Phase 2).

## Status: APPLIED (uncommitted)
