#!/usr/bin/env bash
set -euo pipefail
# Setup the k8s-sandbox end-to-end:
#   1. namespace
#   2. build the worker image
#   3. import image into the local cluster (auto-detects minikube / kind / k3d /
#      docker-desktop from kubectl context; explicit --k3s-container still wins)
#   4. create/update the per-app secret from a local .env file
#
# Usage:
#   ./ops/claude-code-setup.sh [--env-file PATH] [--secret-name NAME]
#                              [--k3s-container NAME] [--image-tag TAG]
#
# Defaults:
#   --env-file       <project>/.env if running under `hivectl agent-setup` and it exists,
#                    else $HIVE_STATE_DIR/.env (default $HOME/.hive/.env)
#   --secret-name    coding-agent-creds      (override via env: SECRET_NAME=<app>-creds)
#   --k3s-container  (none — auto-detect from kubectl context if blank)
#   --image-tag      coding-agent:latest
#
# Required keys in the .env file (kubectl reads it directly via --from-env-file;
# this script never cat/grep/echo the values):
#
#   ANTHROPIC_API_KEY=sk-ant-...           # OR
#   CLAUDE_CODE_OAUTH_TOKEN=...            # (pick one for Claude auth)
#   GH_AUTH_TOKEN=ghp_...                  # for git + gh (clone, push, gh issue, gh pr)

HIVE_STATE_DIR="${HIVE_STATE_DIR:-${HIVE_STATE_DIR:-$HOME/.hive}}"
# Prefer <project>/.env when running under `hivectl agent-setup` (bin/hivectl exports
# HIVE_PROJECT_DIR). Fall back to the global $HIVE_STATE_DIR/.env for ad-hoc
# invocations outside a project. Explicit --env-file always wins.
if [ -z "${ENV_FILE:-}" ]; then
  if [ -n "${HIVE_PROJECT_DIR:-}" ] && [ -f "$HIVE_PROJECT_DIR/.env" ]; then
    ENV_FILE="$HIVE_PROJECT_DIR/.env"
  else
    ENV_FILE="$HIVE_STATE_DIR/.env"
  fi
fi
K3S_CONTAINER="${K3S_CONTAINER:-}"
IMAGE="${IMAGE:-coding-agent:latest}"
QA_IMAGE="${QA_IMAGE:-web-qa-agent:latest}"
SECRET_NAME="${SECRET_NAME:-coding-agent-creds}"
SANDBOX_DIR="$(cd "$(dirname "$0")/../k8s-sandbox" && pwd)"
NS=agents

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)       ENV_FILE="$2"; shift 2 ;;
    --secret-name)    SECRET_NAME="$2"; shift 2 ;;
    --k3s-container)  K3S_CONTAINER="$2"; shift 2 ;;
    --image-tag)      IMAGE="$2"; shift 2 ;;
    --qa-image-tag)   QA_IMAGE="$2"; shift 2 ;;
    -h|--help)        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Ensure user-state dir exists before anything else writes there.
mkdir -p "$HIVE_STATE_DIR" "$HIVE_STATE_DIR/.agents"

if [ ! -f "$ENV_FILE" ]; then
  # Seed an empty .env stub the first time so the user knows where to put keys.
  if [ "$ENV_FILE" = "$HIVE_STATE_DIR/.env" ] && [ ! -f "$HIVE_STATE_DIR/.env.example" ]; then
    cat > "$HIVE_STATE_DIR/.env.example" <<'EOF'
# hive — user secrets. Loaded into the k8s 'coding-agent-creds' Secret by
# `hivectl agent-setup`. Pick one of ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN.
ANTHROPIC_API_KEY=
CLAUDE_CODE_OAUTH_TOKEN=
GH_AUTH_TOKEN=
EOF
    echo "[setup] wrote example env to $HIVE_STATE_DIR/.env.example"
  fi
  echo "env file not found: $ENV_FILE" >&2
  echo "  → copy $HIVE_STATE_DIR/.env.example to $HIVE_STATE_DIR/.env and fill in keys" >&2
  exit 1
fi

echo "[setup] (1/4) ensure namespace '$NS' exists"
kubectl apply -f "$SANDBOX_DIR/manifests/namespace.yaml"

echo "[setup] (2/4) build images $IMAGE + $QA_IMAGE"
docker build -t "$IMAGE" "$SANDBOX_DIR/image"
# web-qa-agent extends the base with playwright+chromium (FROM coding-agent),
# so this build is just one extra layer — only the qa role pulls it.
docker build -t "$QA_IMAGE" -f "$SANDBOX_DIR/image/Dockerfile.qa" "$SANDBOX_DIR/image"

# Import one built image into whatever local cluster is current. Same auto-detect
# logic as run.sh; called once per image so both land in the cluster.
load_image() {
  img="$1"
  if [ -n "$K3S_CONTAINER" ]; then
    echo "[setup] (3/4) import $img into k3s container '$K3S_CONTAINER'"
    docker save "$img" | docker exec -i "$K3S_CONTAINER" ctr -n k8s.io images import -
    return
  fi
  KCTX="$(kubectl config current-context 2>/dev/null || true)"
  case "$KCTX" in
    docker-desktop)
      echo "[setup] (3/4) docker-desktop: host docker == cluster containerd, nothing to do for $img" ;;
    kind-*)
      echo "[setup] (3/4) kind: loading $img into ${KCTX#kind-}"
      kind load docker-image "$img" --name "${KCTX#kind-}" ;;
    k3d-*)
      echo "[setup] (3/4) k3d: importing $img into ${KCTX#k3d-}"
      k3d image import "$img" -c "${KCTX#k3d-}" ;;
    "")
      echo "[setup] (3/4) no kubectl context — skipped import of $img" ;;
    *)
      if command -v minikube >/dev/null 2>&1 && minikube -p "$KCTX" status >/dev/null 2>&1; then
        echo "[setup] (3/4) minikube: loading $img into profile $KCTX"
        minikube -p "$KCTX" image load "$img"
      else
        echo "[setup] (3/4) unknown context '$KCTX' — skipped import of $img" ;
      fi ;;
  esac
}

load_image "$IMAGE"
load_image "$QA_IMAGE"

echo "[setup] (4/4) create/update secret '$SECRET_NAME' from $ENV_FILE"
# --from-env-file reads the file directly; nothing in this script ever sees the
# values. --dry-run|apply makes it idempotent (create or update in one step).
kubectl -n "$NS" create secret generic "$SECRET_NAME" \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Surface which key NAMES landed in the secret (no values).
echo "[setup] secret keys present:"
kubectl -n "$NS" get secret "$SECRET_NAME" \
  -o jsonpath='{.data}' | jq -r 'keys[] | "  - " + .'

# Soft check for the three required auths (warns, doesn't fail — kubectl already
# only added what was in the file).
have() {
  kubectl -n "$NS" get secret "$SECRET_NAME" \
    -o jsonpath="{.data.$1}" 2>/dev/null | grep -q . && echo "yes" || echo "no"
}
echo "[setup] auth check:"
echo "  anthropic (ANTHROPIC_API_KEY):       $(have ANTHROPIC_API_KEY)"
echo "  anthropic (CLAUDE_CODE_OAUTH_TOKEN): $(have CLAUDE_CODE_OAUTH_TOKEN)"
echo "  github    (GH_AUTH_TOKEN):           $(have GH_AUTH_TOKEN)"

cat <<EOF

[setup] Done.

Test it:
  cd $SANDBOX_DIR
  ./run.sh <ISSUE_NUMBER> https://github.com/<you>/<repo> <task-type>

TASK_TYPE is one of:
  feature-implementation | bug-fix | improvement | research | qa
EOF
