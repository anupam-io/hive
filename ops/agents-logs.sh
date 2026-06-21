#!/usr/bin/env bash
set -euo pipefail
# Helpers for coding-agent logs persisted at $HIVE_STATE_DIR/.agents/
# (default $HOME/.hive/.agents/).
#
#   ./ops/agents-logs.sh ls                       # list all runs
#   ./ops/agents-logs.sh tail <ISSUE>             # live-tail a running agent's stdout
#   ./ops/agents-logs.sh show <ISSUE>             # print latest local run.log for an issue
#   ./ops/agents-logs.sh pull <ISSUE>             # re-pull /logs from a still-existing pod
#   ./ops/agents-logs.sh clean [<repo>]           # wipe local .agents/ (or one repo's dir)
#
# <ISSUE> accepts either `42` or `issue-42`.

HIVE_STATE_DIR="${HIVE_STATE_DIR:-${HIVE_STATE_DIR:-$HOME/.hive}}"
AGENTS_DIR="${HIVE_AGENTS_DIR:-$HIVE_STATE_DIR/.agents}"
NS="${HIVE_CLUSTER_AGENTS_NS:-agents}"
APP_LABEL_FILTER="${HIVE_APP:+,app=$HIVE_APP}"

mkdir -p "$AGENTS_DIR"

# Normalize the issue arg: accept "42" or "issue-42", emit the issue-N form.
normalize_issue_id() {
  local a="${1:-}"
  a="${a#issue-}"
  a="${a##*#}"
  echo "issue-$a"
}

cmd="${1:-ls}"; shift || true

case "$cmd" in
  ls)
    if ! find "$AGENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
      echo "(no runs yet at $AGENTS_DIR)"; exit 0
    fi
    # Each run is a dir <issue-N>-<unix-ts>; sorting puts newest last.
    find "$AGENTS_DIR" -mindepth 1 -maxdepth 1 -type d \
      | sed "s|$AGENTS_DIR/||" | sort
    ;;
  tail)
    ISSUE_ID=$(normalize_issue_id "${1:?usage: agents-logs.sh tail <ISSUE>}")
    # Scope by app= label too — two projects can have the same issue id; we
    # never want to tail another project's pod.
    pod="$(kubectl -n "$NS" get pod -l "issue_id=$ISSUE_ID$APP_LABEL_FILTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$pod" ] || { echo "no pod found for issue_id=$ISSUE_ID${HIVE_APP:+ app=$HIVE_APP} (already cleaned up?)"; exit 1; }
    exec kubectl -n "$NS" logs -f "$pod"
    ;;
  show)
    ISSUE_ID=$(normalize_issue_id "${1:?usage: agents-logs.sh show <ISSUE>}")
    latest="$(find "$AGENTS_DIR" -type d -name "${ISSUE_ID}-*" 2>/dev/null | sort | tail -1)"
    [ -n "$latest" ] || { echo "no local logs for $ISSUE_ID"; exit 1; }
    echo "[show] $latest"
    cat "$latest/run.log" 2>/dev/null || echo "(no run.log in $latest)"
    ;;
  pull)
    ISSUE_ID=$(normalize_issue_id "${1:?usage: agents-logs.sh pull <ISSUE>}")
    pod="$(kubectl -n "$NS" get pod -l "issue_id=$ISSUE_ID$APP_LABEL_FILTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$pod" ] || { echo "no pod found for issue_id=$ISSUE_ID${HIVE_APP:+ app=$HIVE_APP}"; exit 1; }
    # discover repo dir inside the pod
    repo="$(kubectl -n "$NS" exec "$pod" -- sh -c 'ls /logs 2>/dev/null | head -1' 2>/dev/null || true)"
    [ -n "$repo" ] || { echo "no /logs dir inside pod $pod"; exit 1; }
    dest="$AGENTS_DIR/$repo"
    mkdir -p "$dest"
    kubectl -n "$NS" cp "$pod:/logs/$repo/." "$dest/"
    echo "[pull] copied to $dest"
    ;;
  clean)
    target="${1:-}"
    if [ -n "$target" ]; then
      rm -rf "${AGENTS_DIR:?}/$target"
      echo "[clean] removed $AGENTS_DIR/$target"
    else
      rm -rf "${AGENTS_DIR:?}"/*
      echo "[clean] wiped $AGENTS_DIR"
    fi
    ;;
  -h|--help|help)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown command: $cmd"; exit 2
    ;;
esac
