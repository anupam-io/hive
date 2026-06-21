#!/usr/bin/env bash
set -euo pipefail
# Single-node local k8s cluster on macOS via minikube + vfkit.
#
# Why this stack: vfkit uses Apple's native Virtualization framework —
# no docker, no Docker Desktop, no qemu wrapper. minikube manages the
# cluster lifecycle (start/stop/delete/image load) on top.
#
# Idempotent: re-running starts a stopped cluster, or no-ops if already running.

# Sizing for a typical sprint wave: 5-10 pods firing concurrently, each capped
# at 2-4 GiB (worker=2Gi, reviewer/qa=4Gi). 8 GiB RAM was tight; 40g disk filled
# up quickly when dead Sandbox CRs lingered (shutdownPolicy: Retain pre-P1).
# Defaults below are headroom-first; override at first start via env, e.g.:
#   DISK=80g MEMORY=16384 hivectl local-cluster-up
# (Override has no effect on an already-created profile — `hivectl local-cluster-down`
# first if you need to resize.)
PROFILE="${MINIKUBE_PROFILE:-local-cluster}"
NODES="${NODES:-1}"
K8S_VERSION="${K8S_VERSION:-stable}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-12288}"
DISK="${DISK:-60g}"

need() { command -v "$1" >/dev/null 2>&1; }

if ! need brew; then
  echo "brew not found — install Homebrew first: https://brew.sh" >&2
  exit 1
fi

if ! need minikube; then echo "==> installing minikube"; brew install minikube; fi
if ! need vfkit;    then echo "==> installing vfkit";    brew install vfkit;    fi
if ! need kubectl;  then echo "==> installing kubectl";  brew install kubectl;  fi

echo "==> minikube start (profile=$PROFILE, driver=vfkit, nodes=$NODES, k8s=$K8S_VERSION)"
minikube start \
  --profile="$PROFILE" \
  --driver=vfkit \
  --nodes="$NODES" \
  --kubernetes-version="$K8S_VERSION" \
  --cpus="$CPUS" \
  --memory="$MEMORY" \
  --disk-size="$DISK" \
  --container-runtime=containerd

kubectl config use-context "$PROFILE" >/dev/null
kubectl get nodes -o wide

echo
echo "local cluster up: context=$PROFILE"
echo "  tear down:                       hivectl local-cluster-down"
echo "  load host image into cluster:    minikube -p $PROFILE image load <img>:<tag>"
