# Phase 3 — Smooth CLI

Goal: the five commands feel first-class. Four already exist (rename only);
two are new.

## Existing (renamed in Phase 2, verify they dispatch)
- `hivectl local-cluster-up`   → `make -C $HIVE_ROOT local-cluster-up`
- `hivectl local-cluster-down` → `make -C $HIVE_ROOT local-cluster-down`
- `hivectl status`             → existing status handler
- `hivectl driver`             → opens a Claude Code instance
  (`exec claude --append-system-prompt $(cat .claude/agents/driver.md) …`)

## New: `hivectl version`
- Prints the version from `package.json` (`$HIVE_ROOT/package.json`).
- Implementation: read with `node -p` if available, else grep the `"version"`
  line — keep it dependency-free (it's a bash CLI). Suggest:
  `awk -F'"' '/"version"/{print $4; exit}' "$HIVE_ROOT/package.json"`.
- Add `version` (and `--version`/`-v` alias) to the dispatch + help text.
- Place in the cluster-wide group (no `.hive/config.yaml` required).

## New: `hivectl bootstrap`
- One-shot fresh-machine setup = chain existing steps with clear progress:
  1. `doctor`            (host CLIs present?)
  2. `local-cluster-up`  (minikube + vfkit)
  3. `setup`             (metrics-server + prometheus + sandbox CRDs + headlamp + hive-gc)
- Stop on first failing step with a readable message ("bootstrap: step N
  (<name>) failed — fix and re-run `hivectl bootstrap`").
- Print a final "next: cd into your app repo and run `hivectl init`".
- Cluster-wide group (no project config required).
- Add to help under "Infra setup (one-time)".

## Gate
- `bash bin/hivectl help` lists `version` and `bootstrap`.
- `bash bin/hivectl version` prints `0.1.0`.
- `bootstrap` dispatch chain traced (cluster steps need a host; dry-verify
  the ordering + early-exit if headless).

## Status: not started.
