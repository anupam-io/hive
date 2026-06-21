#!/usr/bin/env bash
set -euo pipefail
# Point-and-fire: run the coding agent on ONE GitHub issue.
#
#   ./run.sh <ISSUE_NUMBER> [REPO_URL] [TASK_TYPE]
#
# Set REPO_URL once and you only need the issue number + type:
#   export REPO_URL=https://github.com/org/repo
#   ./run.sh 42 "" research
#
# TASK_TYPE is one of: feature-implementation | bug-fix | improvement | research | qa
# (pr-review and pr-merge are retired — the worker reviews + gates its own PR
#  in-pod, and merge is now a local `hivectl merge`, not a pod fire.)
# (the repo's .claude/CLAUDE.md owns the routing — sandbox just hints).

ISSUE_NUMBER="${1:?usage: ./run.sh <ISSUE_NUMBER> [REPO_URL] [TASK_TYPE] [BASE_BRANCH]}"
REPO="${2:-${REPO_URL:-}}"
TASK_TYPE="${3:-${TASK_TYPE:-}}"
BASE_BRANCH="${4:-${BASE_BRANCH:-main}}"

# Tolerate either "42" or "issue-42" — the in-pod scripts normalize either.
ISSUE_NUMBER="${ISSUE_NUMBER#issue-}"
ISSUE_NUMBER="${ISSUE_NUMBER##*#}"
case "$ISSUE_NUMBER" in
  ''|*[!0-9]*) echo "ISSUE_NUMBER must be a positive integer (got '$1')" >&2; exit 1;;
esac

# The canonical issue identifier used in branch names, pod labels, run dirs.
ISSUE_ID="issue-${ISSUE_NUMBER}"

# Every fire needs a repo URL — qa fires too, now that QA artifacts are pushed
# to an orphan branch on the project repo (see qa-agent.sh). qa never clones
# or checks out the code tree; the push happens in a fresh empty workdir.
[ -n "$REPO" ] || { echo "no repo — pass as 2nd arg or 'export REPO_URL=...'"; exit 1; }

# Per-project config — bin/hivectl exports these from .hive/config.yaml. Defaults
# keep the script usable for ad-hoc invocations outside the hivectl wrapper.
APP="${HIVE_APP:-coding-agent}"
AGENTS_NAMESPACE="${HIVE_CLUSTER_AGENTS_NS:-agents}"
SECRET_NAME="${HIVE_CLUSTER_SECRET:-coding-agent-creds}"
NS="$AGENTS_NAMESPACE"
# Unique per-fire name: <app>-issue-42-<unix-ts>. Includes app so two projects
# firing the same issue number at the same instant don't collide in `agents/`.
FIRE_TS="$(date +%s)"
NAME="$APP-${ISSUE_ID}-$FIRE_TS"
AGENT="coding-agent-$NAME"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve MODEL + ROLE the same way agent.sh / qa-agent.sh do, so the pod
# labels match what actually runs. Env overrides (MODEL=opus ./run.sh ...) win.
case "$TASK_TYPE" in
  qa)        ROLE="qa"       ;;
  *)         ROLE="worker"   ;;
esac
# Every ephemeral pod (worker in all modes, qa) runs on Sonnet — only the local
# driver runs on Opus. Never Fable 5 (disqualified) and never Haiku. Precedence:
# explicit MODEL env > project config (defaults.model -> HIVE_DEFAULT_MODEL) >
# this default. ROLE still drives limits + labels.
MODEL="${MODEL:-${HIVE_DEFAULT_MODEL:-sonnet}}"

# Role-based resource ceilings (Kubernetes `limits`, not requests). These are
# the MAXIMUM a pod can use — k8s OOM-kills on memory, throttles on CPU.
# Override per-fire with CPU_LIMIT=… MEM_LIMIT=… ./run.sh …
case "$ROLE" in
  qa) CPU_LIMIT_DEFAULT="2"; MEM_LIMIT_DEFAULT="4Gi" ;; # chromium is hungry
  *)  CPU_LIMIT_DEFAULT="1"; MEM_LIMIT_DEFAULT="2Gi" ;;
esac
CPU_LIMIT="${CPU_LIMIT:-$CPU_LIMIT_DEFAULT}"
MEM_LIMIT="${MEM_LIMIT:-$MEM_LIMIT_DEFAULT}"

# Per-task $USD ceiling — Claude Code's native --max-budget-usd. agent.sh (the
# worker) makes it per-fire by passing the remaining budget across hammers;
# qa-agent.sh is single-shot and just passes the cap. The three coding modes +
# research get the larger cap; qa the smaller. Precedence: explicit
# COST_LIMIT_USD env > project config (defaults.cost_limit_usd ->
# HIVE_DEFAULT_COST_LIMIT_USD, a flat override) > this per-task default.
# NOTE: the worker's in-pod self-review carries its OWN budget
# (REVIEW_COST_LIMIT_USD in agent.sh, default $2) on top of this cap.
case "$TASK_TYPE" in
  feature-implementation|bug-fix|improvement|research) COST_DEFAULT="5" ;;
  *)                                                   COST_DEFAULT="2" ;;
esac
COST_LIMIT_USD="${COST_LIMIT_USD:-${HIVE_DEFAULT_COST_LIMIT_USD:-$COST_DEFAULT}}"

# qa-only inputs — passed through to qa-agent.sh via the manifest. Empty for
# non-qa fires; the YAML envs default to "" which qa-agent treats as
# "no verifying target".
WEB_URL="${WEB_URL:-}"
QA_TARGET="${QA_TARGET:-}"
if [ "$TASK_TYPE" = "qa" ]; then
  [ -n "$WEB_URL" ] || { echo "qa fires require WEB_URL (e.g. WEB_URL=http://web.prod.svc.cluster.local:3000)"; exit 1; }
fi

echo "[fire] #$ISSUE_NUMBER  ->  ${WEB_URL:-$REPO}  type=${TASK_TYPE:-?}  model=$MODEL  role=$ROLE  cpu=$CPU_LIMIT  mem=$MEM_LIMIT  budget=\$$COST_LIMIT_USD  (sandbox/$AGENT)"

# Two images, one tag (latest) — built and loaded into the cluster ONCE by
# `hivectl agent-setup` (ops/claude-code-setup.sh steps 2-3). A fire does NOT
# build, re-tag, or re-load — it just references the image already in the
# cluster (imagePullPolicy: IfNotPresent). If the cluster was recreated, re-run
# `hivectl agent-setup` (same lifecycle as the secret).
#   coding-agent  — worker (lean, no browser)
#   web-qa-agent  — qa role only (base + playwright + chromium)
IMAGE_TAG="latest"
case "$ROLE" in
  qa) IMAGE_REPO="web-qa-agent" ;;
  *)  IMAGE_REPO="coding-agent" ;;
esac

# Fill the template (sed, so no envsubst dependency) and apply — this is the trigger.
sed -e "s|\${AGENT_NAME}|$NAME|g" \
    -e "s|\${APP}|$APP|g" \
    -e "s|\${AGENTS_NAMESPACE}|$AGENTS_NAMESPACE|g" \
    -e "s|\${SECRET_NAME}|$SECRET_NAME|g" \
    -e "s|\${ISSUE_NUMBER}|$ISSUE_NUMBER|g" \
    -e "s|\${ISSUE_ID}|$ISSUE_ID|g" \
    -e "s|\${REPO_URL}|$REPO|g" \
    -e "s|\${TASK_TYPE}|$TASK_TYPE|g" \
    -e "s|\${BASE_BRANCH}|$BASE_BRANCH|g" \
    -e "s|\${IMAGE_TAG}|$IMAGE_TAG|g" \
    -e "s|\${IMAGE_REPO}|$IMAGE_REPO|g" \
    -e "s|\${MODEL}|$MODEL|g" \
    -e "s|\${ROLE}|$ROLE|g" \
    -e "s|\${CPU_LIMIT}|$CPU_LIMIT|g" \
    -e "s|\${MEM_LIMIT}|$MEM_LIMIT|g" \
    -e "s|\${COST_LIMIT_USD}|$COST_LIMIT_USD|g" \
    -e "s|\${WEB_URL}|$WEB_URL|g" \
    -e "s|\${QA_TARGET}|$QA_TARGET|g" \
    "$DIR/manifests/sandbox.yaml" | kubectl apply -f -

echo "[fire] waiting for pod to schedule…"
for _ in $(seq 1 30); do
  # Select by per-fire agent label, not issue — multiple fires for the same
  # issue coexist now, and issue-label match would pick an unrelated pod.
  pod="$(kubectl -n "$NS" get pod -l agent="$NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] && break
  sleep 1
done
[ -n "$pod" ] || { echo "[fire] pod never scheduled"; exit 1; }

AGENTS_DIR="${AGENTS_DIR:-${HIVE_AGENTS_DIR:-${HIVE_STATE_DIR:-$HOME/.hive}/.agents}}"
mkdir -p "$AGENTS_DIR"
# One dir per fire so multiple runs on the same issue don't clobber each other.
LOCAL_DIR="$AGENTS_DIR/${ISSUE_ID}-$(date +%s)"
mkdir -p "$LOCAL_DIR"
LOG_FILE="$LOCAL_DIR/run.log"
echo "[fire] live log -> $LOG_FILE   (tail -f to follow)"

# Wait for container to actually start before streaming (image pull, etc.).
for _ in $(seq 1 60); do
  state="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)"
  [ -n "$state" ] && ! echo "$state" | grep -q 'waiting' && break
  sleep 1
done

# Fire-and-forget: stream pod stdout to the log file in the BACKGROUND so this
# script exits immediately. The agent keeps running on the cluster; the
# Mac-side tailer keeps writing to $LOG_FILE until the pod terminates.
nohup kubectl -n "$NS" logs -f "$pod" >> "$LOG_FILE" 2>&1 &
TAILER_PID=$!
echo "[fire] streaming logs in background (pid=$TAILER_PID)"
echo "[fire] follow:   tail -f $LOG_FILE"
echo "[fire] pod:      kubectl -n $NS get pod $pod"
echo "[fire] cleanup:  kubectl -n $NS delete sandbox $AGENT"
