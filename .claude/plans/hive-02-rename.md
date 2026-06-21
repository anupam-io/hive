# Phase 2 — Rename heiv→hive, binary→hivectl

Goal: zero `heiv` / `HEIV_` outside `.git`. Project = `hive`, CLI = `hivectl`.

## 2a. Content substitutions (per-file, robust loop)
Run over every tracked text file containing `heiv`, EXCLUDING the plan files:
```
grep -rl "heiv" . --exclude-dir=.git | grep -v '.claude/plans/hive-' | while IFS= read -r f; do
  perl -pi -e '
    s/HEIV_/HIVE_/g;
    s{bin/heiv\b}{bin/hivectl}g;
    s/\bheiv-/hive-/g;
    s/\.heiv\b/.hive/g;
    s/\bheiv (fire|qa|merge|status|tail|logs|metrics|ui|expose|init|config|local-cluster-up|local-cluster-down|setup|agent-setup|driver|doctor|labels|gc|root|help|version|bootstrap)\b/hivectl $1/g;
    s/`heiv`/`hivectl`/g;
  ' "$f"
done
```
Note: `HEIV_`→`HIVE_` also unifies the legacy `HEIV_ROOT`/`HIVE_ROOT` split.

## 2b. File / directory renames
- `bin/heiv` → `bin/hivectl`
- `ops/heiv-gc.yaml` → `ops/hive-gc.yaml`
- `assets/.heiv/` → `assets/.hive/`
- `claude-code-sandbox/image/skills/heiv-{qa,research,bug-fix,feature-implementation,improvement}/`
  → `hive-*/`
(plain `mv`; git staging is the user's job)

## 2c. package.json (hand-edit — name vs binary nuance)
- `"name": "heiv"` → `"hive"`  (PACKAGE name = project = hive, NOT hivectl)
- `"bin": { "heiv": "bin/heiv", "sp": "bin/sp" }` → `{ "hivectl": "bin/hivectl" }`
- `files[]`: `bin/heiv`,`bin/sp` → `bin/hivectl`
- `description`: heiv→hive
- test script: `bash bin/heiv help` → `bash bin/hivectl help`
- repo url already `bear-o-bear/hive` ✓

## 2d. Residue hand-pass (the ~129 bare `heiv` + 4 `HEIV_`)
Decide hive vs hivectl by context:
- **CLI invocations / usage / help / errors / comments about the command** → `hivectl`.
- **Project name / package / "the system" prose** → `hive`.
Known stragglers needing thought:
- `CLAUDE.md` line 1 `# heiv` → `# hive`; line ~72 "npm package `hivectl`"
  is WRONG (backtick rule overreached) → should be "npm package `hive`".
- `ops/driver-settings.json` `$HEIV_ROOT` → `$HIVE_ROOT`.
- `ops/driver-pretty.py` `HEIV_DRIVER_MUTE`, `HEIV_SAY_VOICE` → `HIVE_*`.
- `bin/hivectl` help header / usage strings.
- `.gitignore` `.heiv/` → `.hive/`.
- image skill dir SKILL.md self-references after the dir rename.

## Gate
- `grep -rin 'heiv' . --exclude-dir=.git | grep -v hive-` → 0
- `grep -rn 'HEIV_' . --exclude-dir=.git` → 0
- `grep -rn 'HEIV_ROOT\|HIVE_ROOT' bin/hivectl` → only `HIVE_ROOT`

## Status: ~90% applied. Remaining: 2b file/dir renames, 2c package.json,
## 2d residue (4 HEIV_, ~129 bare heiv).
