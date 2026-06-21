.PHONY: setup resources cloud-provider-kind cloud-provider-kind-stop headlamp-token psql help \
        agent-setup agent-fire agent-logs agent-tail agent-clean agent-metrics agent-ui qa-fire \
        local-cluster-up local-cluster-down

REPO ?= https://github.com/bear-o-bear/chain-monitor
# Accept either ISSUE= or legacy TICKET= for one transition cycle.
ISSUE ?= $(TICKET)
TYPE ?=
KUBE_CTX ?= $(shell kubectl config current-context 2>/dev/null)
KIND_NODE ?= $(shell docker ps --format '{{.Names}}' | grep -E 'control-plane|kind|k3' | grep -v desktop | head -1)

help:
	@echo "Operator surface: 'hivectl <cmd>' wraps these targets — run 'hivectl help' for the CLI form."
	@echo ""
	@echo "Local cluster lifecycle (Mac dev only — minikube + vfkit):"
	@echo "  make local-cluster-up         — spin up the local 'local-cluster' minikube cluster (kubectl context: local-cluster)"
	@echo "  make local-cluster-down       — delete the local 'local-cluster' minikube cluster"
	@echo ""
	@echo "make setup                    — install metrics-server, prometheus, agent-sandbox, headlamp into the current cluster"
	@echo "make resources                — apply in-cluster shared resources (postgres on a persistent volume)"
	@echo "make cloud-provider-kind      — install + always-on launchd agent so kind LB services map to localhost"
	@echo "make cloud-provider-kind-stop — unload + remove the launchd agent"
	@echo "make headlamp-token           — mint a 10-year cluster-admin token for the headlamp UI login"
	@echo "make psql                     — open a psql shell inside the postgres pod (db=app)"
	@echo ""
	@echo "Coding agent (ISSUE is a GitHub issue number — '42' or 'issue-42'):"
	@echo "  make agent-setup                            — build image, import into cluster, create k8s secret from .env"
	@echo "  make agent-fire ISSUE=42 TYPE=research [REPO=...]"
	@echo "  make agent-logs                             — list local runs at \$$HIVE_AGENTS_DIR"
	@echo "  make agent-tail ISSUE=42                    — live-tail a running agent's stdout"
	@echo "  make agent-metrics [ISSUE=42]               — cost/tokens/duration table across runs"
	@echo "  make agent-ui                               — open the agent run-analytics UI (http://localhost:8001)"
	@echo "  make agent-clean                            — wipe \$$HIVE_AGENTS_DIR"
	@echo "  make qa-fire URL=http://web.prod.svc.cluster.local:3000 [TARGET=40]"
	@echo "                                              — fire a QA agent: playwright capture + claude vision + GH feedback issue"

local-cluster-up:
	@ops/local-cluster-up.sh

local-cluster-down:
	@ops/local-cluster-down.sh

setup:
	@ops/install.sh

resources:
	@kubectl apply -f ops/resources.yaml
	@kubectl -n resources rollout status statefulset/postgres --timeout=180s
	@echo
	@echo "postgres ready."
	@echo "  in-cluster:   postgres://test:test@postgres.resources.svc.cluster.local:5432/test"
	@echo "  from Mac:     postgres://test:test@localhost:5432/test   (needs make cloud-provider-kind)"

psql:
	@kubectl -n resources exec -it postgres-0 -- psql -U test -d test

cloud-provider-kind:
	@ops/cloud-provider-kind.sh

cloud-provider-kind-stop:
	@ops/cloud-provider-kind.sh stop

headlamp-token:
	@kubectl -n headlamp create token headlamp-admin --duration=87600h

# ── Coding agent ──────────────────────────────────────────────────────────────
agent-setup:
	@echo "[agent] kube context: $(KUBE_CTX)   secret: $${SECRET_NAME:-coding-agent-creds}"
	@SECRET_NAME="$${SECRET_NAME:-coding-agent-creds}" ops/claude-code-setup.sh

agent-fire:
	@test -n "$(ISSUE)" || { echo "usage: make agent-fire ISSUE=42 TYPE=research [REPO=...] [BASE=main]"; exit 1; }
	@test -n "$(TYPE)"   || { echo "TYPE is required (feature-implementation|bug-fix|improvement|research|qa)"; exit 1; }
	@case "$(TYPE)" in feature-implementation|bug-fix|improvement|research|qa) : ;; *) echo "TYPE not in allowlist: '$(TYPE)'"; exit 1 ;; esac
	@case "$(ISSUE)" in *' '*) echo "ISSUE looks shell-mis-split: '$(ISSUE)' — quote it or use a literal number"; exit 1 ;; esac
	@cd k8s-sandbox && ./run.sh $(ISSUE) $(REPO) $(TYPE) $(BASE)

qa-fire:
	@test -n "$(URL)" || { echo "usage: make qa-fire URL=http://web.prod.svc.cluster.local:3000 [TARGET=40] [REPO=...]"; exit 1; }
	@case "$(URL)" in http://*|https://*) : ;; *) echo "URL must start http:// or https:// (got '$(URL)')"; exit 1 ;; esac
	@cd k8s-sandbox && \
	  WEB_URL="$(URL)" QA_TARGET="$(TARGET)" \
	  ./run.sh "$(or $(TARGET),$(ISSUE),0)" "$(REPO)" qa main

agent-metrics:
	@ops/agent-metrics.sh $(ISSUE)

agent-ui:
	@echo "[ui] starting agent-ui on http://localhost:8001 (Ctrl-C to stop)"
	@python3 ops-ui/app.py

agent-logs:
	@ops/agents-logs.sh ls

agent-tail:
	@test -n "$(ISSUE)" || { echo "usage: make agent-tail ISSUE=42"; exit 1; }
	@ops/agents-logs.sh tail $(ISSUE)

agent-clean:
	@ops/agents-logs.sh clean
