#!/usr/bin/env bash
set -euo pipefail
# Install all cluster-level deps in one shot.
#   metrics-server       (kubectl top, HPA inputs)
#   prometheus           (metrics scrape — powers Headlamp's advanced charts)
#   agent-sandbox        (Sandbox / SandboxTemplate / WarmPool CRDs + controller)
#   headlamp             (web UI on http://localhost:4001, no auth — local dev only)

HERE="$(cd "$(dirname "$0")" && pwd)"

ctx="$(kubectl config current-context)"
echo "[ops/k8s] target context: ${ctx}"
case "$ctx" in
  docker-desktop|kind-*|k3d-*|minikube) ;;
  *)
    # Could still be a minikube profile with a non-default name (e.g. 'hive').
    if command -v minikube >/dev/null 2>&1 && minikube -p "$ctx" status >/dev/null 2>&1; then
      :
    else
      echo "[ops/k8s] refusing — this script targets local clusters only. Switch context first."; exit 1
    fi ;;
esac

# Fast-path: every component already installed → no-op cleanly. kubectl apply
# was always idempotent; this just stops the wall of "unchanged" output and
# tells the operator "you're done". Re-apply with FORCE=1.
all_installed() {
  kubectl -n kube-system           get deploy metrics-server -o name >/dev/null 2>&1 \
    && kubectl -n monitoring           get deploy prometheus     -o name >/dev/null 2>&1 \
    && kubectl -n agent-sandbox-system get deploy                -o name 2>/dev/null | grep -q . \
    && kubectl -n headlamp             get deploy headlamp       -o name >/dev/null 2>&1 \
    && kubectl -n agents               get cronjob hive-gc       -o name >/dev/null 2>&1
}
if [ "${FORCE:-}" != "1" ] && all_installed; then
  echo "[ops/k8s] all components already installed — skipping (re-run with FORCE=1 to re-apply)"
  exit 0
fi

"$HERE/metrics-server.sh"
"$HERE/prometheus.sh"
"$HERE/agent-sandbox.sh"
kubectl apply -f "$HERE/headlamp.yaml"
# hive-gc CronJob lives in the `agents` namespace (the shared pod pool). That ns
# is normally created per-project by `hivectl agent-setup`, but on a FRESH cluster
# `setup` runs first — so ensure it here, else the gc apply 404s. Idempotent.
kubectl create namespace agents --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$HERE/hive-gc.yaml"

echo
echo "[ops/k8s] done."
echo "  headlamp:   http://localhost:4001  (give the LB ~30s to provision)"
echo "  metrics:    kubectl top nodes"
echo "  prometheus: kubectl -n monitoring port-forward svc/prometheus 9090:9090"
echo "  CRDs:       kubectl get crd | grep agents.x-k8s.io"
echo "  hive-gc:    kubectl -n agents get cronjob hive-gc      (runs every 10min)"
