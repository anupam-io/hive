#!/usr/bin/env bash
set -uo pipefail   # not -e: we trap failures ourselves so we always emit status
# QA role — sees NO source code, only the running web app over HTTP via
# Playwright. The agent's outputs land on GitHub:
#   - A NEW issue on the project's repo with label `type:qa-feedback`.
#   - QA artifacts (screenshots, console/network logs) pushed to an
#     ORPHAN branch `qa-artifacts/issue-<target>/<ts>/` on the same repo.
#     Orphan = no shared history with `main`, so no code is read or written.
#
#   Inputs (env): WEB_URL, REPO_URL, QA_TARGET (the issue # being verified),
#                 GITHUB_PAT_TOKEN (already wired by entrypoint.sh)
#   Output:       a GH feedback issue cross-linking #QA_TARGET, with the
#                 orphan-branch tree URL for evidence + STATUS + METRICS.
#
# Pipeline (split: we own the floor, the agent owns the QA):
#   1. Baseline capture (qa-capture.mjs) — small + deterministic.
#      Just initial.png + loaded.png + page.txt + console.log + network.log
#      + meta.json. We capture console/network because they need listeners
#      attached BEFORE navigation; MCP can't replay them after the fact.
#   2. Claude analysis — claude has the official @playwright/mcp at its
#      disposal AND the Read tool over the baseline. It drives the browser
#      ITSELF: navigates, scrolls, hovers, clicks, takes its own
#      screenshots, tries multiple viewports. We do not script the QA.
#   3. Artifact push + issue create — push the baseline to an orphan
#      branch on the project's repo, then `gh issue create` referencing it.
#
# Hard rules (mirrored in CLAUDE.md):
#   - NEVER `git clone` the repo's main tree, NEVER `git checkout` main, NEVER
#     read source code. The orphan branch carries ONLY captured QA artifacts
#     and shares NO history with the codebase.
#   - The only branch this agent may push is `qa-artifacts/issue-<N>/<ts>/`.
#   - Outbound traffic from the agent body is to (a) the target web app via
#     the playwright browser, and (b) GitHub (gh + the orphan-branch push).
#   - GH writes are limited to: pushing an orphan artifact branch and
#     `gh issue create --label type:qa-feedback`. Never edits existing
#     issues, never opens a PR.

: "${WEB_URL:?set WEB_URL (e.g. http://web.prod.svc.cluster.local:3000)}"
: "${REPO_URL:?set REPO_URL (project repo for orphan artifact branch + gh issue create)}"
QA_TARGET="${QA_TARGET:-}"
ISSUE_ID="${ISSUE_NUMBER:-qa-$(date +%s)}"
RUN_START_EPOCH=$(date +%s)
ARTIFACTS=/workspace/qa
mkdir -p "$ARTIFACTS"

REPO_SLUG="$(echo "$REPO_URL" | sed -E 's|^.*github\.com[:/]||; s|\.git$||')"
case "$REPO_URL" in
  https://*|http://*|git@*) : ;;
  *) echo "[qa] FATAL: REPO_URL not a valid clone URL: '$REPO_URL'" >&2; exit 2 ;;
esac

# QA_TARGET sanity-check: if set, must be a bare issue number (allow "issue-N").
QA_TARGET_NUM=""
if [ -n "$QA_TARGET" ]; then
  QA_TARGET_NUM="${QA_TARGET#issue-}"
  QA_TARGET_NUM="${QA_TARGET_NUM##*#}"
  case "$QA_TARGET_NUM" in
    ''|*[!0-9]*) echo "[qa] FATAL: QA_TARGET must be an issue number (e.g. 42 or issue-42): '$QA_TARGET'" >&2; exit 2 ;;
  esac
fi

emit() { echo "STATUS: $1${2:+ :: $2}"; printf '%s' "$1" > /dev/termination-log 2>/dev/null || true; STATUS_EMITTED=1; }
fail() { emit FAILED "$1"; exit 1; }
STATUS_EMITTED=0
trap 'rc=$?; if [ "$STATUS_EMITTED" = 0 ]; then emit FAILED "qa-agent.sh exited rc=$rc at line $LINENO without emit"; fi' EXIT

echo "=== qa-agent: target=$WEB_URL repo=$REPO_SLUG qa_target=${QA_TARGET_NUM:-none} ==="

# ── 0. Reachability is a HARD precondition, with retry/backoff. ───────────────
# A QA pod that can't reach the app must NOT be indistinguishable from a clean
# pass. A transient pod-restart / port-forward race shouldn't kill QA, so poll
# with backoff first; a persistent miss is an INFRA block — emit NEEDS_HUMAN (the
# driver surfaces it, driver.md), never a silent FAILED the sprint then closes
# as "no new bugs found".
reach_tries="${QA_REACH_TRIES:-6}"
reach_delay="${QA_REACH_DELAY:-2}"
reach_ok=0
for attempt in $(seq 1 "$reach_tries"); do
  if curl -sS --max-time 5 -o /dev/null -w "[qa] reachability $attempt/$reach_tries: HTTP %{http_code} in %{time_total}s\n" "$WEB_URL"; then
    reach_ok=1; break
  fi
  if [ "$attempt" -lt "$reach_tries" ]; then
    echo "[qa] target not reachable yet — retrying in ${reach_delay}s"
    sleep "$reach_delay"
    reach_delay=$((reach_delay * 2))
  fi
done
if [ "$reach_ok" = 0 ]; then
  emit NEEDS_HUMAN "target $WEB_URL not reachable after $reach_tries attempts — INFRA block (app not exposed / port-forward down). QA did NOT run; do not count as a clean pass."
  exit 1
fi

# ── 1. Baseline capture (lean — just what the agent can't get later) ──────────
echo "[qa] stage 1/3: baseline capture -> $ARTIFACTS"
if ! node /usr/local/bin/qa-capture.mjs "$WEB_URL" "$ARTIFACTS"; then
  fail "baseline capture failed"
fi
SCREENSHOTS=$(ls "$ARTIFACTS"/*.png 2>/dev/null | sort)
[ -n "$SCREENSHOTS" ] || fail "baseline capture produced no screenshots"
echo "[qa] baseline: $(echo "$SCREENSHOTS" | wc -l | tr -d ' ') screenshot(s) + text artifacts"

SHOT_LIST=""
for s in $SCREENSHOTS; do
  base=$(basename "$s")
  case "$base" in
    01-initial.png) cap="initial paint (DOMContentLoaded, before data)" ;;
    02-loaded.png)  cap="after networkidle (data should be rendered)" ;;
    *)              cap="$base" ;;
  esac
  SHOT_LIST="${SHOT_LIST}- ${s} — ${cap}
"
done

# ── 2. Claude analysis — agent drives Playwright itself via MCP ───────────────
PAGE_TXT="$ARTIFACTS/page.txt"
CONSOLE_LOG="$ARTIFACTS/console.log"
NETWORK_LOG="$ARTIFACTS/network.log"
META_JSON="$ARTIFACTS/meta.json"

# Configure claude to spawn the official @playwright/mcp server. The browser
# runs inside the same pod as claude; chromium is already installed.
MCP_CONFIG=/tmp/qa-mcp.json
cat > "$MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest",
               "--browser=chromium",
               "--headless",
               "--no-sandbox",
               "--viewport-size=1280,720"]
    }
  }
}
EOF

# QA never clones the code tree, so the hive-qa skill can't auto-load from a
# repo. Ship it into claude's cwd (/workspace, the image WORKDIR) so Claude Code
# discovers it as an available skill. Only ever touches hive's own namespace.
QA_SKILL_SRC="${HIVE_SKILLS_DIR:-/opt/hive/skills}/hive-qa/SKILL.md"
if [ -r "$QA_SKILL_SRC" ]; then
  mkdir -p .claude/skills/hive-qa
  cp -f "$QA_SKILL_SRC" .claude/skills/hive-qa/SKILL.md \
    && echo "[qa] shipped hive-qa skill -> .claude/skills/hive-qa/SKILL.md"
else
  echo "[qa] WARN: hive-qa skill not found at $QA_SKILL_SRC — falling back to prompt-only guidance"
fi

# Thin pointer. The method + report format live in the hive-qa skill; the
# prompt carries only the dynamic bits (target URL, baseline artifact paths,
# the issue under verification) plus the load-bearing RESULT marker.
PROMPT="Follow the \`hive-qa\` skill — it defines the QA method and the report format.

Target app: ${WEB_URL}
${QA_TARGET_NUM:+Issue being verified: #${QA_TARGET_NUM}
}
Baseline capture from a prior Playwright run — read with the Read tool (Read
supports PNG images):

${SHOT_LIST}- ${PAGE_TXT} — rendered document.body.innerText
- ${CONSOLE_LOG} — every browser console event during load
- ${NETWORK_LOG} — every failed request / non-2xx response during load
- ${META_JSON} — capture metadata + any baseline errors

You also have a LIVE Playwright browser via the playwright MCP — drive it
yourself to do everything the baseline can't show you (navigate to ${WEB_URL},
scroll below the fold, hover/click interactive elements, resize to a mobile
viewport, visit every route, screenshot whenever it sharpens a claim). Live
interaction is the heart of the job; the baseline only exists for
console/network grounding.

Do NOT run git or gh — the harness publishes your report as the feedback issue.
End your reply with exactly one line:
RESULT: REPORTED"

CLAUDE_OUT=/tmp/qa.out
: > "$CLAUDE_OUT"
MODEL="${MODEL:-sonnet}"
MAX_TURNS="${MAX_TURNS:-120}"   # USD + time are the real guardrails, not the turn cap

budget_arg=""
if [ -n "${COST_LIMIT_USD:-}" ]; then
  budget_arg="--max-budget-usd $COST_LIMIT_USD"
fi

echo "[qa] stage 2/3: claude + playwright MCP (model=$MODEL max-turns=$MAX_TURNS budget=\$${COST_LIMIT_USD:-∞})"
# shellcheck disable=SC2086
claude -p "$PROMPT" \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS" \
  $budget_arg \
  --mcp-config "$MCP_CONFIG" \
  --output-format stream-json --verbose --dangerously-skip-permissions 2>&1 \
  | tee -a "$CLAUDE_OUT"
crc=${PIPESTATUS[0]}
[ "$crc" -eq 0 ] || fail "claude exited rc=$crc"
is_err=$(jq -r 'select(.type=="result") | .is_error // false' "$CLAUDE_OUT" 2>/dev/null | head -1)
err_subtype=$(jq -r 'select(.type=="result") | .subtype // empty' "$CLAUDE_OUT" 2>/dev/null | head -1)
[ "$is_err" = "true" ] && fail "claude is_error=true subtype=${err_subtype:-unknown}"
report=$(jq -s 'map(select(.type=="result"))[-1].result // empty' "$CLAUDE_OUT" 2>/dev/null)
[ -n "$report" ] || fail "claude produced no result text"

# Strip the trailing RESULT marker line.
report_body=$(printf '%s' "$report" | sed -E '/^[-* ]*\**[Rr][Ee][Ss][Uu][Ll][Tt]\**[[:space:]:]*[Rr][Ee][Pp][Oo][Rr][Tt][Ee][Dd]\**\.?$/d')

# ── 3. Push artifacts to an orphan branch + create the feedback issue ─────────
# An orphan branch has NO shared history with `main`, so this push does not
# expose any code to (or pull any code into) the QA pod. The push happens in
# a fresh empty git workdir we never `git clone` into.
echo "[qa] stage 3/3: push artifacts to orphan branch + gh issue create"

ARTIFACT_BRANCH="qa-artifacts/issue-${QA_TARGET_NUM:-untargeted}/$(date -u +%Y%m%dT%H%M%SZ)"
PUSH_DIR=/workspace/qa-push
rm -rf "$PUSH_DIR"
mkdir -p "$PUSH_DIR"

artifact_branch_url=""
if [ -z "${GITHUB_PAT_TOKEN:-}${GH_TOKEN:-}" ]; then
  echo "[qa] WARN: no GH token — skipping orphan-branch push; the issue will have screenshots inline only"
else
  (
    cd "$PUSH_DIR"
    git init -q -b "$ARTIFACT_BRANCH"
    cp -R "$ARTIFACTS"/. ./
    # README so a human landing on the branch knows what they're looking at.
    {
      printf "# QA artifacts — %s\n\n" "$ARTIFACT_BRANCH"
      printf "- target URL: \`%s\`\n" "$WEB_URL"
      [ -n "$QA_TARGET_NUM" ] && printf "- verifying issue: #%s\n" "$QA_TARGET_NUM"
      printf "- captured at: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf "\nThis branch is an orphan — it shares no history with \`main\`.\n"
    } > README.md
    git add -A
    GIT_AUTHOR_NAME="qa-agent" GIT_AUTHOR_EMAIL="qa-agent@coding.local" \
      GIT_COMMITTER_NAME="qa-agent" GIT_COMMITTER_EMAIL="qa-agent@coding.local" \
      git commit -q -m "qa: artifacts for ${QA_TARGET_NUM:+#$QA_TARGET_NUM at }$WEB_URL"
    git remote add origin "$REPO_URL"
    if ! git push -q --set-upstream origin "$ARTIFACT_BRANCH" 2>&1; then
      echo "[qa] WARN: orphan-branch push failed — issue will have inline screenshots only" >&2
      exit 1
    fi
  ) && artifact_branch_url="https://github.com/${REPO_SLUG}/tree/${ARTIFACT_BRANCH}"
fi
[ -n "$artifact_branch_url" ] && echo "[qa] artifacts pushed: $artifact_branch_url"

# Compose the feedback issue body. Always inline the report; add the
# artifact-branch tree URL if we managed to push it.
meta_block=$(printf '> Auto-generated by the QA agent. No source code was read.\n>\n> - target: \`%s\`\n%s> - captured: %s screenshot(s)\n%s' \
  "$WEB_URL" \
  "${QA_TARGET_NUM:+> - verifying: #${QA_TARGET_NUM}
}" \
  "$(echo "$SCREENSHOTS" | wc -l | tr -d ' ')" \
  "${artifact_branch_url:+> - artifacts: $artifact_branch_url
}")

body=$(printf '%s\n\n## Report\n\n%s\n' "$meta_block" "$report_body")
issue_title="QA: ${WEB_URL}${QA_TARGET_NUM:+ (verifying #${QA_TARGET_NUM})}"

label_args=(--label "type:qa-feedback" --label "status:ready")
issue_url=$(gh -R "$REPO_SLUG" issue create \
  --title "$issue_title" \
  --body  "$body" \
  "${label_args[@]}" 2>&1) || fail "gh issue create failed: $issue_url"

# `gh issue create` prints the URL on success — strip everything else just
# in case (e.g. a deprecation notice line).
created_url=$(printf '%s\n' "$issue_url" | grep -oE 'https://github\.com/[^[:space:]]+' | head -1)
created_num=$(printf '%s\n' "$created_url" | sed -E 's|^.*/issues/||; s|[^0-9].*$||')
[ -n "$created_url" ] || fail "gh issue create returned no URL (response: $issue_url)"

# ── METRICS + final status ────────────────────────────────────────────────────
WALL_S=$(( $(date +%s) - RUN_START_EPOCH ))
R=$(jq -s '
  [.[] | select(.type=="result")] as $r |
  { total_cost_usd: ([$r[].total_cost_usd // 0] | add // 0),
    duration_ms:    ([$r[].duration_ms    // 0] | add // 0),
    num_turns:      ([$r[].num_turns      // 0] | add // 0),
    usage: {
      input_tokens:                ([$r[].usage.input_tokens                // 0] | add // 0),
      output_tokens:               ([$r[].usage.output_tokens               // 0] | add // 0),
      cache_read_input_tokens:     ([$r[].usage.cache_read_input_tokens     // 0] | add // 0),
      cache_creation_input_tokens: ([$r[].usage.cache_creation_input_tokens // 0] | add // 0)
    } }
' "$CLAUDE_OUT" 2>/dev/null || echo '{}')
METRICS=$(jq -nc \
  --arg issue_id "$ISSUE_ID" --arg type "qa" --arg repo "$(basename "${REPO_URL%.git}")" \
  --arg repo_slug "$REPO_SLUG" \
  --arg role "qa" --arg model "$MODEL" \
  --arg target "${QA_TARGET_NUM:-}" --arg web_url "$WEB_URL" \
  --arg created "${created_num:-}" --arg created_url "${created_url:-}" \
  --arg artifact_branch "${ARTIFACT_BRANCH:-}" --arg artifact_branch_url "${artifact_branch_url:-}" \
  --arg cost_limit "${COST_LIMIT_USD:-}" \
  --argjson wall_s "$WALL_S" --argjson r "$R" \
  --argjson n_shots "$(echo "$SCREENSHOTS" | wc -l | tr -d ' ')" \
  '{issue_id:$issue_id, task_type:$type, repo:$repo, repo_slug:$repo_slug,
    role:$role, model:$model,
    qa_target:$target, web_url:$web_url,
    feedback_issue:$created, feedback_issue_url:$created_url,
    artifact_branch:$artifact_branch, artifact_branch_url:$artifact_branch_url,
    screenshots:$n_shots,
    wall_s:$wall_s,
    cost_usd:       ($r.total_cost_usd // 0),
    cost_limit_usd: ($cost_limit | if . == "" then null else tonumber end),
    duration_ms:    ($r.duration_ms // 0),
    num_turns:      ($r.num_turns // 0),
    input_tokens:   ($r.usage.input_tokens // 0),
    output_tokens:  ($r.usage.output_tokens // 0),
    cache_read:     ($r.usage.cache_read_input_tokens // 0),
    cache_creation: ($r.usage.cache_creation_input_tokens // 0)}')
echo "METRICS: $METRICS"

echo "[qa] created feedback issue #${created_num}  ->  $created_url"
emit SUCCEEDED "$created_url"
echo "=== done: qa $WEB_URL -> #${created_num} ==="
exit 0
