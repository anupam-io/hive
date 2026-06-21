#!/usr/bin/env bash
set -euo pipefail
# kubernetes-sigs/agent-sandbox — controller + CRDs (Sandbox, SandboxTemplate,
# SandboxClaim, WarmPool). Required for chital-sandbox + k8s-sandbox.

VERSION="${VERSION:-v0.4.6}"

kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/manifest.yaml"
# Extensions: WarmPool + SandboxClaim CRDs. Needed by chital-sandbox.
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/extensions.yaml"

# Best-effort wait for the controller to settle. Namespace name comes from the
# upstream manifest; if it changes, edit here.
kubectl -n agent-sandbox-system rollout status deployment --timeout=180s || true

echo "agent-sandbox: ok (version ${VERSION})"
echo "  kubectl get crd | grep agents.x-k8s.io"
