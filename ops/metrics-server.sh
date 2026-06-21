#!/usr/bin/env bash
set -euo pipefail
# metrics-server, patched for docker-desktop / kind / minikube.
#
# Why the patch: those clusters use self-signed kubelet certs, and metrics-server
# refuses to scrape them by default — pod CrashLoops on `tls: failed to verify
# certificate`. The `--kubelet-insecure-tls` flag is the documented escape hatch.
# Do NOT use this patch on a real production cluster.

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl -n kube-system patch deployment metrics-server --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}
]'

kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
echo "metrics-server: ok — try 'kubectl top nodes'"
