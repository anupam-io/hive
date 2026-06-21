#!/usr/bin/env bash
set -uo pipefail   # not -e: we trap failures ourselves so we always emit status
# Generalized ONE-SHOT coding agent.
#   Inputs (env or args): ISSUE_NUMBER, REPO_URL
#   Task   -> read from the GitHub issue (title + body) via `gh issue view`
#   Rules  -> the repo's own CLAUDE.md (Claude Code auto-loads it)
#   Output -> a PR (or questions on the issue/PR) + an emitted status:
#             SUCCEEDED | NEEDS_INFO | FAILED
#   All output goes to stdout — kubectl logs is the single source of truth.
#   run.sh tees that into <project>/.hive/runs/<run>/run.log live.

ISSUE_NUMBER="${1:-${ISSUE_NUMBER:?set ISSUE_NUMBER (e.g. 42)}}"
REPO="${2:-${REPO_URL:?set REPO_URL}}"
BASE_BRANCH="${BASE_BRANCH:-main}"   # branch the agent forks from + PR targets
# Set early: the in-pod review (run_review) and render_template both read it.
TEMPLATES_DIR="${HIVE_TEMPLATES_DIR:-/opt/hive/templates}"

# Prompt renderer — the sibling of render_template (defined later) for the
# LLM *input* prompts (worker task, hammer continuation, in-pod review). It
# carries its own whitelist because these interpolate the issue/diff locals,
# not the output-template vars. A missing prompt file would silently truncate
# the prompt the model runs on, so treat it as FATAL, not a warning.
PROMPT_VARS='$ISSUE_NUMBER $ISSUE_TITLE $ISSUE_DESC $TASK_TYPE $BRANCH $BASE_BRANCH $EXISTING_PR_URL $CONFLICT_FILES $REVIEW_DIFF $REVIEW_SKELETON $HAMMER_N $HAMMER_MAX'
render_prompt() {  # render_prompt <basename.md>
  local path="$TEMPLATES_DIR/$1"
  [ -r "$path" ] || { echo "[agent] FATAL: prompt template missing: $path" >&2; exit 1; }
  envsubst "$PROMPT_VARS" < "$path"
}

# The issue identifier used in branch names, run dirs, and METRICS is
# `issue-<N>`. ISSUE_NUMBER is the bare digits passed to every `gh issue ...`
# call. Decoupling them keeps `gh` args clean.
ISSUE_ID="issue-${ISSUE_NUMBER#issue-}"
ISSUE_NUMBER="${ISSUE_NUMBER#issue-}"  # tolerate either "42" or "issue-42"

# Pre-flight input validation. Catches one common misfire where shell
# mis-splitting fed an issue id as $REPO; git clone failed with a confusing
# error. Fail fast and clearly so a bad fire never touches the workspace.
case "$REPO" in
  https://*|http://*|git@*) : ;;
  *) echo "[agent] FATAL: REPO_URL not a valid clone URL: '$REPO'" >&2; exit 2 ;;
esac
case "$ISSUE_NUMBER" in
  ''|*[!0-9]*) echo "[agent] FATAL: ISSUE_NUMBER must be a positive integer: '$ISSUE_NUMBER'" >&2; exit 2 ;;
esac
case "${TASK_TYPE:-}" in
  feature-implementation|bug-fix|improvement|research|"") : ;;
  qa) echo "[agent] FATAL: agent.sh invoked with TASK_TYPE=qa — entrypoint.sh should have dispatched to qa-agent" >&2; exit 2 ;;
  pr-review|pr-merge) echo "[agent] FATAL: TASK_TYPE=$TASK_TYPE is retired — the worker reviews + gates its own PR in-pod, and merge is now a local \`hivectl merge\` (not a pod fire). Re-fire the worker, or run \`hivectl merge\` for the merge." >&2; exit 2 ;;
  *) echo "[agent] FATAL: TASK_TYPE not in allowlist: '$TASK_TYPE' (allowed: feature-implementation|bug-fix|improvement|research|qa)" >&2; exit 2 ;;
esac

REPO_NAME="$(basename "${REPO%.git}")"
# gh wants <owner>/<name>, derive once from REPO_URL.
REPO_SLUG="$(echo "$REPO" | sed -E 's|^.*github\.com[:/]||; s|\.git$||')"
RUN_START_EPOCH=$(date +%s)

# ── Status emission ───────────────────────────────────────────────────────────
emit() {  # emit <STATUS> [detail]
  echo "STATUS: $1${2:+ :: $2}"
  printf '%s' "$1" > /dev/termination-log 2>/dev/null || true
  STATUS_EMITTED=1
}
fail() { emit FAILED "$1"; exit 1; }

# Never exit without a status. Captures rc != 0 paths that bypassed emit.
STATUS_EMITTED=0
trap 'rc=$?; if [ "$STATUS_EMITTED" = 0 ]; then emit FAILED "agent.sh exited rc=$rc at line $LINENO without emit"; fi' EXIT

echo "=== coding-agent: issue=#$ISSUE_NUMBER repo=$REPO_SLUG ==="

# 1. Read the task from the GitHub issue.
issue_json=$(gh -R "$REPO_SLUG" issue view "$ISSUE_NUMBER" --json number,title,body,labels 2>&1) \
  || fail "gh issue view failed: $issue_json"
title=$(echo "$issue_json" | jq -r '.title // empty')
desc=$(echo  "$issue_json" | jq -r '.body  // ""')
[ -n "$title" ] || fail "issue #$ISSUE_NUMBER returned no title (response: $(echo "$issue_json" | head -c 200))"
echo "[agent] #$ISSUE_NUMBER — $title"

# 2. Clone the repo. Claude auto-loads its CLAUDE.md (the guardrails).
#    If the agent branch already exists on the remote (a previous run pushed),
#    start FROM that branch so this run iterates on the existing PR rather than
#    re-branching from main (which would create non-fast-forward push errors).
WORK=/workspace/repo
rm -rf "$WORK"
branch="agent/${ISSUE_ID}"
git clone -q "$REPO" "$WORK" || fail "git clone failed"
cd "$WORK"
EXISTING_BRANCH=0
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  git checkout -q -b "$branch" "origin/$branch" || fail "checkout of existing $branch failed"
  echo "[agent] iterating on existing $branch ($(git rev-parse --short HEAD))"
  EXISTING_BRANCH=1
else
  git checkout -q -b "$branch" "origin/$BASE_BRANCH" || fail "checkout from $BASE_BRANCH failed"
  echo "[agent] new $branch from $BASE_BRANCH ($(git rev-parse --short HEAD))"
fi

# 1b. Ship hive's systematic-stage skill for this task type into the workspace
# so Claude Code auto-loads it. It lives in hive's OWN skill namespace
# (.claude/skills/hive-<TASK_TYPE>/), distinct from the app's own
# <TASK_TYPE> skill — so we can safely ALWAYS overwrite (we only ever clobber
# hive's namespace, never the application's skills). The skill encodes the
# required stages (explore → understand → best practices → mode core → test →
# compile & lint). Only the three coding modes ship one.
SKILLS_SRC="${HIVE_SKILLS_DIR:-/opt/hive/skills}"
if [ -n "${TASK_TYPE:-}" ] && [ -r "$SKILLS_SRC/hive-$TASK_TYPE/SKILL.md" ]; then
  mkdir -p "$WORK/.claude/skills/hive-$TASK_TYPE"
  cp -f "$SKILLS_SRC/hive-$TASK_TYPE/SKILL.md" "$WORK/.claude/skills/hive-$TASK_TYPE/SKILL.md" \
    && echo "[agent] shipped systematic skill -> .claude/skills/hive-$TASK_TYPE/SKILL.md"
fi

# 2a. Pre-rebase the existing branch against the latest BASE_BRANCH. Without
# this, wave-N PRs that were merged in some order leave wave-N+1 PRs in a
# CONFLICTING state, and the re-fired worker has no way to see the conflict
# (we forbid it from running git). Three outcomes:
#   clean    → branch is rebased on top of latest main; REBASE_HAPPENED=1
#              so the final push is --force-with-lease
#   conflict → leave conflict markers in the working tree, set
#              REBASE_IN_PROGRESS=1, list files in CONFLICT_FILES, then the
#              PROMPT explicitly tells the worker it MAY edit those files to
#              resolve markers. After claude exits the harness runs
#              `rebase --continue` + force-push.
#   error    → abort + log; continue as if no rebase (worker may still do
#              useful work and the in-pod review will catch the unmergeable state)
REBASE_HAPPENED=0
REBASE_IN_PROGRESS=0
CONFLICT_FILES=""
if [ "$EXISTING_BRANCH" = "1" ]; then
  git fetch -q origin "$BASE_BRANCH" 2>/dev/null || echo "[agent] WARN: git fetch origin $BASE_BRANCH failed"
  if git rebase "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    REBASE_HAPPENED=1
    echo "[agent] rebased $branch onto origin/$BASE_BRANCH cleanly ($(git rev-parse --short HEAD))"
  else
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [ -n "$CONFLICT_FILES" ]; then
      REBASE_HAPPENED=1
      REBASE_IN_PROGRESS=1
      echo "[agent] rebase against origin/$BASE_BRANCH hit conflicts; worker will resolve:"
      printf '%s\n' "$CONFLICT_FILES" | sed 's/^/  /'
    else
      git rebase --abort 2>/dev/null || true
      echo "[agent] WARN: rebase failed without conflict markers — proceeding without rebase"
    fi
  fi
fi

# 2b. Role + chatid. The chatid is the claude session id once hammer 1 starts;
# until then we use a fire-unique fallback so any commits in flight still get
# a recognisable author. set_git_identity is re-called after hammer 1's init
# event lands the real session_id.
# agent.sh only ever runs the worker now (qa dispatches to qa-agent.sh; the
# merge pod path is retired in favour of a local `hivectl merge`). The gating
# review still runs in-pod as a sub-process (run_review), not as its own ROLE.
ROLE="worker"
CHATID="${ROLE}-pending-${ISSUE_ID}-$(date +%s)"
set_git_identity() {
  git config user.email "${CHATID}@coding.local"
  git config user.name  "${CHATID}"
}
set_git_identity
echo "[agent] role=$ROLE chatid=$CHATID (pending — will update with claude session id)"

# 2c. Does an open PR already exist for this branch? If yes, hammer 1 must
# read PR comments since the last bot commit and address them before doing
# anything else — that's how the re-fire / human-in-the-loop cycle works.
existing_pr_url=""
if [ "$EXISTING_BRANCH" = "1" ]; then
  existing_pr_url=$(gh pr view "$branch" --json url -q '.url' 2>/dev/null || echo "")
  [ -n "$existing_pr_url" ] && echo "[agent] existing PR on $branch: $existing_pr_url"
fi

# 3. Build the worker prompt. The prose lives in templates/worker-*.md; only
# the conditional assembly stays here. Generic harness contract only —
# role-specific guidance (how to review, what good code looks like) lives in
# the target repo's .claude/CLAUDE.md, .claude/agents/<role>.md, and
# .claude/skills/<TASK_TYPE>/SKILL.md, which Claude Code auto-loads. Export the
# locals the templates interpolate so envsubst (PROMPT_VARS) can see them.
export ISSUE_NUMBER BASE_BRANCH
export ISSUE_TITLE="$title"
export ISSUE_DESC="$desc"
PROMPT="$(render_prompt worker-task.md)"

has_dod=0
if printf '%s' "$desc" | grep -qiE '^[[:space:]]*#{1,3}[[:space:]]+definition[[:space:]]+of[[:space:]]+done[[:space:]]*:?[[:space:]]*$'; then
  has_dod=1
fi

# A '## Plan' heading WITHOUT the '(proposed by driver)' suffix is the
# human-approved scope. The proposal heading does not count — the driver
# is supposed to refuse to fire on a proposal, but we double-check here
# so a misconfigured driver can't bypass the gate by chance.
has_plan=0
if printf '%s' "$desc" | grep -qiE '^[[:space:]]*#{1,3}[[:space:]]+plan[[:space:]]*:?[[:space:]]*$'; then
  has_plan=1
fi

case "${TASK_TYPE:-}" in
  qa)
    : ;;
  *)
    if [ "$has_dod" = "1" ]; then
      PROMPT="$PROMPT

$(render_prompt worker-dod.md)"
    fi
    if [ "$has_plan" = "1" ]; then
      PROMPT="$PROMPT

$(render_prompt worker-plan.md)"
    fi
    if [ -n "${TASK_TYPE:-}" ] && [ -r "$WORK/.claude/skills/hive-${TASK_TYPE}/SKILL.md" ]; then
      export TASK_TYPE
      PROMPT="$PROMPT

$(render_prompt worker-skill.md)"
    fi
    ;;
esac

if [ -n "$existing_pr_url" ]; then
  export BRANCH="$branch"
  export EXISTING_PR_URL="$existing_pr_url"
  PROMPT="$PROMPT

$(render_prompt worker-existing-pr.md)"
fi

if [ "$REBASE_IN_PROGRESS" = "1" ]; then
  export CONFLICT_FILES
  PROMPT="$PROMPT

$(render_prompt worker-rebase.md)"
fi

echo "[agent] running claude…"
CLAUDE_OUT=/tmp/claude.out
: > "$CLAUDE_OUT"

# Per-task model fallback for ad-hoc runs (run.sh sets MODEL via the manifest
# for fleet fires, so this case only bites a bare `agent` invocation). The three
# coding modes default to Opus; everything else to Sonnet. Never Fable 5 (disqualified), never Haiku.
case "${TASK_TYPE:-}" in
  feature-implementation|bug-fix|improvement) MODEL_DEFAULT="opus" ;;
  *)                                          MODEL_DEFAULT="sonnet" ;;
esac
MODEL="${MODEL:-$MODEL_DEFAULT}"
MAX_TURNS="${MAX_TURNS:-120}"       # high-effort default; USD + time are the real guardrails
# Research runs on Sonnet and is cheap per-hammer, so give it more attempts to converge.
case "${TASK_TYPE:-}" in
  research) HAMMER_DEFAULT="8" ;;
  *)        HAMMER_DEFAULT="3" ;;
esac
HAMMER_MAX="${HAMMER_MAX:-$HAMMER_DEFAULT}"

# Per-fire spend ceiling. Plumbed to claude code's native --max-budget-usd
# (which works with -p / --print). The cap is for the WHOLE fire, not per
# hammer — we subtract each hammer's total_cost_usd and pass the remainder
# to the next call. Below $COST_FLOOR remaining, we skip the next hammer
# entirely instead of firing a near-zero budget call that can't get work
# done. Empty COST_LIMIT_USD = no cap (legacy).
COST_LIMIT_USD="${COST_LIMIT_USD:-}"
COST_FLOOR="${COST_FLOOR:-0.05}"
cost_so_far=0

# Hammer continuation prompt — role-agnostic. Role-specific guidance lives
# in the target repo's .claude/ tree, not here. Hammer 1 uses $PROMPT.
hammer_prompt() {
  export HAMMER_N="$1" HAMMER_MAX
  render_prompt hammer.md
}

# Tolerant RESULT detector. Matches the canonical 'RESULT: SUCCEEDED' line
# AND the variants the model has historically slipped into:
#   **RESULT: SUCCEEDED**         (markdown bold)
#   **RESULT:** SUCCEEDED         (bold key, plain value)
#   Result: succeeded             (cased differently)
#   - RESULT: SUCCEEDED           (list bullet prefix)
#   RESULT  :  SUCCEEDED.         (extra whitespace, trailing punct)
# We previously anchored to ^RESULT: which failed on ALL of the above and
# burned hammers re-doing finished work.
result_says() {  # result_says <succeeded|needs_human>
  printf '%s' "${out:-}" | grep -qiE 'result[[:space:]*_]*:[[:space:]*_]*'"$1"
}

# Strip the RESULT line and everything after (lenient match). Used to
# extract the agent's questions for NEEDS_HUMAN — we don't want the marker
# line itself in the GitHub comment.
strip_result_line() {
  local body="$1" line_no
  line_no=$(printf '%s\n' "$body" \
    | grep -niE 'result[[:space:]*_]*:[[:space:]*_]*(succeeded|needs_human)' \
    | head -1 | cut -d: -f1)
  if [ -n "$line_no" ] && [ "$line_no" -gt 1 ]; then
    printf '%s\n' "$body" | head -n $((line_no - 1))
  else
    printf '%s' "$body"
  fi
}

# Extract ONLY the `**Open questions:**` block from a NEEDS_HUMAN reply
# so the in-pod review (and humans) never see the worker's free-text reasoning.
# The block runs from the `**Open questions:**` heading through the line
# just before the RESULT marker. Falls back to the legacy strip-result-line
# tail if the block is missing (older worker prompts or model drift) so
# the human still gets context.
extract_open_questions() {
  local body="$1" start_line result_line
  start_line=$(printf '%s\n' "$body" \
    | grep -niE '^[[:space:]]*\*\*open[[:space:]]+questions[[:space:]]*:?\*\*' \
    | head -1 | cut -d: -f1)
  if [ -z "$start_line" ]; then
    strip_result_line "$body"
    return
  fi
  result_line=$(printf '%s\n' "$body" \
    | grep -niE 'result[[:space:]*_]*:[[:space:]*_]*(succeeded|needs_human)' \
    | head -1 | cut -d: -f1)
  if [ -n "$result_line" ] && [ "$result_line" -gt "$start_line" ]; then
    printf '%s\n' "$body" | sed -n "${start_line},$((result_line - 1))p"
  else
    printf '%s\n' "$body" | sed -n "${start_line},\$p"
  fi
}

# Extract ONLY the brief the worker emitted between the HIVE_BRIEF markers.
# The worker fills /opt/hive/templates/<type>-brief.md and wraps it per its
# hive-<TASK_TYPE> skill; we post just that block to the PR. Empty if absent —
# posting is non-gating, like self-review. The marker literals here MUST match
# the ones in the hive-* skills' "Write the brief" stage.
extract_brief() {  # extract_brief <body>
  printf '%s\n' "$1" | awk '
    /<!--[[:space:]]*\/HIVE_BRIEF[[:space:]]*-->/ { p=0; next }
    p { print }
    /<!--[[:space:]]*HIVE_BRIEF[[:space:]]*-->/   { p=1 }
  '
}

# Has the agent actually done its job, based on EVIDENCE in the repo
# — not the model's last sentence? Used to break the hammer loop early
# when the model finished but forgot the RESULT marker.
#   worker → dirty working tree (they were told NOT to run git, so
#            anything dirty was edited this hammer)
work_completed() {
  [ -n "$(git -C "$WORK" status --porcelain 2>/dev/null)" ]
}

out=""
hammers_used=0
cost_cap_hit=0
for n in $(seq 1 "$HAMMER_MAX"); do
  hammers_used=$n
  # Cost-cap pre-check: refuse to burn another claude call if remaining
  # budget is below the floor. Claude code's --max-budget-usd is per-call;
  # we make it per-fire by passing (cap - spent) to each hammer.
  budget_arg=""
  if [ -n "$COST_LIMIT_USD" ]; then
    remaining=$(awk -v l="$COST_LIMIT_USD" -v s="$cost_so_far" 'BEGIN{printf "%.4f", l-s}')
    under_floor=$(awk -v r="$remaining" -v f="$COST_FLOOR" 'BEGIN{print (r+0 < f+0)?1:0}')
    if [ "$under_floor" = "1" ]; then
      echo "[agent] cost cap reached: spent \$$cost_so_far / limit \$$COST_LIMIT_USD (remaining \$$remaining < floor \$$COST_FLOOR) — skipping hammer $n"
      hammers_used=$((n-1))
      cost_cap_hit=1
      break
    fi
    budget_arg="--max-budget-usd $remaining"
  fi
  echo "[agent] === hammer $n/$HAMMER_MAX (model=$MODEL max-turns=$MAX_TURNS budget=\$${remaining:-∞}/\$${COST_LIMIT_USD:-∞} spent=\$$cost_so_far task_type=${TASK_TYPE:-?}) ==="
  if [ "$n" = "1" ]; then
    msg="$PROMPT"
    continue_arg=""
  else
    msg="$(hammer_prompt "$n")"
    continue_arg="--continue"
  fi
  CLAUDE_OUT_N=/tmp/claude.out.$n
  : > "$CLAUDE_OUT_N"
  # shellcheck disable=SC2086
  claude -p "$msg" $continue_arg --model "$MODEL" --max-turns "$MAX_TURNS" \
    $budget_arg \
    --output-format stream-json --verbose --dangerously-skip-permissions 2>&1 \
    | tee -a "$CLAUDE_OUT" "$CLAUDE_OUT_N"
  crc=${PIPESTATUS[0]}
  [ "$crc" -eq 0 ] || fail "claude exited rc=$crc on hammer $n"
  is_err=$(jq -r 'select(.type=="result") | .is_error // false' "$CLAUDE_OUT_N" 2>/dev/null | head -1)
  err_subtype=$(jq -r 'select(.type=="result") | .subtype // empty' "$CLAUDE_OUT_N" 2>/dev/null | head -1)
  if [ "$is_err" = "true" ]; then
    fail "claude returned is_error=true subtype=${err_subtype:-unknown} on hammer $n"
  fi
  out=$(jq -s 'map(select(.type=="result"))[-1].result // empty' "$CLAUDE_OUT_N" 2>/dev/null)
  # Accumulate this hammer's spend so the next hammer's budget is correct.
  cost_this=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$CLAUDE_OUT_N" 2>/dev/null | head -1)
  [ -n "$cost_this" ] || cost_this=0
  cost_so_far=$(awk -v a="$cost_so_far" -v b="$cost_this" 'BEGIN{printf "%.6f", a+b}')
  echo "[agent] hammer $n done (${#out} bytes, cost \$$cost_this, cumulative \$$cost_so_far / cap \$${COST_LIMIT_USD:-∞})"
  # On the FIRST hammer, swap the pending chatid for the real claude session id
  # so subsequent commits land with author 'worker-<sid8>'.
  if [ "$n" = "1" ]; then
    sid=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id // empty' "$CLAUDE_OUT_N" 2>/dev/null | head -1)
    if [ -n "$sid" ] && [ "$sid" != "null" ]; then
      CHATID="${ROLE}-${sid:0:8}"
      set_git_identity
      echo "[agent] chatid finalized: $CHATID (session=$sid)"
    fi
  fi
  # Early exit, two paths.
  # 1) Model declared a RESULT (now lenient — handles **bold**, casing,
  #    leading list-bullet, trailing punct).
  # 2) Evidence in the repo / PR says the work is done, even if the model
  #    forgot the marker. This is the real fix for the "hammers=3 but
  #    the model finished on hammer 1" pattern.
  if result_says "succeeded"; then
    echo "[agent] model declared RESULT: SUCCEEDED on hammer $n — stopping"
    break
  fi
  if result_says "needs_human"; then
    echo "[agent] model declared RESULT: NEEDS_HUMAN on hammer $n — stopping"
    break
  fi
  if work_completed; then
    echo "[agent] hammer $n: work complete (evidence in repo/PR) — stopping early"
    break
  fi
done
echo "[agent] claude done after $hammers_used hammer(s) (${#out} bytes)"

# ── Independent GATING review (worker success) ────────────────────────────────
# A SECOND, fresh `claude` run (no --continue) reviews the change this worker
# just produced and GATES it. Fresh process => zero access to the worker's
# reasoning trail, so it is an independent review even though it shares this
# pod. This REPLACES the separate pr-review pod: the review happens here and the
# DRIVER (never this pod) performs the merge, so the pod that wrote the code
# never ships it. It runs IN $WORK so it can read surrounding files and run the
# project's build/tests; like the worker's "no git" rule, we trust the prompt to
# keep it read-only (the in-place tradeoff vs a fresh clone). It grades the
# issue's Definition of Done + Plan and emits PASS / CHANGES_REQUESTED. Own
# budget ($REVIEW_COST_LIMIT_USD, default $2, sonnet); cost folds into METRICS.
REVIEW_FILE=/tmp/review.md
REVIEW_COST=0
REVIEW_VERDICT=""
REVIEW_MODEL="${REVIEW_MODEL:-sonnet}"
: > "$REVIEW_FILE"
run_review() {
  local rv_diff rv_skeleton rv_prompt RV_OUT rv_body rv_marker
  rv_diff=$(git -C "$WORK" diff "origin/$BASE_BRANCH" 2>/dev/null | head -c 120000)
  if [ -z "$rv_diff" ]; then
    echo "[agent] review: empty diff against origin/$BASE_BRANCH — skipping (verdict unknown)"
    return 0
  fi
  local rv_budget="${REVIEW_COST_LIMIT_USD:-2}"
  rv_skeleton=""
  [ -r "$TEMPLATES_DIR/review-brief.md" ] && rv_skeleton=$(cat "$TEMPLATES_DIR/review-brief.md")
  export REVIEW_DIFF="$rv_diff"
  export REVIEW_SKELETON="$rv_skeleton"
  rv_prompt="$(render_prompt review-prompt.md)"
  RV_OUT=/tmp/review.out
  : > "$RV_OUT"
  echo "[agent] review: model=$REVIEW_MODEL budget=\$$rv_budget (independent, in $WORK)"
  ( cd "$WORK" && claude -p "$rv_prompt" --model "$REVIEW_MODEL" \
      --max-turns 40 --max-budget-usd "$rv_budget" \
      --output-format stream-json --verbose --dangerously-skip-permissions 2>&1 ) \
    | tee "$RV_OUT" >/dev/null || echo "[agent] WARN: review claude failed (non-fatal)"
  rv_body=$(jq -s 'map(select(.type=="result"))[-1].result // empty' "$RV_OUT" 2>/dev/null)
  REVIEW_COST=$(jq -r 'select(.type=="result") | .total_cost_usd // 0' "$RV_OUT" 2>/dev/null | head -1)
  [ -n "$REVIEW_COST" ] || REVIEW_COST=0
  # Verdict from the LAST REVIEW: marker line (lenient, like result_says).
  rv_marker=$(printf '%s\n' "$rv_body" | grep -iE 'review[[:space:]*_]*:[[:space:]*_]*(pass|changes_requested)' | tail -1)
  case "$(printf '%s' "$rv_marker" | tr 'A-Z' 'a-z')" in
    *changes*) REVIEW_VERDICT="CHANGES_REQUESTED" ;;
    *pass*)    REVIEW_VERDICT="PASS" ;;
    *)         REVIEW_VERDICT="" ;;
  esac
  # Strip the trailing REVIEW: marker line from the posted body.
  printf '%s\n' "$rv_body" | grep -viE '^[-* ]*\**review\**[[:space:]:]*\**(pass|changes_requested)\**\.?[[:space:]]*$' > "$REVIEW_FILE"
  echo "[agent] review: verdict=${REVIEW_VERDICT:-unknown} cost=\$$REVIEW_COST ($(wc -c < "$REVIEW_FILE") bytes)"
}
if ! result_says "needs_human"; then
  case "${TASK_TYPE:-}" in
    feature-implementation|bug-fix|improvement|research)
      if result_says "succeeded" || work_completed; then run_review; fi
      ;;
  esac
fi

# Emit METRICS as soon as claude finished — covers SUCCEEDED, NEEDS_INFO, and
# any FAILED path between here and the end. Single-line JSON; the Mac-side
# aggregator (ops/agent-metrics.sh) greps it out of the run.log.
WALL_S=$(( $(date +%s) - RUN_START_EPOCH ))
# Sum across every hammer's result event so METRICS reflects the whole run.
R=$(jq -s '
  [.[] | select(.type=="result")] as $r |
  {
    total_cost_usd: ([$r[].total_cost_usd // 0] | add // 0),
    duration_ms:    ([$r[].duration_ms    // 0] | add // 0),
    num_turns:      ([$r[].num_turns      // 0] | add // 0),
    usage: {
      input_tokens:                ([$r[].usage.input_tokens                // 0] | add // 0),
      output_tokens:               ([$r[].usage.output_tokens               // 0] | add // 0),
      cache_read_input_tokens:     ([$r[].usage.cache_read_input_tokens     // 0] | add // 0),
      cache_creation_input_tokens: ([$r[].usage.cache_creation_input_tokens // 0] | add // 0)
    },
    hammers: ($r | length)
  }
' "$CLAUDE_OUT" 2>/dev/null || echo '{}')
METRICS=$(jq -nc \
  --arg issue_id "$ISSUE_ID" --arg type "${TASK_TYPE:-}" --arg repo "$REPO_NAME" \
  --arg repo_slug "$REPO_SLUG" \
  --arg role "$ROLE" --arg model "$MODEL" \
  --argjson issue_number "$ISSUE_NUMBER" \
  --argjson wall_s "$WALL_S" --argjson r "$R" \
  --argjson hammers_used "$hammers_used" \
  --argjson hammer_max "$HAMMER_MAX" \
  --arg cost_limit "${COST_LIMIT_USD:-}" \
  --argjson cost_cap_hit "$cost_cap_hit" \
  --argjson sr_cost "${REVIEW_COST:-0}" \
  '{issue_id:$issue_id, issue_number:$issue_number, task_type:$type, repo:$repo, repo_slug:$repo_slug,
    role:$role, model:$model,
    wall_s:$wall_s,
    cost_usd:           (($r.total_cost_usd // 0) + $sr_cost),
    primary_cost_usd:   ($r.total_cost_usd // 0),
    selfreview_cost_usd: $sr_cost,
    cost_limit_usd: ($cost_limit | if . == "" then null else tonumber end),
    cost_cap_hit:   ($cost_cap_hit == 1),
    duration_ms:    ($r.duration_ms // 0),
    num_turns:      ($r.num_turns // 0),
    input_tokens:   ($r.usage.input_tokens // 0),
    output_tokens:  ($r.usage.output_tokens // 0),
    cache_read:     ($r.usage.cache_read_input_tokens // 0),
    cache_creation: ($r.usage.cache_creation_input_tokens // 0),
    hammers:        $hammers_used,
    hammer_max:     $hammer_max}')
echo "METRICS: $METRICS"

# Push to Prometheus pushgateway so Prom can chart cost/tokens/duration
# alongside CPU/mem. Pushgateway URL is injected by the sandbox manifest;
# unset → silent skip (e.g. local non-cluster runs). Failure is non-fatal:
# a Prom outage must never sink a successful agent run.
push_metrics_to_prom() {
  [ -n "${PUSHGATEWAY_URL:-}" ] || return 0
  local job="coding_agent"
  # Pushgateway groups by job + label values in the URL path; instance per
  # run keeps each fire as its own series (otherwise reruns overwrite each
  # other and Prom only ever sees the latest).
  local instance="${ISSUE_ID}-${RUN_START_EPOCH}"
  local url="${PUSHGATEWAY_URL%/}/metrics/job/${job}/instance/${instance}/issue_id/${ISSUE_ID}/task_type/${TASK_TYPE:-unknown}/role/${ROLE}/model/${MODEL}/repo/${REPO_NAME}"
  # Build the Prom text exposition payload from the METRICS json.
  local payload
  payload=$(jq -r '
    "# TYPE coding_agent_cost_usd gauge\ncoding_agent_cost_usd \(.cost_usd)\n" +
    "# TYPE coding_agent_wall_seconds gauge\ncoding_agent_wall_seconds \(.wall_s)\n" +
    "# TYPE coding_agent_duration_ms gauge\ncoding_agent_duration_ms \(.duration_ms)\n" +
    "# TYPE coding_agent_num_turns gauge\ncoding_agent_num_turns \(.num_turns)\n" +
    "# TYPE coding_agent_hammers gauge\ncoding_agent_hammers \(.hammers)\n" +
    "# TYPE coding_agent_hammer_max gauge\ncoding_agent_hammer_max \(.hammer_max // 3)\n" +
    "# TYPE coding_agent_input_tokens gauge\ncoding_agent_input_tokens \(.input_tokens)\n" +
    "# TYPE coding_agent_output_tokens gauge\ncoding_agent_output_tokens \(.output_tokens)\n" +
    "# TYPE coding_agent_cache_read_tokens gauge\ncoding_agent_cache_read_tokens \(.cache_read)\n" +
    "# TYPE coding_agent_cache_creation_tokens gauge\ncoding_agent_cache_creation_tokens \(.cache_creation)\n" +
    "# TYPE coding_agent_run_completed gauge\ncoding_agent_run_completed 1\n"
  ' <<<"$METRICS" 2>/dev/null) || { echo "[agent] WARN: could not build push payload"; return 0; }
  if curl -sS --max-time 5 --data-binary "$payload" "$url" >/dev/null 2>&1; then
    echo "[agent] pushgateway: pushed metrics (job=$job instance=$instance)"
  else
    echo "[agent] WARN: pushgateway push failed (continuing — non-fatal)"
  fi
}
push_metrics_to_prom

# 4. Helpers — GH issue label move (status mutex), GH issue comment, PR comment.

# Move the issue to a new status:* label. The label dictionary
# (.claude/labels.md in the hive repo) defines exactly one `status:*` label
# per issue at any time — `gh_issue_set_status` enforces that mutex by
# removing every other status:* label as it adds the new one.
ALL_STATUS_LABELS="status:ready status:in-progress status:in-review status:changes-requested status:done status:needs-human"

gh_issue_set_status() {  # gh_issue_set_status <new-status>  (e.g. status:in-review)
  local new="$1" rm_args=() lab
  for lab in $ALL_STATUS_LABELS; do
    [ "$lab" = "$new" ] && continue
    rm_args+=(--remove-label "$lab")
  done
  if gh -R "$REPO_SLUG" issue edit "$ISSUE_NUMBER" \
      --add-label "$new" "${rm_args[@]}" >/dev/null 2>&1; then
    echo "[agent] gh: issue #$ISSUE_NUMBER -> $new"
  else
    echo "[agent] WARN: gh issue edit failed setting $new on #$ISSUE_NUMBER"
  fi
}

# Template renderer — reads /opt/hive/templates/<name>, expands ONLY the
# whitelisted env vars below (envsubst whitelist), so a template can
# include literal $foo or shell-escape sequences without them getting
# silently eaten. (TEMPLATES_DIR itself is set near the top — needed early.)
TEMPLATE_VARS='$CHATID $ISSUE_NUMBER $ISSUE_URL $ISSUE_TITLE $STATUS $TASK_TYPE $ROLE $BRANCH $BASE_BRANCH $PR_URL_OR_DASH $MODEL $HAMMERS_USED $HAMMER_MAX $COST_USD $COMMIT_BODY $HIVE_VERSION $TAIL_BLOCK $NEEDS_HUMAN_REASON $OPEN_QUESTIONS_BLOCK $NEXT_STEP_HINT'
render_template() {  # render_template <basename.md>
  local path="${TEMPLATES_DIR:-/opt/hive/templates}/$1"
  if ! [ -r "$path" ]; then
    echo "[agent] WARN: template missing: $path" >&2
    return 1
  fi
  envsubst "$TEMPLATE_VARS" < "$path"
}

# Short status comment on the issue itself. Body is the issue-status.md
# template; tail block dropped on SUCCEEDED per the S2 hygiene rule.
gh_issue_status_comment() {  # gh_issue_status_comment <status> <pr_url> <tail>
  local status="$1" pr_url="$2" tail="$3"
  export STATUS="$status"
  export PR_URL_OR_DASH="${pr_url:-—}"
  export HAMMERS_USED="$hammers_used"
  export COST_USD="${cost_so_far:-0}"
  if [ "$status" = "SUCCEEDED" ] || [ -z "$tail" ]; then
    export TAIL_BLOCK=""
  else
    local tail_short
    tail_short=$(printf '%s' "$tail" | head -c 1200)
    export TAIL_BLOCK=$(printf '<details><summary>agent reply (tail)</summary>\n\n```\n%s\n```\n</details>' "$tail_short")
  fi
  local body
  body=$(render_template issue-status.md) || return 0
  if printf '%s\n' "$body" | gh -R "$REPO_SLUG" issue comment "$ISSUE_NUMBER" -F - >/dev/null 2>&1; then
    echo "[agent] gh: posted status comment on #$ISSUE_NUMBER"
  else
    echo "[agent] WARN: gh issue comment failed on #$ISSUE_NUMBER"
  fi
}

pr_comment() {  # pr_comment <pr_url> <body>
  local pr_url="$1" body="$2"
  if [ -z "$pr_url" ]; then
    echo "[agent] WARN: no PR url to comment on" >&2
    return 1
  fi
  printf '%s\n' "$body" | gh pr comment "$pr_url" -F - \
    && echo "[agent] pr: posted comment on $pr_url" \
    || echo "[agent] WARN: gh pr comment failed on $pr_url"
}

# Templated NEEDS_HUMAN comment on the PR. Unifies the four ad-hoc
# `printf … needs human input …` callsites so every NEEDS_HUMAN comment
# from the fleet has the same shape.
pr_needs_human_comment() {  # pr_needs_human_comment <pr_url> <reason> <next_step> [questions_block]
  local pr_url="$1" reason="$2" next_step="$3" questions="${4:-_(none — see reason above)_}"
  if [ -z "$pr_url" ]; then
    echo "[agent] WARN: no PR url for needs-human comment" >&2
    return 1
  fi
  export NEEDS_HUMAN_REASON="$reason"
  export NEXT_STEP_HINT="$next_step"
  export OPEN_QUESTIONS_BLOCK="$questions"
  export HAMMERS_USED="$hammers_used"
  local body
  body=$(render_template pr-needs-human.md) || { pr_comment "$pr_url" "$reason"; return; }
  printf '%s\n' "$body" | gh pr comment "$pr_url" -F - \
    && echo "[agent] pr: posted needs-human comment on $pr_url" \
    || echo "[agent] WARN: gh pr comment failed on $pr_url"
}

# commit+push helper: stage everything, commit if dirty (allow-empty optional),
# push to origin. All commits use the role+chatid identity set above.
# force=1 → push --force-with-lease (used after a rebase rewrote branch history).
commit_and_push() {  # commit_and_push <commit_subject> [allow_empty:0|1] [force:0|1]
  local subject="$1" allow_empty="${2:-0}" force="${3:-0}"
  git add -A
  if git diff --cached --quiet; then
    if [ "$allow_empty" = "1" ]; then
      git commit --allow-empty -m "$subject" >/dev/null
    fi
  else
    git commit -m "$subject" >/dev/null
  fi
  if [ "$force" = "1" ]; then
    git push --force-with-lease -u origin "$branch" 2>/dev/null \
      || git push --force -u origin "$branch" 2>/dev/null \
      || git push -u origin "$branch" 2>/dev/null || true
  else
    git push -u origin "$branch" 2>/dev/null || git push origin "$branch" 2>/dev/null || true
  fi
}

# Finish a pending rebase, looping across multiple rounds. Each round:
#   1. Stage the worker's edits (any file).
#   2. Refuse if conflict markers remain in any tracked file.
#   3. Auto-resolve build-artifact conflicts (lockfiles, tsbuildinfo,
#      dist/**) by taking --theirs — they regenerate and human-resolving
#      them is wasted spend. Stage the auto-resolved files.
#   4. `git rebase --continue`. If it advances the rebase past the next
#      commit and no new conflicts appear → return 0.
#   5. If new conflicts appear AND every conflict file is an auto-gen file
#      → auto-resolve in the next loop iteration (no worker re-fire needed).
#   6. If new conflicts appear AND any non-auto-gen file is conflicted →
#      update CONFLICT_FILES with the new list and return 2 so the caller
#      can fire another worker hammer.
#   7. After REBASE_MAX_ROUNDS (default 5) without convergence → return 1.
# Returns: 0 = rebase done; 1 = fatal (caller NEEDS_HUMANs); 2 = need
# another worker hammer with new conflicts (CONFLICT_FILES is updated and
# exported so the next hammer prompt can use it).
REBASE_MAX_ROUNDS="${REBASE_MAX_ROUNDS:-5}"

# Pattern for files the harness is allowed to auto-resolve with --theirs
# (i.e. take whatever main has, ours regenerates). Treated as a case glob.
is_autogen_file() {  # is_autogen_file <path>
  case "$1" in
    package-lock.json|*/package-lock.json|\
    yarn.lock|*/yarn.lock|\
    bun.lockb|*/bun.lockb|\
    pnpm-lock.yaml|*/pnpm-lock.yaml|\
    Cargo.lock|*/Cargo.lock|\
    *.tsbuildinfo|*/*.tsbuildinfo|\
    dist/*|*/dist/*) return 0 ;;
    *) return 1 ;;
  esac
}

finish_rebase() {  # finish_rebase  → echoes reason on failure
  local round=0 conflict_now f remaining continue_log rc
  while [ "$round" -lt "$REBASE_MAX_ROUNDS" ]; do
    round=$((round + 1))
    # Query CURRENT round's conflict files BEFORE git add (--diff-filter=U
    # reports unmerged index entries; `git add -A` would clear them).
    conflict_now=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [ -n "$conflict_now" ]; then
      # Worker should have resolved non-autogen files. If any still has
      # markers, bail to NEEDS_HUMAN (return 2 = "could fire another
      # hammer", caller currently treats as NEEDS_HUMAN — fine for now).
      remaining=""
      for f in $conflict_now; do
        if ! is_autogen_file "$f"; then
          if [ -f "$f" ] && grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$f"; then
            remaining="${remaining:+$remaining }$f"
          fi
        fi
      done
      if [ -n "$remaining" ]; then
        echo "[agent] finish_rebase round=$round: unresolved markers: $remaining" >&2
        CONFLICT_FILES="$remaining"; export CONFLICT_FILES
        echo "$remaining"
        return 2
      fi
      # Auto-resolve build artifacts with --theirs (they regenerate).
      for f in $conflict_now; do
        if is_autogen_file "$f"; then
          git checkout --theirs -- "$f" 2>/dev/null
          echo "[agent] finish_rebase round=$round: auto --theirs: $f"
        fi
      done
      # Stage everything (worker edits + autogen --theirs picks).
      git add -A 2>/dev/null
    fi
    # Advance the rebase.
    continue_log=$(GIT_EDITOR=true git rebase --continue 2>&1)
    rc=$?
    # Rebase fully done?
    if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
      if [ "$rc" -eq 0 ]; then
        echo "[agent] finish_rebase round=$round: rebase fully done"
        return 0
      fi
      echo "rebase exited with rc=$rc and no rebase state: $(printf '%s' "$continue_log" | tail -c 400)"
      return 1
    fi
    # Still rebasing. Either rc=0 (next step paused on new conflicts; the
    # next loop iteration will see them) or rc!=0 (commonly: "no changes —
    # did you forget" because the commit became empty after auto-resolve).
    if printf '%s' "$continue_log" | grep -qiE 'no changes|nothing to commit|empty commit'; then
      echo "[agent] finish_rebase round=$round: empty commit → skipping"
      GIT_EDITOR=true git rebase --skip >/dev/null 2>&1 || true
      if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
        return 0
      fi
    fi
    # Loop — next iteration's `--diff-filter=U` query catches new conflicts.
  done
  echo "rebase did not converge after $REBASE_MAX_ROUNDS rounds"
  return 1
}

ensure_pr_exists() {  # echoes pr_url for $branch (creates if missing)
  local pr_url=""
  pr_url=$(gh pr view "$branch" --json url -q .url 2>/dev/null || echo "")
  if [ -z "$pr_url" ]; then
    export ISSUE_URL="https://github.com/${REPO_SLUG}/issues/${ISSUE_NUMBER}"
    export ISSUE_TITLE="$title"
    export COMMIT_BODY=$(git log "$BASE_BRANCH..$branch" --pretty=%B 2>/dev/null | head -c 4000)
    export HAMMERS_USED="$hammers_used"
    export COST_USD="${cost_so_far:-0}"
    export HIVE_VERSION="${HIVE_VERSION:-dev}"
    local pr_body
    pr_body=$(render_template pr-body.md 2>/dev/null) || pr_body="$COMMIT_BODY"
    pr_url=$(printf '%s\n' "$pr_body" \
      | gh pr create --base "$BASE_BRANCH" --head "$branch" \
          --title "[#${ISSUE_NUMBER}] ${title}" --body-file - 2>/dev/null || true)
    [ -n "$pr_url" ] || pr_url=$(gh pr view "$branch" --json url -q .url 2>/dev/null || echo "")
  fi
  printf '%s' "$pr_url"
}

# 5. Outcome verification — harness decides PASS/FAIL, not the model.
# Three terminal outcomes for both roles: SUCCEEDED / NEEDS_HUMAN / FAILED.
# Every outcome posts a short status comment on the GH issue; NEEDS_HUMAN
# also posts the agent's questions as a GitHub PR comment.
tail_for_comment="$(printf '%s' "$out" | tail -c 4000)"
case "${TASK_TYPE:-}" in
  *)
    # Worker: harness commits code changes, pushes, opens PR. (The pr-merge
    # arm is retired — merge is now a local `hivectl merge`, not a pod fire.)
    if result_says "needs_human"; then
      # Can't commit while a rebase is in progress — abort first so the
      # NEEDS_HUMAN questions can land as a normal commit on the un-rebased
      # branch tip. The rebase state is sacrificial; the PR comment carries
      # the conflict context for the human anyway.
      [ "$REBASE_IN_PROGRESS" = "1" ] && git rebase --abort 2>/dev/null || true
      # Make sure a PR exists so the questions have a place to live, even
      # if the agent produced no code changes.
      commit_and_push "[$CHATID] #$ISSUE_NUMBER: $title (NEEDS_HUMAN — see PR)" 1 "$REBASE_HAPPENED"
      pr_url=$(ensure_pr_exists)
      questions=$(extract_open_questions "$out")
      pr_needs_human_comment "$pr_url" \
        "Worker exited with \`RESULT: NEEDS_HUMAN\` — see Open questions below." \
        "Answer the questions inline; then re-fire the worker (\`hivectl fire $ISSUE_NUMBER\`)." \
        "$questions"
      gh_issue_set_status "status:needs-human"
      gh_issue_status_comment "NEEDS_HUMAN" "$pr_url" "$tail_for_comment"
      emit NEEDS_HUMAN "questions posted on $pr_url"
      echo "=== done: #$ISSUE_NUMBER ($REPO_NAME) ==="
      exit 0
    fi
    # Rebase-resolution path: the worker edited files to remove conflict
    # markers; the harness now stages, continues the rebase, and force-pushes.
    if [ "$REBASE_IN_PROGRESS" = "1" ]; then
      if reason=$(finish_rebase); then
        echo "[agent] rebase resolved by worker; force-pushing $branch"
        git push --force-with-lease -u origin "$branch" 2>/dev/null \
          || git push --force -u origin "$branch" 2>/dev/null \
          || fail "force-push after rebase resolution failed"
      else
        git rebase --abort 2>/dev/null || true
        pr_url="$existing_pr_url"
        [ -z "$pr_url" ] && pr_url=$(gh pr view "$branch" --json url -q .url 2>/dev/null || echo "")
        if [ -n "$pr_url" ]; then
          pr_needs_human_comment "$pr_url" \
            "Worker did not fully resolve the rebase conflict against \`$BASE_BRANCH\`. Reason: $reason." \
            "Rebase this PR manually (\`git fetch && git rebase origin/$BASE_BRANCH\`), push, then re-fire the worker."
        fi
        gh_issue_set_status "status:needs-human"
        gh_issue_status_comment "NEEDS_HUMAN" "${pr_url:-}" "rebase resolution failed: $reason"
        emit NEEDS_HUMAN "rebase resolution failed: $reason"
        echo "=== done: #$ISSUE_NUMBER ($REPO_NAME) ==="
        exit 0
      fi
    else
      commit_and_push "[$CHATID] #$ISSUE_NUMBER: $title" 0 "$REBASE_HAPPENED"
    fi
    pr_url=$(ensure_pr_exists)
    if [ -n "$pr_url" ] && echo "$pr_url" | grep -qE '^https://github\.com/'; then
      echo "[agent] PR: $pr_url"
      # Post the worker's own brief (filled from its hive-<type> skill, wrapped
      # in the HIVE_BRIEF markers) as a PR comment so the in-pod review and human get
      # a structured summary of what was done. Non-gating: no markers → skip.
      # The `**coding-agent ` prefix + no `**Open questions:**` block means the
      # re-fire read filter ignores it (same as self-review).
      brief_body=$(extract_brief "$out")
      if [ -n "$(printf '%s' "$brief_body" | tr -d '[:space:]')" ]; then
        { printf '**coding-agent brief**\n\n'; printf '%s\n' "$brief_body"; } \
          | gh pr comment "$pr_url" -F - 2>/dev/null \
          && echo "[agent] posted brief to $pr_url" \
          || echo "[agent] WARN: brief comment failed (non-fatal)"
      fi
      # Post the independent GATING review as a PR comment. The
      # `**coding-agent review** — <VERDICT>` header is load-bearing: the driver
      # reads the verdict to decide whether to merge (PASS) or re-fire the worker
      # (CHANGES_REQUESTED), and the re-fire read filter pulls the
      # `**Changes requested:**` block out of it. Non-gating to POST (the verdict
      # gates), so a failed post never sinks the run.
      if [ -s "$REVIEW_FILE" ]; then
        { printf '**coding-agent review** — %s (independent %s pass)\n\n' "${REVIEW_VERDICT:-UNKNOWN}" "${REVIEW_MODEL:-sonnet}"; cat "$REVIEW_FILE"; } \
          | gh pr comment "$pr_url" -F - 2>/dev/null \
          && echo "[agent] posted review (${REVIEW_VERDICT:-unknown}) to $pr_url" \
          || echo "[agent] WARN: review comment failed (non-fatal)"
      fi
      # Verdict routing. CHANGES_REQUESTED -> the driver re-fires the worker
      # (resolver loop). PASS or unknown (review skipped/failed) -> in-review,
      # which the driver merges only when it sees a PASS review comment.
      if [ "$REVIEW_VERDICT" = "CHANGES_REQUESTED" ]; then
        gh_issue_set_status "status:changes-requested"
        gh_issue_status_comment "SUCCEEDED" "$pr_url" "$tail_for_comment"
        emit SUCCEEDED "$pr_url (review: CHANGES_REQUESTED — re-fire worker to address)"
      else
        gh_issue_set_status "status:in-review"
        gh_issue_status_comment "SUCCEEDED" "$pr_url" "$tail_for_comment"
        emit SUCCEEDED "$pr_url${REVIEW_VERDICT:+ (review: $REVIEW_VERDICT)}"
      fi
      echo "=== done: #$ISSUE_NUMBER ($REPO_NAME) ==="
      exit 0
    fi
    gh_issue_status_comment "FAILED" "" "no PR opened on $branch"
    fail "no PR exists on $branch after $hammers_used hammer(s) and no NEEDS_HUMAN escape"
    ;;
esac
