# Phase 4 — Publish-readiness

Goal: the repo is safe and clean to push public + `npm publish`.

## 4a. README.md (new)
Sections:
- What hive is (one-shot coding-agent fleet; per-project; GitHub-issue driven).
- Requirements (kubectl, docker, gh, jq, yq, envsubst, claude, minikube+vfkit).
- Install (`npm i -g hive` → `hivectl`).
- Quickstart: `hivectl bootstrap` → `cd my-app && hivectl init` →
  `hivectl agent-setup` → `hivectl fire 42 --type=research`.
- Command reference (mirror `hivectl help`).
- Link to CLAUDE.md for architecture.
Keep it tight; no marketing fluff.

## 4b. Package hygiene
- `package.json` `files[]` ships only: `bin/hivectl`, `Makefile`, `assets/**`,
  `k8s-sandbox/{run.sh,README.md,manifests/*.yaml,image/...}`,
  `.claude/{agents,skills,labels.md}`, `ops/**`, `ops-ui/*.py`,
  `CLAUDE.md`, `README.md`. Confirm no `bin/sp`, no `sp-core`, no `docs/`.
- `.npmignore` / `.gitignore` still exclude `.env*`, `auth.json`,
  `service-account-token.txt`, `.hive/`, `__pycache__`.
- Confirm no secrets in git history (already verified clean: auth.json,
  service-account-token.txt, .env never committed).

## 4c. Final verification (all must pass)
1. `bash bin/hivectl help` exits 0.
2. `grep -rin 'heiv\|spidey\|sp-core' . --exclude-dir=.git | grep -v hive-` → 0.
3. `grep -rn 'HEIV_' . --exclude-dir=.git` → 0.
4. `bash bin/hivectl version` → `0.1.4`.
5. `npm pack --dry-run` file list reviewed — clean tree, no scratch/secrets.

## Hand-off to user
- Agent does NOT commit/branch/push or `npm publish`. Surface a summary and
  let the user drive git + release.

## Status: not started.
