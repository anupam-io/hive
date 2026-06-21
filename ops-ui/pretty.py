# Pretty-printer for claude --output-format stream-json log files.
# Ported from ~/chital/core/services/format-stream.ts.
#
# Each run.log is a mix of:
#   - shell narration   ([agent] …, === coding-agent: …, METRICS: …)
#   - claude events     (one JSON object per line)
#
# Two outputs share one parser:
#   pretty_log(text)      → plain text (CLI / "Raw" toggle fallback)
#   pretty_log_html(text) → HTML with per-kind classes so the UI can render
#                           agent speech, tool calls, results, narration as
#                           visually distinct rows.

from __future__ import annotations

import html
import json
import re
from typing import Iterator, Tuple

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_WS_RE   = re.compile(r"\s+")

_TOOL_ICON = {
    "WebSearch": "🔍", "WebFetch": "🌐", "Bash": "⚡",
    "Read":      "📖", "Write":    "✏️", "Edit":  "✂️",
    "Glob":      "🔎", "Grep":     "🔎",
    "TodoWrite": "📋", "Task":     "🤖",
}


def _short(s: str, n: int = 120) -> str:
    s = _WS_RE.sub(" ", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def _shorten_input(name: str, inp: object) -> str:
    """One-line summary of a tool_use's input, keyed on the tool's shape."""
    if not isinstance(inp, dict):
        return ""
    g = lambda k: str(inp.get(k, "") or "")
    if name == "WebSearch": return f'"{_short(g("query"), 100)}"'
    if name == "WebFetch":  return g("url")
    if name == "Bash":      return _short(g("command"), 160)
    if name in ("Read", "Write", "Edit"):
        return g("file_path") or g("path")
    if name == "Glob":      return g("pattern")
    if name == "Grep":
        return f'"{_short(g("pattern"), 80)}" in {g("path") or "."}'
    return _short(json.dumps(inp, default=str), 160)


def _summarize_result(content: object) -> str:
    if content is None:
        return "(empty)"
    if isinstance(content, str):
        return _short(content, 200)
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict) and "text" in c:
                parts.append(_short(str(c["text"]), 160))
            else:
                parts.append(_short(json.dumps(c, default=str), 160))
        return " | ".join(parts)
    return _short(json.dumps(content, default=str), 200)


# ---------------------------------------------------------------------------
# Parsing — yields tagged events the renderers below consume.
#
# Kinds:
#   banner      "=== … ==="                              shell, run-level header
#   narration   "[agent] …"                              shell, agent driver chatter
#   metrics     "METRICS: {…}"                           shell, machine-readable totals
#   status      "STATUS: …"                              shell, final status
#   plain       anything else not parsed                 shell, fallback
#   session     init event                               claude
#   think       assistant thinking block                 claude — internal monologue
#   text        assistant text block                     claude — what it SAYS
#   tool        tool_use block                           claude — COMMAND it runs
#   result      tool_result block                        claude — output of a command
#   summary     final result event                       claude — run total
# ---------------------------------------------------------------------------

def _emit_event(ev: dict) -> Iterator[Tuple[str, dict]]:
    typ, sub = ev.get("type"), ev.get("subtype")
    if typ == "stream_event": return
    if typ == "system" and sub == "status": return
    iso = ev.get("timestamp") or ""
    t = iso[11:19] if len(iso) >= 19 else ""

    if typ == "system" and sub == "init":
        yield ("session", {
            "t":       t,
            "session": str(ev.get("session_id", "?")),
            "model":   str(ev.get("model", "?")),
            "cwd":     str(ev.get("cwd", "?")),
        })
        return

    if typ == "assistant":
        for block in (ev.get("message") or {}).get("content") or []:
            bt = block.get("type")
            if bt == "thinking":
                th = (block.get("thinking") or "").strip()
                if th:
                    yield ("think", {"t": t, "body": _short(th, 400)})
            elif bt == "tool_use":
                name = block.get("name") or ""
                icon = _TOOL_ICON.get(name, "🔧")
                args = _shorten_input(name, block.get("input") or {})
                yield ("tool", {
                    "t": t, "name": name, "icon": icon, "args": args,
                })
            elif bt == "text":
                txt = (block.get("text") or "").strip()
                if txt:
                    for line in txt.split("\n"):
                        if line.strip():
                            yield ("text", {"t": t, "body": line})
        return

    if typ == "user":
        tur = ev.get("tool_use_result")
        if not isinstance(tur, dict):
            tur = {}
        dur_ms = tur.get("durationMs")
        if dur_ms is None:
            dur_s = tur.get("durationSeconds")
            dur_str = f"{dur_s:.1f}s" if dur_s is not None else ""
        else:
            dur_str = (f"{dur_ms/1000:.1f}s" if dur_ms >= 1000
                       else f"{round(dur_ms)}ms")
        for block in (ev.get("message") or {}).get("content") or []:
            if block.get("type") == "tool_result":
                yield ("result", {
                    "t":       t,
                    "err":     block.get("is_error") is True,
                    "summary": _summarize_result(block.get("content")),
                    "dur":     dur_str,
                })
        return

    if typ == "result":
        cost = ev.get("total_cost_usd") or 0
        turns = ev.get("num_turns") or 0
        dur_ms = ev.get("duration_ms") or 0
        usage = ev.get("usage") or {}
        yield ("summary", {
            "sub":    sub or "",
            "cost":   cost,
            "turns":  turns,
            "dur_s":  dur_ms / 1000.0,
            "inp":    usage.get("input_tokens") or 0,
            "outp":   usage.get("output_tokens") or 0,
            "result": ev.get("result") or "",
        })


def _classify_shell(line: str) -> Tuple[str, dict]:
    if line.startswith("=== ") and line.endswith(" ==="):
        return ("banner", {"line": line})
    if line.startswith("[agent]"):
        return ("narration", {"line": line})
    if line.startswith("METRICS:"):
        return ("metrics", {"line": line})
    if line.startswith("STATUS:"):
        return ("status", {"line": line})
    return ("plain", {"line": line})


def _iter_events(text: str) -> Iterator[Tuple[str, dict]]:
    for raw in text.splitlines():
        raw = raw.rstrip()
        if not raw:
            continue
        if raw.startswith("{") and raw.endswith("}"):
            try:
                yield from _emit_event(json.loads(raw))
                continue
            except json.JSONDecodeError:
                pass
        yield _classify_shell(_ANSI_RE.sub("", raw))


# ---------------------------------------------------------------------------
# Plain-text renderer (compat with the old pretty_log signature).
# ---------------------------------------------------------------------------

def _ts(t: str) -> str:
    return f"[{t or '        '}]"


def _render_text(kind: str, f: dict) -> str:
    if kind == "session":
        return (f"{_ts(f['t'])} session {f['session']} · "
                f"model {f['model']} · cwd {f['cwd']}")
    if kind == "think":   return f"{_ts(f['t'])} 🧠 {f['body']}"
    if kind == "text":    return f"{_ts(f['t'])} 💬 {f['body']}"
    if kind == "tool":
        return f"{_ts(f['t'])} {f['icon']} {f['name']}  {f['args']}"
    if kind == "result":
        tag = "↳ ERR" if f["err"] else "↳"
        dur = f" ({f['dur']})" if f["dur"] else ""
        return f"{_ts(f['t'])}    {tag} {f['summary']}{dur}"
    if kind == "summary":
        head = (f"\n== RESULT == {f['sub']} cost=${f['cost']:.4f} "
                f"turns={f['turns']} duration={f['dur_s']:.1f}s "
                f"tokens={f['inp']}/{f['outp']}")
        return head + (f"\n\n{f['result']}\n" if f["result"] else "")
    return f["line"]


def pretty_log(text: str) -> str:
    """Render a run.log into a plain-text pretty form. CLI-friendly."""
    out: list[str] = []
    for kind, fields in _iter_events(text):
        line = _render_text(kind, fields)
        if line:
            out.append(line)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# HTML renderer — the UI loads this into <div class="log"> so each row can
# be styled by category. CSS for these classes lives in index_html.py.
# ---------------------------------------------------------------------------

def _h(s: str) -> str:
    return html.escape(s, quote=False)


def _ts_html(t: str) -> str:
    # Fixed-width timestamp; missing time becomes spaces so columns line up.
    return f'<span class="ll-ts">[{_h(t) if t else "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"}]</span>'


def _render_html(kind: str, f: dict) -> str:
    ts = _ts_html(f.get("t", "")) if "t" in f else ""

    if kind == "session":
        return (
            f'<div class="ll ll-session">{ts}'
            f'<span class="ll-icon">·</span>'
            f'<span class="ll-body">'
            f'session <code>{_h(f["session"])}</code> · '
            f'model <code>{_h(f["model"])}</code> · '
            f'cwd <code>{_h(f["cwd"])}</code>'
            f'</span></div>'
        )

    if kind == "think":
        return (
            f'<div class="ll ll-think">{ts}'
            f'<span class="ll-icon">🧠</span>'
            f'<span class="ll-body">{_h(f["body"])}</span></div>'
        )

    if kind == "text":
        # AGENT SPEECH — the headline content. Render in sans-serif so it
        # reads like prose, not log output.
        return (
            f'<div class="ll ll-say">{ts}'
            f'<span class="ll-icon">💬</span>'
            f'<span class="ll-body">{_h(f["body"])}</span></div>'
        )

    if kind == "tool":
        # COMMAND the agent issued. Terminal aesthetic so it's never
        # mistaken for the agent's speech.
        return (
            f'<div class="ll ll-tool">{ts}'
            f'<span class="ll-icon">{_h(f["icon"])}</span>'
            f'<span class="ll-tool-name">{_h(f["name"])}</span>'
            f'<code class="ll-cmd">{_h(f["args"])}</code></div>'
        )

    if kind == "result":
        cls = "ll ll-result" + (" ll-err" if f["err"] else "")
        arrow = "↳ ERR" if f["err"] else "↳"
        dur = (f'<span class="ll-dur">({_h(f["dur"])})</span>'
               if f["dur"] else "")
        return (
            f'<div class="{cls}">{ts}'
            f'<span class="ll-arrow">{arrow}</span>'
            f'<span class="ll-summary">{_h(f["summary"])}</span>'
            f'{dur}</div>'
        )

    if kind == "summary":
        head = (f"== RESULT == {f['sub']} cost=${f['cost']:.4f} "
                f"turns={f['turns']} duration={f['dur_s']:.1f}s "
                f"tokens={f['inp']}/{f['outp']}")
        body = (f'<div class="ll-summary-body">{_h(f["result"])}</div>'
                if f["result"] else "")
        return (
            f'<div class="ll ll-summary-banner">'
            f'<div class="ll-summary-head">{_h(head)}</div>'
            f'{body}</div>'
        )

    # Shell-narration kinds — each gets its own color/affordance.
    line = f["line"]
    if kind == "banner":
        return f'<div class="ll ll-banner">{_h(line)}</div>'
    if kind == "narration":
        return f'<div class="ll ll-narration">{_h(line)}</div>'
    if kind == "metrics":
        return f'<div class="ll ll-metrics">{_h(line)}</div>'
    if kind == "status":
        return f'<div class="ll ll-status">{_h(line)}</div>'
    return f'<div class="ll ll-plain">{_h(line)}</div>'


def pretty_log_html(text: str) -> str:
    """Render a run.log into HTML with per-line classes for styled display."""
    rows = [_render_html(kind, fields) for kind, fields in _iter_events(text)]
    return '<div class="log">' + "\n".join(rows) + "</div>"
