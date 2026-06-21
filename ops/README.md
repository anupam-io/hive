# ops

Cluster-level deps for the local sandbox stack. **Local dev only** — every
choice here is too permissive for a real cluster.

## What gets installed

| Component | Why |
|---|---|
| **metrics-server** | `kubectl top`, HPA inputs. Patched with `--kubelet-insecure-tls` because docker-desktop / kind / minikube serve self-signed kubelet certs. |
| **agent-sandbox** | Controller + CRDs (`Sandbox`, `SandboxTemplate`, `SandboxClaim`, `WarmPool`) from `kubernetes-sigs/agent-sandbox`. Required for `chital-sandbox` and `k8s-sandbox`. Pinned to `v0.4.6`. |
| **headlamp** | k8s web UI on `http://localhost:4001`. Cluster-admin SA — login with a token from `make headlamp-token` (no `hivectl` wrapper for this one). |

## Install

```bash
./install.sh
```

Refuses to run unless the current kubectl context is `docker-desktop`, `kind-*`,
or `minikube`. To install pieces individually:

```bash
./metrics-server.sh
./agent-sandbox.sh                 # VERSION=v0.4.6 by default
kubectl apply -f headlamp.yaml
```

## Access

| What | How |
|---|---|
| Headlamp UI | `http://localhost:4001` (needs `make cloud-provider-kind`). Login: `make headlamp-token`. (Both `make`-only; not wrapped by `hivectl`.) |
| Node metrics | `kubectl top nodes` |
| Sandbox CRDs | `kubectl get crd \| grep agents.x-k8s.io` |

## Why these choices (and when to revisit)

- **`--kubelet-insecure-tls`** — fine on a local cluster you own. Never on
  anything shared. If you move to a real cluster, drop the patch and provision
  proper kubelet certs.
- **Headlamp + cluster-admin SA token** — picked for friction-free local use.
  On any shared cluster, switch to per-user OIDC and a namespace-scoped role.
- **agent-sandbox pinned to `v0.4.6`** — chital-sandbox + k8s-sandbox
  were built against this CRD shape. Override with `VERSION=vX.Y.Z ./agent-sandbox.sh`
  when you want to bump.
