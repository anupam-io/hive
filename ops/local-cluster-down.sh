#!/usr/bin/env bash
set -euo pipefail
# Tear down the local minikube cluster created by ops/local-cluster-up.sh.

PROFILE="${MINIKUBE_PROFILE:-local-cluster}"

minikube delete --profile="$PROFILE"
echo "local cluster down: profile=$PROFILE deleted"
