# hive migration — master index

Rename the project to **hive**, the CLI to **hivectl**, purge the dead
spidey/sp-core layers, add a smooth bootstrap, make it publish-ready.
No `heiv`, `spidey`, `sp-core`, or `HEIV_` anywhere outside `.git`.

Global config: `~/.hive`. Per-project config: `.hive/`.

## Phase plans (execute in order)

1. [hive-01-purge.md](hive-01-purge.md) — delete dead layers + dev scratch.
2. [hive-02-rename.md](hive-02-rename.md) — heiv→hive, binary→hivectl, vars/paths/files.
3. [hive-03-cli.md](hive-03-cli.md) — smooth CLI: status/version/driver + new `bootstrap`.
4. [hive-04-publish.md](hive-04-publish.md) — README + npm pack hygiene + final verify.

## Naming rules (apply in every phase)

- **Project / system / npm package / concept** → `hive`.
- **CLI command / binary / invocation** → `hivectl`.
- **Env vars** `HEIV_*` → `HIVE_*`; unify the legacy `HEIV_ROOT`/`HIVE_ROOT`
  split → single `HIVE_ROOT`.
- **Paths** `.heiv/`→`.hive/`, `$HOME/.heiv`→`$HOME/.hive`, `assets/.heiv/`→`assets/.hive/`.
- **Identifiers** `heiv-gc`→`hive-gc`; image skill dirs `heiv-*`→`hive-*`.

## Locked decisions

- Cleanup scope = **full purge**.
- `bootstrap` = **cluster + infra one-shot** (`doctor → local-cluster-up → setup`).
- README = **yes**.
- `.heiv/`→`.hive/` is a breaking change — intended (fresh publish).
- Git is the user's: no commit/branch/push by the agent.

## CURRENT STATE (as of last session, uncommitted working tree)

- Phase 1: **APPLIED** (deletions done).
- Phase 2: **~90% applied** — `HEIV_`→`HIVE_` + command renames in tree;
  NOT done: file/dir renames, 4 `HEIV_` stragglers, ~129 prose `heiv` hits.
- Phases 3–4: not started.
- Decision pending from user: revert to clean (`git checkout`/`clean`) and
  run from these plans, OR keep current tree and resume mid-Phase-2.
