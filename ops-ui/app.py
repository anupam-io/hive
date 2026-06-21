#!/usr/bin/env python3
# Agent-analytics UI entry point.
#
#   python3 ops-ui/app.py            (or: hivectl ui)
#   open    http://localhost:8001
#
# This module is intentionally tiny — it only wires the HTTP server to the
# data/pretty modules and substitutes the SSR payload into the index. All
# heavy lifting lives in:
#   cache.py       - TTL cache + locks
#   data.py        - runs / live / prom loaders
#   pretty.py      - claude stream-json → human log
#   index_html.py  - the single-page HTML/CSS/JS string

from __future__ import annotations

import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

# This script's dir is on sys.path automatically when invoked via
# `python3 ops-ui/app.py`, so flat sibling imports work despite the
# dash in the folder name (`ops-ui` isn't a valid Python package name).
from cache import CACHE_TTL
from data import (
    AGENTS_DIR, PROM_URL,
    get_runs, get_live, get_prom, get_sprints,
    read_log_tail, kubectl_logs,
)
from pretty import pretty_log, pretty_log_html
from index_html import INDEX_HTML

PORT = int(os.environ.get("AGENT_UI_PORT", "8001"))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:  # quiet default access log
        return

    def do_GET(self) -> None:  # noqa: N802
        u = urllib.parse.urlparse(self.path)
        if u.path == "/" or u.path == "/index.html":
            # SSR: bake the first frame of data into the page so the user
            # sees a fully-populated dashboard on the first paint — no
            # fetch round-trip before the UI is usable.
            initial = json.dumps({
                "runs":      get_runs(),
                "prom":      get_prom(),
                "live":      get_live(),
                "sprints":   get_sprints(),
                "ttl":       CACHE_TTL,
                # The project's GitHub repo URL — used to build issue+PR
                # chip links in the drawer.
                "repo_url":  os.environ.get("HIVE_REPO", ""),
                "app":       os.environ.get("HIVE_APP", ""),
            }, separators=(",", ":"))
            html = INDEX_HTML.replace("/*__INITIAL__*/null", initial)
            return self._send(200, html.encode(), "text/html; charset=utf-8")
        if u.path == "/api/runs":
            return self._send(200, json.dumps(get_runs()).encode(),
                              "application/json")
        if u.path == "/api/live":
            return self._send(200, json.dumps(get_live()).encode(),
                              "application/json")
        if u.path == "/api/prom":
            return self._send(200, json.dumps(get_prom()).encode(),
                              "application/json")
        if u.path == "/api/sprints":
            return self._send(200, json.dumps(get_sprints()).encode(),
                              "application/json")
        if u.path == "/api/log":
            qs = urllib.parse.parse_qs(u.query)
            run = (qs.get("run", [""])[0]).strip()
            if not run or "/" in run or ".." in run:
                return self._send(400, b"bad run id", "text/plain")
            # Live row → kubectl logs the pod. Completed run → read the
            # on-disk run.log under .agents/<run>/. Pretty trims; give it
            # more raw input to work with.
            if run.startswith("live:"):
                pod = run[len("live:"):]
                text = kubectl_logs(pod, tail=1500)
            else:
                log = AGENTS_DIR / run / "run.log"
                text = read_log_tail(str(log), n=1500)
            pretty = (qs.get("pretty", ["1"])[0]).strip() != "0"
            if pretty:
                body = pretty_log_html(text)
                ctype = "text/html; charset=utf-8"
            else:
                body = text
                ctype = "text/plain; charset=utf-8"
            return self._send(200, body.encode(), ctype)
        self._send(404, b"not found", "text/plain")


def main() -> int:
    httpd = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"agent-ui: http://127.0.0.1:{PORT}")
    print(f"agent-ui: prometheus = {PROM_URL}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nagent-ui: bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
