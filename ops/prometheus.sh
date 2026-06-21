#!/usr/bin/env bash
set -euo pipefail
# Prometheus + kube-state-metrics + node-exporter — metrics for Headlamp's
# advanced charts. Local-dev only: no Alertmanager, no PVC, no auth.

HERE="$(cd "$(dirname "$0")" && pwd)"

kubectl apply -f "$HERE/prometheus.yaml"

kubectl -n monitoring rollout status deployment/kube-state-metrics --timeout=180s
kubectl -n monitoring rollout status daemonset/node-exporter --timeout=180s
kubectl -n monitoring rollout status deployment/prometheus --timeout=180s
kubectl -n monitoring rollout status deployment/pushgateway --timeout=180s

echo "prometheus: ok"
echo "  in-cluster URL:  http://prometheus.monitoring.svc.cluster.local:9090"
echo "  pushgateway URL: http://pushgateway.monitoring.svc.cluster.local:9091"
echo "  Headlamp: auto-detects monitoring/prometheus (no manual config needed)."
