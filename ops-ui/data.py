# Data loaders for the agent-ui dashboard.
#
# Three concerns:
#   1. Historical runs   → list_runs()       (shells out to ops/agent-metrics.sh)
#   2. Live agent pods   → list_live_runs()  (shells out to kubectl)
#   3. Prometheus stats  → build_prom()      (HTTP to PROM_URL)
#
# All three are exposed via cache-wrapped getters (get_runs / get_live /
# get_prom) so every API call is sub-millisecond after the first warm-up.

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path

from cache import cached

# ── Paths ─────────────────────────────────────────────────────────────────────
# Package files (read-only): ROOT = <wherever hive was installed>.
# Project state (writable): <project>/.hive/runs/<issue-N>-<ts>/run.log.
# Falls back to the global $HIVE_STATE_DIR/.agents/ for pre-per-project runs.
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HIVE_PROJECT_DIR = Path(os.environ.get("HIVE_PROJECT_DIR", os.getcwd()))
HIVE_STATE_DIR = Path(os.environ.get(
    "HIVE_STATE_DIR",
    os.environ.get("HIVE_STATE_DIR", os.path.expanduser("~/.hive")),
))
# Resolution order: explicit HIVE_AGENTS_DIR (e.g. migration / tests) >
# per-project <project>/.hive/runs if it exists > global state-dir fallback.
# Legacy ~/.hive/.agents/ data is picked up via HIVE_AGENTS_DIR during the
# per-project migration.
_explicit = os.environ.get("HIVE_AGENTS_DIR")
_project_runs = HIVE_PROJECT_DIR / ".hive" / "runs"
if _explicit:
    AGENTS_DIR = Path(_explicit)
elif _project_runs.exists():
    AGENTS_DIR = _project_runs
else:
    AGENTS_DIR = HIVE_STATE_DIR / ".agents"
METRICS_SH = ROOT / "ops" / "agent-metrics.sh"

# Sprint identity lives in the TARGET app repo on disk:
#   <APP_REPO>/sprints/sprint-N/promise.md  (issue list, planning header)
#   <APP_REPO>/sprints/sprint-N/result.md   (retro — its existence == closed)
APP_REPO = Path(os.environ.get("HIVE_APP_REPO", os.path.expanduser("~/chain-monitor")))

PROM_URL = os.environ.get("PROM_URL", "http://localhost:9090")


# ── Historical runs ──────────────────────────────────────────────────────────
def list_runs() -> list[dict]:
    """Rebuild .agents/all.jsonl (cheap — pure bash + jq) and read it back."""
    if not METRICS_SH.exists():
        return []
    subprocess.run(
        ["bash", str(METRICS_SH), "--write-jsonl"],
        cwd=str(ROOT), check=False, capture_output=True,
    )
    jsonl = AGENTS_DIR / "all.jsonl"
    if not jsonl.exists():
        return []
    i2s = issue_to_sprint()
    out: list[dict] = []
    for line in jsonl.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        row["sprint"] = i2s.get((row.get("issue_id") or "").lower(), "")
        out.append(row)
    return out


# ── Sprints (on-disk promise files in the target app repo) ───────────────────
# Promise files reference issues either as `#42` (GH style) or `issue-42`.
_ISSUE_RE = re.compile(r"(?:\bissue-(\d+)|#(\d+))\b")


def _parse_waves(text: str) -> dict:
    """{issue-id → wave-int} from the promise.md issue table's `wave` column.

    The table schema is `| # | type | title | files-owned | deps | wave | why |`
    (see sprint-plan SKILL). We locate the header row that has a `wave` column,
    then read each data row's first cell (issue #) and its wave cell. Returns {}
    if the file has no such table (older promises, hand-written sprints)."""
    waves: dict = {}
    lines = text.splitlines()
    hdr_idx, wave_col = None, None
    for i, line in enumerate(lines):
        if "|" not in line or "wave" not in line.lower():
            continue
        cells = [c.strip().lower() for c in line.strip().strip("|").split("|")]
        if "wave" in cells:
            hdr_idx, wave_col = i, cells.index("wave")
            break
    if hdr_idx is None:
        return waves
    for line in lines[hdr_idx + 1:]:
        s = line.strip()
        if not s.startswith("|"):
            break  # table ended
        if set(s) <= set("|-: "):
            continue  # separator row
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) <= wave_col:
            continue
        m = re.search(r"(\d+)", cells[0])
        wm = re.search(r"(\d+)", cells[wave_col])
        if m and wm:
            waves[f"issue-{m.group(1)}"] = int(wm.group(1))
    return waves


def _parse_promise(path: Path) -> dict:
    """Pull thesis, planned date, issue IDs, and issue→wave out of a promise.md."""
    try:
        text = path.read_text()
    except OSError:
        return {"thesis": "", "planned_at": "", "issues": [], "waves": {}}
    thesis = ""
    planned = ""
    for line in text.splitlines():
        s = line.strip()
        if not thesis and s.lower().startswith("**thesis:**"):
            thesis = s.split("**", 2)[-1].strip(": ").strip()
        if not planned and s.lower().startswith("**planned:**"):
            planned = s.split("**", 2)[-1].strip(": ").strip()
        if thesis and planned:
            break
    # Issues: any "#42" or "issue-42" anywhere in the file (the doc lists them
    # in markdown tables — regex over the whole text is simpler than parsing).
    issue_nums = {n for m in _ISSUE_RE.findall(text) for n in m if n}
    issues = sorted(f"issue-{n}" for n in issue_nums)
    return {"thesis": thesis, "planned_at": planned, "issues": issues,
            "waves": _parse_waves(text)}


def list_sprints() -> list[dict]:
    """Scan <APP_REPO>/sprints/sprint-*/ → enriched sprint dicts. Newest first."""
    root = APP_REPO / "sprints"
    if not root.exists():
        return []
    out: list[dict] = []
    for d in sorted(root.glob("sprint-*"), key=lambda p: p.name):
        if not d.is_dir():
            continue
        m = re.match(r"sprint-(\d+)", d.name)
        if not m:
            continue
        n = int(m.group(1))
        promise = d / "promise.md"
        if not promise.exists():
            continue
        parsed = _parse_promise(promise)
        result_path = d / "result.md"
        out.append({
            "n":           n,
            "name":        d.name,
            "thesis":      parsed["thesis"],
            "planned_at":  parsed["planned_at"],
            "issues":      parsed["issues"],
            "wave_of":     parsed["waves"],
            "closed":      result_path.exists(),
            "promise_path": str(promise),
            "result_path":  str(result_path) if result_path.exists() else "",
        })
    out.sort(key=lambda s: s["n"], reverse=True)
    return out


def issue_to_sprint() -> dict:
    """{issue-id → 'sprint-N'} flat lookup, cached. Later sprints win on dupes."""
    def _build() -> dict:
        mp: dict = {}
        for s in list_sprints():
            for t in s["issues"]:
                key = t.lower()
                # Later sprints overwrite earlier — an issue re-committed to a
                # newer sprint should report as that newer sprint.
                if key not in mp or s["n"] > int(mp[key].split("-")[1]):
                    mp[key] = s["name"]
        return mp
    return cached("issue_to_sprint", _build)


# ── Live agent pods ──────────────────────────────────────────────────────────
def list_live_runs() -> list[dict]:
    """
    Currently in-flight agent pods. Quiet failure if kubectl is unavailable
    or the cluster is offline — the UI degrades to "no live runs" instead
    of breaking.
    """
    try:
        proc = subprocess.run(
            ["kubectl", "-n", "agents", "get", "pods",
             "-l", "app.kubernetes.io/name=coding-agent",
             "-o", "json"],
            capture_output=True, text=True, timeout=4,
        )
        if proc.returncode != 0:
            return []
        data = json.loads(proc.stdout or "{}")
    except Exception:
        return []

    i2s = issue_to_sprint()
    out: list[dict] = []
    for item in data.get("items", []):
        md = item.get("metadata", {}) or {}
        labels = md.get("labels", {}) or {}
        st = item.get("status", {}) or {}
        phase = st.get("phase") or ""
        # Only Pending/Running are "in flight". Succeeded/Failed terminate.
        if phase not in ("Pending", "Running"):
            continue
        # Container ready state — distinguishes "spinning up" vs "doing work".
        ready = False
        for cs in st.get("containerStatuses") or []:
            if cs.get("name") == "agent":
                ready = bool(cs.get("ready"))
                break
        issue_id = labels.get("issue_id") or ""
        out.append({
            "pod":        md.get("name"),
            "issue_id":   issue_id,
            "task_type":  labels.get("task_type") or "",
            "role":       labels.get("role") or "",
            "model":      labels.get("model") or "",
            "phase":      phase,
            "ready":      ready,
            "started":    md.get("creationTimestamp") or "",
            "sprint":     i2s.get(issue_id.lower(), ""),
        })
    # Newest first.
    out.sort(key=lambda r: r["started"], reverse=True)
    return out


# ── Prometheus ───────────────────────────────────────────────────────────────
def prom_query(q: str) -> dict:
    try:
        url = f"{PROM_URL}/api/v1/query?query={urllib.parse.quote(q)}"
        with urllib.request.urlopen(url, timeout=3) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"status": "error", "error": str(e)}


# 1h sliding window for CPU/RAM distributions: sub-sample every 30s, then
# aggregate. Cluster totals come from node_exporter; agent totals from
# cAdvisor with the pause "POD" container filtered out.
_CL_CPU = 'sum(rate(node_cpu_seconds_total{mode!="idle"}[2m]))'
_CL_MEM = 'sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)'
_AG_CPU = (
    'sum(rate(container_cpu_usage_seconds_total'
    '{namespace="agents",container!="",container!="POD"}[2m]))'
)
_AG_MEM = (
    'sum(container_memory_working_set_bytes'
    '{namespace="agents",container!="",container!="POD"})'
)
PROM_QUERIES = {
    "agent_pods":         'count(kube_pod_info{namespace="agents"}) or vector(0)',
    "cluster_pods":       'count(kube_pod_info) or vector(0)',
    "cluster_nodes":      'count(kube_node_info) or vector(0)',
    "agent_cpu_mean":     f'avg_over_time(({_AG_CPU})[1h:30s])',
    "agent_cpu_p95":      f'quantile_over_time(0.95, ({_AG_CPU})[1h:30s])',
    "agent_cpu_max":      f'max_over_time(({_AG_CPU})[1h:30s])',
    "agent_mem_mean":     f'avg_over_time(({_AG_MEM})[1h:30s])',
    "agent_mem_p95":      f'quantile_over_time(0.95, ({_AG_MEM})[1h:30s])',
    "agent_mem_max":      f'max_over_time(({_AG_MEM})[1h:30s])',
    "cpu_mean":           f'avg_over_time(({_CL_CPU})[1h:30s])',
    "cpu_p95":            f'quantile_over_time(0.95, ({_CL_CPU})[1h:30s])',
    "cpu_max":            f'max_over_time(({_CL_CPU})[1h:30s])',
    "mem_mean":           f'avg_over_time(({_CL_MEM})[1h:30s])',
    "mem_p95":            f'quantile_over_time(0.95, ({_CL_MEM})[1h:30s])',
    "mem_max":            f'max_over_time(({_CL_MEM})[1h:30s])',
}


def build_prom() -> dict:
    out: dict = {}
    for k, q in PROM_QUERIES.items():
        r = prom_query(q)
        if r.get("status") != "success":
            return {"error": r.get("error") or "prometheus unreachable"}
        res = r.get("data", {}).get("result", [])
        out[k] = float(res[0]["value"][1]) if res else 0.0
    return out


# ── Log tail ─────────────────────────────────────────────────────────────────
def read_log_tail(path: str, n: int = 1500) -> str:
    """Tail the last n lines of a run.log without slurping the whole file."""
    p = Path(path)
    # Path-confine: only files under .agents/ can be read this way.
    if not p.exists() or not str(p.resolve()).startswith(str(AGENTS_DIR.resolve())):
        return ""
    try:
        with p.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            block = 8192
            data = b""
            while size > 0 and data.count(b"\n") <= n:
                read = min(block, size)
                size -= read
                f.seek(size)
                data = f.read(read) + data
        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines()
        return "\n".join(lines[-n:])
    except OSError:
        return ""


# ── Live pod logs ────────────────────────────────────────────────────────────
def kubectl_logs(pod: str, tail: int = 1500) -> str:
    """Fetch stdout of a live agent pod. Quiet failure → empty string."""
    # Belt-and-braces input check — caller also validates, but this is the
    # last line of defence before shelling out.
    if not pod or not all(c.isalnum() or c in "-." for c in pod):
        return ""
    try:
        proc = subprocess.run(
            ["kubectl", "-n", "agents", "logs", pod,
             "-c", "agent", f"--tail={tail}"],
            capture_output=True, text=True, timeout=5,
        )
        if proc.returncode != 0:
            return ""
        return proc.stdout or ""
    except Exception:
        return ""


# ── Cache-wrapped getters ────────────────────────────────────────────────────
def get_runs() -> list[dict]:
    return cached("runs", list_runs)


def get_prom() -> dict:
    return cached("prom", build_prom)


def get_live() -> list[dict]:
    return cached("live", list_live_runs)


def get_sprints() -> list[dict]:
    """Sprint cards enriched with aggregates from runs + live pods."""
    def _build() -> list[dict]:
        sprints = list_sprints()
        runs = get_runs()
        live = get_live()
        for s in sprints:
            name = s["name"]
            srows = [r for r in runs if r.get("sprint") == name]
            slive = [r for r in live if r.get("sprint") == name]
            # An issue counts as "done" if ANY of its runs SUCCEEDED. Counting
            # raw SUCCEEDED runs inflated done past the sprint's issue count
            # (sprint-2 read 121%) because a single issue is worked across
            # multiple runs (worker → reviewer → re-fix → re-review) and any
            # of those can be SUCCEEDED. Using "any run per issue succeeded"
            # naturally caps done at total. Failed/blocked use the same shape
            # but exclude issues that ever succeeded, so an issue that
            # NEEDS_INFO'd once then merged reads as done, not blocked.
            done_iss:    set[str] = set()
            failed_iss:  set[str] = set()
            blocked_iss: set[str] = set()
            for r in srows:
                t = (r.get("issue_id") or "").lower()
                if not t:
                    continue
                st = r.get("status")
                if st == "SUCCEEDED":
                    done_iss.add(t)
                elif st == "FAILED":
                    failed_iss.add(t)
                elif st == "NEEDS_HUMAN":
                    blocked_iss.add(t)
            failed_iss  -= done_iss
            blocked_iss -= done_iss
            done, failed, blocked = len(done_iss), len(failed_iss), len(blocked_iss)
            cost = sum(float(r.get("cost_usd") or 0) for r in srows)
            tokens = sum(int(r.get("input_tokens") or 0) +
                         int(r.get("output_tokens") or 0) for r in srows)
            wall = sum(float(r.get("wall_s") or 0) for r in srows)
            # Wave count: distinct start_ts buckets ≥5 min apart.
            starts = sorted(int(r.get("start_ts") or 0) for r in srows
                            if r.get("start_ts"))
            waves, prev = (1 if starts else 0), None
            for t in starts:
                if prev is not None and (t - prev) >= 300:
                    waves += 1
                prev = t
            # State chip: closed > in-flight > planned.
            if s["closed"]:
                state = "closed"
            elif slive or srows:
                state = "in-flight"
            else:
                state = "planned"
            total = len(s["issues"])
            # done is now issue-deduped (max len = total), so we cap at 100
            # only as defense-in-depth in case an issue gets re-promised mid-sprint.
            pct = min(100, int(round(100 * done / total))) if total else 0
            # ETA = (remaining issues) × avg wall per done issue. We only
            # estimate when we have at least one completed issue to anchor
            # the average — otherwise the number is meaningless.
            remaining = max(0, total - done)
            if state == "closed" or done == 0 or remaining == 0:
                eta_s = 0
            else:
                eta_s = int(remaining * (wall / done))
            # Per-ticket board state: each planned issue → status + planned wave.
            # in-progress = a live pod is on it right now; done/failed/blocked use
            # the issue-deduped sets above; everything else is pending.
            wave_of = s.get("wave_of") or {}
            live_iss = {(r.get("issue_id") or "").lower()
                        for r in slive if r.get("issue_id")}
            tickets = []
            for iss in s["issues"]:
                k = iss.lower()
                if   k in done_iss:    tstat = "done"
                elif k in live_iss:    tstat = "in-progress"
                elif k in blocked_iss: tstat = "blocked"
                elif k in failed_iss:  tstat = "failed"
                else:                  tstat = "pending"
                num = iss.split("-")[-1]
                tickets.append({"issue": iss, "num": num,
                                "wave": wave_of.get(iss, 0), "status": tstat})
            tickets.sort(key=lambda t: (t["wave"],
                                        int(t["num"]) if t["num"].isdigit() else 0))
            planned_waves = max((t["wave"] for t in tickets), default=0)
            # Current wave = lowest planned wave that still has an unfinished
            # ticket; once all are done, it's the last wave.
            unfinished = [t["wave"] for t in tickets if t["status"] != "done"]
            current_wave = (min(unfinished) if unfinished
                            else (planned_waves if tickets else 0))
            s.update({
                "tickets":       tickets,
                "current_wave":  current_wave,
                "planned_waves": planned_waves,
                "state":         state,
                "runs":          len(srows),
                "done":          done,
                "failed":        failed,
                "blocked":       blocked,
                "total_issues":  total,
                "percent":       pct,
                "eta_s":         eta_s,
                "cost_usd":      round(cost, 4),
                "tokens":        tokens,
                "wall_s":        int(wall),
                "waves":         waves,
                "pods_live":     len(slive),
            })
        return sprints
    return cached("sprints", _build)
