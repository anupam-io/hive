#!/usr/bin/env bash
set -euo pipefail
# ONE-SHOT: wire auth, run a single task, exit. Task comes from container args.

# ── Claude auth: first mode present wins (credentials.json > token > api key) ──
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"
# Attribute commits to the agent identity only — drop Claude's
# "Co-Authored-By: Claude" / "Generated with Claude Code" trailers.
echo '{"includeCoAuthoredBy": false}' > "$CLAUDE_DIR/settings.json"
if [ -f /auth/.credentials.json ]; then
  install -m 600 /auth/.credentials.json "$CLAUDE_DIR/.credentials.json"
  echo "[agent] auth: OAuth credentials.json"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  # Accept either shape and ALWAYS land a valid credentials.json:
  #   (a) full JSON blob → write verbatim
  #   (b) raw OAuth bearer token (sk-ant-oat01-…) → wrap in the claudeAiOauth
  #       JSON the CLI expects. Long-lived tokens have no refresh; we set
  #       expiresAt to year 2100 so the CLI never tries to refresh.
  case "$CLAUDE_CODE_OAUTH_TOKEN" in
    \{*)
      printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "$CLAUDE_DIR/.credentials.json"
      echo "[agent] auth: OAuth credentials JSON (wired to credentials.json)"
      ;;
    *)
      jq -n --arg t "$CLAUDE_CODE_OAUTH_TOKEN" \
        '{claudeAiOauth:{accessToken:$t,refreshToken:"",expiresAt:4102444800000,scopes:["user:inference","user:profile"]}}' \
        > "$CLAUDE_DIR/.credentials.json"
      echo "[agent] auth: OAuth bearer token (wrapped into credentials.json)"
      ;;
  esac
  chmod 600 "$CLAUDE_DIR/.credentials.json"
  unset CLAUDE_CODE_OAUTH_TOKEN
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[agent] auth: API key"
else
  echo "[agent] FATAL: no Claude auth (credentials.json / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY)" >&2
  exit 1
fi

# ── GitHub auth for git + gh ──────────────────────────────────────────────────
# Every role needs gh now: the worker/reviewer for issues/PRs/comments, and
# the qa role for `gh issue create` (type:qa-feedback) + pushing artifacts to
# an ORPHAN branch on the project repo (never the code tree — see qa-agent.sh).
if [ -n "${GITHUB_PAT_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_PAT_TOKEN" > "$HOME/.git-credentials"
  export GH_TOKEN="$GITHUB_PAT_TOKEN"
else
  echo "[agent] WARN: GITHUB_PAT_TOKEN not set — git push and gh will fail" >&2
fi

# Run the one task, then the container exits (one-shot). qa role gets a
# different body — no clone, no code checkout, just playwright + an orphan
# artifact branch + gh issue create.
if [ "${TASK_TYPE:-}" = "qa" ]; then
  exec qa-agent "$@"
else
  exec agent "$@"
fi
