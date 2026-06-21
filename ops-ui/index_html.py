# Single-page UI for the agent-analytics dashboard.
#
# Kept as one big string on purpose — zero build step, zero deps, easy to
# diff. The server replaces the literal `/*__INITIAL__*/null` token with
# JSON-encoded {runs, prom, live, ttl} so the first paint is SSR-instant.

INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>hive — Swarm Analytics</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  :root {
    --fg:#0f172a; --fg-soft:#475569; --fg-mute:#94a3b8;
    --bg:#ffffff; --bg-alt:#f8fafc; --border:#e5e7eb; --border-strong:#cbd5e1;
    --accent:#0ea5e9; --accent-soft:#e0f2fe;
    --ok:#15803d; --warn:#b45309; --bad:#b91c1c; --info:#0369a1;
  }
  *,*::before,*::after { box-sizing:border-box; }
  html,body { margin:0; padding:0; background:var(--bg); color:var(--fg);
    font:14px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,
    "Helvetica Neue",Arial,sans-serif;
    font-feature-settings:"tnum","ss01"; -webkit-font-smoothing:antialiased; }
  header { border-bottom:1px solid var(--border); padding:0; }
  header .hdr-inner { max-width:1400px; margin:0 auto; padding:14px 24px;
    display:flex; align-items:center; gap:24px; }
  header h1 { font-size:13px; font-weight:600; margin:0; letter-spacing:.02em;
    display:inline-flex; align-items:baseline; gap:8px; }
  header h1 .brand { font-size:32px; font-weight:700; letter-spacing:-.02em;
    color:var(--fg); line-height:1; }
  header h1 .tag { font-size:11px; font-weight:500; color:var(--fg-mute);
    text-transform:uppercase; letter-spacing:.08em; }
  header .meta { color:var(--fg-mute); font-size:12px; }
  header .spacer { flex:1; }
  header button { font:inherit; color:var(--fg-soft); background:transparent;
    border:1px solid var(--border); border-radius:4px; padding:4px 10px; cursor:pointer;
    display:inline-flex; align-items:center; gap:8px; }
  header button:hover { color:var(--fg); border-color:var(--border-strong); }
  header button .dot { width:6px; height:6px; border-radius:50%;
    background:var(--accent); display:inline-block; }
  header button.refreshing .dot { background:var(--warn);
    animation:pulse 1s ease-in-out infinite; }
  header button .countdown { font-variant-numeric:tabular-nums; color:var(--fg-mute);
    font-size:11px; min-width:24px; text-align:right; }
  @keyframes pulse { 50% { opacity:.35; } }
  main { padding:20px 24px 28px; max-width:1400px; margin:0 auto; }
  section { margin-bottom:28px; }
  h2 { font-size:11px; text-transform:uppercase; letter-spacing:.08em;
    color:var(--fg-mute); font-weight:600; margin:0 0 10px; }
  .kpis { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; }
  .kpi { border:1px solid var(--border); border-radius:6px; padding:12px 14px; background:var(--bg); }
  .kpi .label { font-size:11px; color:var(--fg-mute); text-transform:uppercase;
    letter-spacing:.06em; }
  .kpi .value { font-size:20px; font-weight:600; margin-top:4px;
    font-variant-numeric:tabular-nums; }
  .kpi .sub { font-size:11px; color:var(--fg-soft); margin-top:4px;
    font-variant-numeric:tabular-nums; display:flex; flex-wrap:wrap;
    align-items:baseline; gap:0 8px; }
  .kpi .sub .lbl { color:var(--fg-mute); font-size:10px; font-weight:600;
    text-transform:uppercase; letter-spacing:.08em; margin-right:4px; }
  .kpi .sub .num { color:var(--fg); font-weight:500; }
  .kpi .sub .sep { color:var(--border-strong); }
  .kpi .sub .unit { color:var(--fg-mute); margin-left:2px; }
  .filters { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px; }
  .filters input, .filters select { font:inherit; color:var(--fg);
    background:var(--bg); border:1px solid var(--border); border-radius:4px;
    padding:5px 8px; min-width:140px; }
  .filters input:focus, .filters select:focus { outline:none;
    border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
  table { width:100%; border-collapse:collapse; background:var(--bg);
    border:1px solid var(--border); border-radius:6px; overflow:hidden;
    font-variant-numeric:tabular-nums; }
  thead th { text-align:left; font-weight:600; font-size:11px;
    text-transform:uppercase; letter-spacing:.06em; color:var(--fg-mute);
    background:var(--bg-alt); padding:8px 12px; border-bottom:1px solid var(--border);
    cursor:pointer; user-select:none; white-space:nowrap; }
  thead th:hover { color:var(--fg); }
  thead th.num { text-align:right; }
  tbody td { padding:8px 12px; border-bottom:1px solid var(--border);
    white-space:nowrap; }
  tbody td.num { text-align:right; }
  tbody tr { cursor:pointer; }
  tbody tr:hover { background:var(--bg-alt); }
  tbody tr:last-child td { border-bottom:none; }
  .badge { display:inline-block; font-size:11px; font-weight:500; padding:1px 7px;
    border-radius:10px; letter-spacing:.02em; }
  .badge.ok      { background:#dcfce7; color:var(--ok); }
  .badge.bad     { background:#fee2e2; color:var(--bad); }
  .badge.warn    { background:#fef3c7; color:var(--warn); }
  .badge.info    { background:#dbeafe; color:var(--info); }
  .badge.neutral { background:#f1f5f9; color:var(--fg-soft); }
  .mono { font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace; font-size:12px; }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }
  /* drawer */
  .drawer { position:fixed; top:0; right:0; bottom:0; width:min(820px,72vw);
    background:var(--bg); border-left:1px solid var(--border-strong);
    box-shadow:-12px 0 32px -16px rgba(15,23,42,.18); transform:translateX(100%);
    transition:transform .18s ease; display:flex; flex-direction:column; z-index:20; }
  .drawer.open { transform:translateX(0); }
  /* Click-outside scrim — invisible but click-eating, behind the drawer. */
  .drawer-scrim { position:fixed; inset:0; z-index:10; display:none;
    background:transparent; }
  .drawer-scrim.open { display:block; }
  .drawer header { border-bottom:1px solid var(--border); padding:14px 18px;
    display:flex; align-items:center; gap:12px; }
  .drawer header h3 { margin:0; font-size:13px; font-weight:600; }
  .drawer header .close { margin-left:auto; }
  .drawer .body { padding:16px 18px; overflow:auto; }
  .drawer .grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr));
    gap:8px 18px; margin-bottom:18px; }
  .drawer .grid .k { font-size:11px; color:var(--fg-mute); text-transform:uppercase;
    letter-spacing:.06em; }
  .drawer .grid .v { font-size:13px; color:var(--fg);
    font-variant-numeric:tabular-nums; word-break:break-all; }
  .drawer pre { background:#0b1220; color:#e2e8f0; padding:12px 14px;
    border-radius:6px; font:11.5px/1.55 ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    white-space:pre-wrap; word-break:break-word; max-height:60vh; overflow:auto;
    margin:0; }
  /* ── Drawer log: structured terminal layout ─────────────────────────────
     Single column, no bubbles, no L/R alignment. Each event row reads as
     one line in a terminal session. Categories are distinguished by a
     left-edge marker glyph + color + indent (results indent under their
     tool call so the pair reads as one unit).

     Lanes:
       SYSTEM     — session/banner/metrics/status/summary  →  ═══ dividers
       INPUT      — [agent] narration                       →  amber ▸
       AGENT THINK— italic dim purple                       →  🧠
       AGENT TEXT — sans-serif bright on faint shade        →  💬 (the headline)
       TOOL CALL  — emerald                                 →  ⚡
       TOOL RES.  — slate, indented under the tool          →  ↳ (red ↳ ERR on error)
  */
  .drawer .log { background:#0b1220; border-radius:6px; padding:8px 0;
    max-height:60vh; overflow:auto;
    font:12px/1.55 ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    color:#cbd5e1; }
  .drawer .log .ll { display:flex; gap:10px; padding:3px 16px;
    align-items:flex-start; white-space:pre-wrap; word-break:break-word; }
  .drawer .log .ll-ts { color:#3f4b5f; flex:none; font-variant-numeric:tabular-nums;
    user-select:none; font-size:10.5px; padding-top:1px; min-width:60px; }
  .drawer .log .ll-icon { flex:none; width:18px; text-align:center; }
  .drawer .log .ll-body { flex:1; min-width:0; }

  /* Phase spacing — give breathing room before a new prompt or banner. */
  .drawer .log .ll-narration,
  .drawer .log .ll-banner,
  .drawer .log .ll-summary-banner,
  .drawer .log .ll-session { margin-top:8px; }

  /* ── AGENT TEXT ── the headline. Sans-serif, brighter, faint shade so it
     visually anchors the conversation. */
  .drawer .log .ll-say { background:#0f1729; padding-top:6px; padding-bottom:6px;
    border-left:2px solid #38bdf8; }
  .drawer .log .ll-say .ll-body { color:#f1f5f9;
    font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    font-size:13.5px; line-height:1.5; }

  /* ── AGENT THINKING ── internal monologue. Italic, dim purple. */
  .drawer .log .ll-think .ll-icon { color:#a78bfa; }
  .drawer .log .ll-think .ll-body { color:#a78bfa; font-style:italic; opacity:.75; }

  /* ── TOOL CALL ── command issued by the agent. Emerald marker, mono body. */
  .drawer .log .ll-tool .ll-icon { color:#34d399; }
  .drawer .log .ll-tool .ll-tool-name { color:#34d399; font-weight:600;
    flex:none; min-width:54px; }
  .drawer .log .ll-tool .ll-cmd { color:#7dd3fc; flex:1; min-width:0;
    font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    background:transparent; padding:0; overflow-wrap:anywhere; }

  /* ── TOOL RESULT ── pairs with the tool call immediately above. Indent
     the marker so it visually sits UNDER the tool's body. Hide its own
     timestamp — the tool call's timestamp is the one that matters. */
  .drawer .log .ll-result { padding-top:0; padding-bottom:4px; }
  /* visibility:hidden (not display:none) so the ts gutter stays reserved,
     keeping the arrow column-aligned under the tool's ⚡ icon above. */
  .drawer .log .ll-result .ll-ts { visibility:hidden; }
  .drawer .log .ll-result .ll-arrow { color:#64748b; flex:none; width:18px;
    text-align:center; }
  .drawer .log .ll-result .ll-summary { color:#94a3b8; flex:1; min-width:0; }
  .drawer .log .ll-result .ll-dur { color:#475569; flex:none; font-size:10.5px;
    padding-left:8px; }
  .drawer .log .ll-result.ll-err .ll-arrow,
  .drawer .log .ll-result.ll-err .ll-summary { color:#fca5a5; }

  /* ── INPUT lane: driver narration ([agent] …) ── what flows INTO the agent.
     Amber, with a thin amber left rule. */
  .drawer .log .ll-narration { color:#fbbf24; border-left:2px solid #f59e0b66;
    padding-top:4px; padding-bottom:4px; }
  .drawer .log .ll-narration::before { content:"▸"; color:#fbbf24; font-weight:700;
    flex:none; width:14px; text-align:center; }

  /* ── SYSTEM lane ── full-width dividers. Quiet visual punctuation. */
  .drawer .log .ll-session,
  .drawer .log .ll-banner,
  .drawer .log .ll-status,
  .drawer .log .ll-metrics,
  .drawer .log .ll-plain { padding:4px 16px; }
  .drawer .log .ll-session { color:#94a3b8;
    border-top:1px dashed #1e293b; border-bottom:1px dashed #1e293b;
    background:#0d1626; }
  .drawer .log .ll-session code { background:transparent; color:#7dd3fc; padding:0; }
  .drawer .log .ll-banner { color:#fcd34d; font-weight:600; letter-spacing:.02em;
    border-top:1px solid #2a1f12; border-bottom:1px solid #2a1f12;
    background:#1a130a; padding:6px 16px; }
  .drawer .log .ll-status { color:#86efac; font-weight:600;
    border-left:2px solid #22c55e; background:#06210f; padding:5px 16px; }
  .drawer .log .ll-metrics { color:#94a3b8; opacity:.7; font-size:11px; }

  /* ── == RESULT == final summary banner ── the model's last word.
     Sky background, prominent so end-of-run is unmistakable. */
  .drawer .log .ll-summary-banner { background:#062639; color:#bae6fd;
    padding:10px 16px; border-left:3px solid #0ea5e9; display:block; }
  .drawer .log .ll-summary-banner .ll-summary-head { font-weight:600;
    color:#7dd3fc; margin-bottom:6px; font-size:11.5px;
    text-transform:uppercase; letter-spacing:.06em; }
  .drawer .log .ll-summary-banner .ll-summary-body { color:#e2e8f0;
    font-family:ui-sans-serif,system-ui,-apple-system,sans-serif; font-size:13px;
    line-height:1.55; white-space:pre-wrap; }
  /* Top-of-drawer link pills (GitHub issue, repo, PR). */
  .drawer .links { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:14px; }
  .drawer .links a.pill { display:inline-flex; align-items:center; gap:6px;
    padding:5px 10px; border-radius:14px; border:1px solid var(--border);
    background:var(--bg-alt); color:var(--fg); text-decoration:none; font-size:12px;
    font-weight:500; }
  .drawer .links a.pill:hover { border-color:var(--border-strong);
    background:var(--bg); }
  .drawer .links a.pill .dot { width:6px; height:6px; border-radius:50%; }
  .drawer .links a.pill.gh .dot     { background:#22c55e; }
  .drawer .links a.pill .label { color:var(--fg-mute); font-size:10px;
    text-transform:uppercase; letter-spacing:.08em; font-weight:600; }
  .drawer .links a.pill .val { font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace; }
  .empty { padding:48px 16px; text-align:center; color:var(--fg-mute);
    border:1px dashed var(--border); border-radius:6px; }
  .prom { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; }
  .prom .kpi .value { font-size:18px; }
  /* Header live counter — workers / reviewers running on the cluster RIGHT
     NOW. Lives between page meta and the Refresh button. */
  .livebar { display:inline-flex; align-items:center; gap:14px; padding:4px 10px;
    border:1px solid var(--border); border-radius:4px; font-size:11px; }
  .livebar .livebar-group { display:inline-flex; align-items:center; gap:6px; }
  .livebar .dot-live { width:6px; height:6px; border-radius:50%; background:var(--ok);
    box-shadow:0 0 0 3px #dcfce7; animation:pulse 1.4s ease-in-out infinite; }
  .livebar .lbl { color:var(--fg-mute); text-transform:uppercase; letter-spacing:.06em;
    font-weight:600; font-size:10px; }
  .livebar .num { color:var(--fg); font-weight:600; font-variant-numeric:tabular-nums; }
  /* Active-sprint badge in the header — biggest open sprint. */
  .sprint-badge { display:inline-flex; align-items:center; gap:6px; padding:4px 10px;
    border:1px solid var(--border); border-radius:4px; font-size:11px;
    color:var(--fg-soft); }
  .sprint-badge .lbl { color:var(--fg-mute); text-transform:uppercase;
    letter-spacing:.06em; font-weight:600; font-size:10px; }
  .sprint-badge .name { color:var(--fg); font-weight:600; }
  .sprint-badge.in-flight { border-color:var(--accent); color:var(--info); }
  /* Status as a leading icon — no background tint, just the icon column. */
  td.st { width:22px; padding:6px 0 6px 12px; text-align:center; }
  td.st .ico { display:inline-block; width:14px; height:14px; line-height:14px;
    font-size:13px; text-align:center; vertical-align:middle; font-weight:700; }
  td.st .ico.ok   { color:var(--ok); }
  td.st .ico.bad  { color:var(--bad); }
  td.st .ico.warn { color:var(--warn); }
  td.st .ico.neutral { color:var(--fg-mute); }
  td.st .spinner { display:inline-block; width:12px; height:12px; border-radius:50%;
    border:2px solid #fef3c7; border-top-color:var(--warn);
    animation:spin .9s linear infinite; vertical-align:middle; }
  @keyframes spin { to { transform:rotate(360deg); } }
  /* Sprint chip in the runs table. */
  .sprint-chip { display:inline-block; font-size:11px; font-weight:500;
    padding:1px 7px; border-radius:10px; background:#ede9fe; color:#5b21b6;
    letter-spacing:.02em; }
  .sprint-chip.none { background:transparent; color:var(--fg-mute);
    font-style:italic; }
  /* Sprints section — one minimalist card per sprint. No expand toggle,
     no nested grids; just header line, stats line, and a progress bar
     with ETA at the bottom. Mirrors the .kpi card aesthetic. The same .sc-*
     element styles now dress the unified .sprint-board (it carries both the
     .sprint-card and .sprint-board classes). */
  .sprint-card { border:1px solid var(--border); border-radius:6px;
    background:var(--bg); padding:14px 16px 12px;
    display:flex; flex-direction:column; gap:10px; }
  .sprint-card.in-flight { border-color:var(--accent); }
  .sprint-card .sc-head { display:flex; align-items:center; gap:10px;
    flex-wrap:wrap; }
  .sprint-card .sc-name { font-weight:600; font-size:13px; color:var(--fg);
    font-variant-numeric:tabular-nums; }
  .sprint-card .sc-chip { font-size:10px; font-weight:600;
    text-transform:uppercase; letter-spacing:.06em; padding:2px 7px;
    border-radius:10px; }
  .sprint-card .sc-chip.closed    { background:#dcfce7; color:var(--ok); }
  .sprint-card .sc-chip.in-flight { background:#dbeafe; color:var(--info); }
  .sprint-card .sc-chip.planned   { background:#f1f5f9; color:var(--fg-soft); }
  .sprint-card .sc-thesis { color:var(--fg-soft); font-size:12px;
    flex:1; min-width:160px; }
  .sprint-card .sc-links { display:flex; gap:10px; font-size:11px; }
  .sprint-card .sc-links a { color:var(--fg-mute); }
  .sprint-card .sc-links a:hover { color:var(--accent); }
  .sprint-card .sc-stats { display:flex; gap:14px; flex-wrap:wrap;
    font-size:11px; color:var(--fg-soft);
    font-variant-numeric:tabular-nums; }
  .sprint-card .sc-stats .stat .lbl { color:var(--fg-mute);
    text-transform:uppercase; letter-spacing:.06em; font-size:9px; font-weight:600;
    margin-right:4px; }
  .sprint-card .sc-stats .stat .num { color:var(--fg); font-weight:600; }
  .sprint-card .sc-stats .sep { color:var(--border-strong); }
  .sprint-card .sc-progress { display:flex; align-items:center; gap:10px;
    font-size:11px; color:var(--fg-soft);
    font-variant-numeric:tabular-nums; }
  .sprint-card .sc-bar { flex:1; height:6px; background:var(--bg-alt);
    border-radius:3px; overflow:hidden; position:relative; }
  .sprint-card .sc-bar-fill { height:100%; background:var(--accent);
    transition:width .3s ease; }
  .sprint-card.closed    .sc-bar-fill { background:var(--ok); }
  .sprint-card.planned   .sc-bar-fill { background:var(--border-strong); }
  .sprint-card .sc-pct { font-weight:600; color:var(--fg); min-width:36px;
    text-align:right; }
  .sprint-card .sc-eta { color:var(--fg-mute); min-width:64px; text-align:right; }
  .sprint-card .sc-eta .lbl { color:var(--fg-mute); text-transform:uppercase;
    letter-spacing:.06em; font-size:9px; font-weight:600; margin-right:4px; }
  .sprint-card .sc-eta .num { color:var(--fg-soft); font-weight:600; }
  /* Live sprint board — tickets grouped by wave + a totals HUD */
  .sprint-board { margin-top:10px; border:1px solid var(--border); border-radius:6px;
    background:var(--bg); padding:12px 14px; }
  .sprint-board .sb-head { display:flex; align-items:center; gap:10px; margin-bottom:10px; }
  .sprint-board .sb-cur { margin-left:auto; font-size:10px; color:var(--info);
    background:var(--accent-soft); padding:1px 8px; border-radius:10px; font-weight:600; }
  /* Live-updating stat numbers (cost / runs / run time) bump on change. */
  .sprint-board .sc-stats .num.bump { animation:hud-bump .5s ease; }
  .sb-wave { display:flex; align-items:flex-start; gap:10px; padding:6px 0;
    border-top:1px dashed var(--border); }
  .sb-wave:first-of-type { border-top:none; }
  .sb-wave.current { background:linear-gradient(90deg,var(--accent-soft),transparent);
    border-radius:4px; padding-left:6px; }
  .sb-wave .wv { flex:none; width:70px; font-size:10px; font-weight:600;
    color:var(--fg-mute); text-transform:uppercase; padding-top:4px; }
  .sb-wave.current .wv { color:var(--info); }
  .sb-tix { display:flex; flex-wrap:wrap; gap:5px; }
  .tix { font-size:11px; font-weight:600; font-variant-numeric:tabular-nums;
    padding:2px 7px; border-radius:4px; border:1px solid var(--border-strong);
    color:var(--fg-soft); background:var(--bg-alt); animation:tix-in .25s ease both; }
  .tix.done        { color:var(--ok);   border-color:#86efac; background:#dcfce7; }
  .tix.failed      { color:var(--bad);  border-color:#fca5a5; background:#fee2e2; }
  .tix.blocked     { color:var(--warn); border-color:#fcd34d; background:#fef3c7; }
  .tix.in-progress { color:#fff; border-color:var(--accent); background:var(--accent);
    animation:tix-in .25s ease both, tix-pulse 1.5s ease-in-out infinite; }
  .tix.pending     { opacity:.65; }
  @keyframes tix-in   { from { opacity:0; transform:translateY(2px); } to { opacity:1; transform:none; } }
  @keyframes tix-pulse{ 0%,100% { box-shadow:0 0 0 0 var(--accent-soft); }
                        50%     { box-shadow:0 0 0 4px var(--accent-soft); } }
  @keyframes hud-bump { 0% { transform:scale(1); } 40% { transform:scale(1.18); } 100% { transform:scale(1); } }
  /* Drawer log toggle */
  .log-tools { display:flex; align-items:center; gap:6px; margin:14px 0 8px; }
  .log-tools h2 { margin:0; }
  .log-tools .spacer { flex:1; }
  .log-tools .seg { display:inline-flex; border:1px solid var(--border); border-radius:4px;
    overflow:hidden; }
  .log-tools .seg button { font:inherit; background:transparent; border:0; color:var(--fg-soft);
    padding:3px 10px; cursor:pointer; font-size:11px; }
  .log-tools .seg button.active { background:var(--accent-soft); color:var(--info); font-weight:600; }
  .log-tools .seg button + button { border-left:1px solid var(--border); }
  /* Pagination — bottom of runs table. */
  .pager { display:flex; align-items:center; gap:8px; padding:10px 2px 0;
    font-size:12px; color:var(--fg-soft); }
  .pager .spacer { flex:1; }
  .pager button { font:inherit; color:var(--fg-soft); background:var(--bg);
    border:1px solid var(--border); border-radius:4px; padding:4px 10px;
    cursor:pointer; }
  .pager button:hover:not(:disabled) { color:var(--fg); border-color:var(--border-strong); }
  .pager button:disabled { opacity:.4; cursor:not-allowed; }
  .pager .info { font-variant-numeric:tabular-nums; color:var(--fg-mute); }
  /* Footer — minimal, matches header. */
  footer.site { border-top:1px solid var(--border); background:var(--bg);
    color:var(--fg-soft); }
  footer.site .ftr-grid { max-width:1400px; margin:0 auto;
    padding:18px 24px 14px; display:grid;
    grid-template-columns:repeat(4, minmax(0,1fr)); gap:24px; }
  footer.site .ftr-col h4 { font-size:10px; font-weight:600;
    text-transform:uppercase; letter-spacing:.08em; color:var(--fg-mute);
    margin:0 0 8px; }
  footer.site .ftr-col ul { list-style:none; margin:0; padding:0;
    display:flex; flex-direction:column; gap:5px; }
  footer.site .ftr-col a { color:var(--fg-soft); text-decoration:none;
    font-size:12px; }
  footer.site .ftr-col a:hover { color:var(--fg); }
  footer.site .ftr-col .mono { font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    font-size:11px; color:var(--fg-soft); }
  footer.site .ftr-bar { border-top:1px solid var(--border);
    max-width:1400px; margin:0 auto; padding:10px 24px;
    display:flex; align-items:center; gap:12px; flex-wrap:wrap;
    font-size:11px; color:var(--fg-mute); }
  footer.site .ftr-bar .name { font-weight:600; color:var(--fg-soft);
    letter-spacing:.02em; }
  footer.site .ftr-bar .status { display:inline-flex; align-items:center; gap:6px; }
  footer.site .ftr-bar .status .dot { width:6px; height:6px; border-radius:50%;
    background:var(--ok); }
  footer.site .ftr-bar .spacer { flex:1; }
  footer.site .ftr-bar .build { font-variant-numeric:tabular-nums; }
  footer.site .ftr-bar .build .sep { color:var(--border-strong); margin:0 6px; }
  @media (max-width: 720px) {
    footer.site .ftr-grid { grid-template-columns:1fr 1fr; gap:18px;
      padding:14px 16px 10px; }
    footer.site .ftr-bar { padding:10px 16px; }
  }
</style>
</head>
<body>
<header>
  <div class="hdr-inner">
    <h1><span class="brand">hive</span><span class="tag">Swarm Analytics</span></h1>
    <span class="meta" id="meta"></span>
    <span class="spacer"></span>
    <div class="livebar" id="livebar" title="agents currently running on cluster">
      <span class="livebar-group"><span class="dot-live"></span>
        <span class="lbl">workers</span><span class="num" id="live-workers">0</span></span>
      <span class="livebar-group"><span class="dot-live"></span>
        <span class="lbl">reviewers</span><span class="num" id="live-reviewers">0</span></span>
    </div>
    <span class="sprint-badge" id="sprint-badge" hidden>
      <span class="lbl">active</span><span class="name" id="sprint-badge-name"></span>
    </span>
    <button id="refresh" title="Click to refresh now">
      <span class="dot" id="refresh-dot"></span>
      <span id="refresh-label">Refresh</span>
      <span class="countdown" id="refresh-countdown"></span>
    </button>
  </div>
</header>

<main>
  <section>
    <h2>Summary</h2>
    <div class="kpis" id="kpis"></div>
  </section>

  <section>
    <h2>Agents (Prometheus, 1h)</h2>
    <div class="prom" id="prom-agents"></div>
  </section>

  <section>
    <h2>Cluster (Prometheus, 1h)</h2>
    <div class="prom" id="prom-cluster"></div>
  </section>

  <section id="sprints-section" hidden>
    <h2>Sprints</h2>
    <div class="sprint-board" id="sprint-board" hidden></div>
  </section>

  <section>
    <h2>Runs</h2>
    <div class="filters">
      <input id="f-text" placeholder="Search issue / repo">
      <select id="f-type"><option value="">All Types</option></select>
      <select id="f-status"><option value="">All Statuses</option></select>
      <select id="f-role"><option value="">All Roles</option></select>
      <select id="f-model"><option value="">All Models</option></select>
      <select id="f-sprint"><option value="">All Sprints</option></select>
    </div>
    <table id="tbl">
      <thead><tr>
        <th></th>
        <th data-sort="issue_id">Issue</th>
        <th data-sort="sprint">Sprint</th>
        <th data-sort="task_type">Type</th>
        <th data-sort="role">Role · Model</th>
        <th data-sort="tokens"   class="num">Tokens</th>
        <th data-sort="cost_usd" class="num">Cost</th>
        <th data-sort="wall_s"   class="num">Time</th>
      </tr></thead>
      <tbody id="rows"></tbody>
    </table>
    <div id="empty" class="empty" hidden>No runs yet. Fire one with <span class="mono">hivectl fire ANU-7 --type=research</span>.</div>
    <div class="pager" id="pager" hidden>
      <span class="info" id="pager-info"></span>
      <span class="spacer"></span>
      <button id="pager-prev">&larr; Prev</button>
      <button id="pager-next">Next &rarr;</button>
    </div>
  </section>
</main>

<aside class="drawer" id="drawer" aria-hidden="true">
  <header>
    <h3 id="d-title">Run</h3>
    <button class="close" id="d-close">Close</button>
  </header>
  <div class="body">
    <div class="links" id="d-links"></div>
    <div class="grid" id="d-grid"></div>
    <div class="log-tools">
      <h2>Log tail</h2>
      <span class="spacer"></span>
      <div class="seg" role="tablist" aria-label="Log format">
        <button id="d-fmt-pretty" class="active" data-fmt="1">Pretty</button>
        <button id="d-fmt-raw" data-fmt="0">Raw</button>
      </div>
    </div>
    <pre id="d-log">Loading…</pre>
  </div>
</aside>
<div class="drawer-scrim" id="drawer-scrim" aria-hidden="true"></div>

<footer class="site" role="contentinfo">
  <div class="ftr-grid">
    <div class="ftr-col">
      <h4>Platform</h4>
      <ul>
        <li><a href="/">Dashboard</a></li>
        <li><a href="/api/runs" target="_blank" rel="noopener">Runs API</a></li>
        <li><a href="/api/live" target="_blank" rel="noopener">Live pods API</a></li>
        <li><a href="/api/prom" target="_blank" rel="noopener">Prometheus API</a></li>
      </ul>
    </div>
    <div class="ftr-col">
      <h4>Observability</h4>
      <ul>
        <li><a href="http://localhost:9090" target="_blank" rel="noopener">Prometheus</a></li>
        <li><a href="http://localhost:4001" target="_blank" rel="noopener">Headlamp</a></li>
        <li><a href="http://localhost:9091" target="_blank" rel="noopener">Pushgateway</a></li>
      </ul>
    </div>
    <div class="ftr-col">
      <h4>Operations</h4>
      <ul>
        <li><span class="mono">hivectl fire</span></li>
        <li><span class="mono">hivectl metrics</span></li>
        <li><span class="mono">hivectl tail</span></li>
        <li><span class="mono">hivectl merge</span></li>
      </ul>
    </div>
    <div class="ftr-col">
      <h4>Resources</h4>
      <ul>
        <li><a href="https://github.com" target="_blank" rel="noopener">GitHub</a></li>
        <li><a href="https://docs.claude.com/en/docs/claude-code" target="_blank" rel="noopener">Claude Code</a></li>
      </ul>
    </div>
  </div>
  <div class="ftr-bar">
    <span class="name">Agent Control Plane</span>
    <span class="status" title="UI healthy"><span class="dot"></span> operational</span>
    <span class="spacer"></span>
    <span class="build">
      <span>docker-desktop</span>
      <span class="sep">&middot;</span>
      <span>ns agents</span>
      <span class="sep">&middot;</span>
      <span>&copy; <span id="ftr-year">2026</span></span>
    </span>
  </div>
</footer>

<script>
// SSR — server bakes the first frame here so we paint with data, not a spinner.
window.__INITIAL = /*__INITIAL__*/null;

// Footer year — set once on load.
{ const _y = document.getElementById("ftr-year");
  if (_y) _y.textContent = new Date().getFullYear(); }

const $ = (s) => document.querySelector(s);
const fmt = {
  ts: (t) => { const d = new Date(t*1000); return d.toLocaleString(undefined,
    {year:"2-digit",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit"}); },
  usd: (n) => "$" + (Number(n)||0).toFixed(2),
  int: (n) => (Number(n)||0).toLocaleString(),
  sec: (n) => (Number(n)||0).toFixed(0) + "s",
  // Human duration. <1min → "Xs", <1h → "Xm" (rounded), else "Xh Ym".
  dur: (s) => {
    s = Math.round(Number(s)||0);
    if (s < 60)   return s + "s";
    if (s < 3600) return Math.round(s/60) + "m";
    const h = Math.floor(s/3600), m = Math.round((s%3600)/60);
    return m ? `${h}h ${m}m` : `${h}h`;
  },
  // Minutes-only formatter for the runs-table Time column. "0m" if <1min.
  mins: (s) => Math.max(0, Math.round((Number(s)||0) / 60)) + "m",
  // Compact number — 1.2K, 19K, 1.2M, 4.7B. Strips trailing .0.
  compact: (n) => {
    n = Number(n) || 0;
    const a = Math.abs(n), trim = (s) => s.replace(/\.0$/, "");
    if (a >= 1e9) return trim((n/1e9).toFixed(1)) + "B";
    if (a >= 1e6) return trim((n/1e6).toFixed(1)) + "M";
    if (a >= 1e3) return trim((n/1e3).toFixed(1)) + "K";
    return Number.isInteger(n) ? String(n) : n.toFixed(2);
  },
  // Bytes → [value, unit]. Auto-picks MB/GB so a 1.2GB pod doesn't show
  // as "1228 MB" and a 200MB pod doesn't show as "0.2 GB".
  bytesVU: (b) => {
    b = Number(b) || 0;
    const trim = (s) => s.replace(/\.0$/, "");
    if (b >= 1e9) return [trim((b/1e9).toFixed(1)), "GB"];
    if (b >= 1e6) return [Math.round(b/1e6) + "", "MB"];
    return [Math.round(b/1e3) + "", "KB"];
  },
};
const STATUS_BADGE = { SUCCEEDED:"ok", FAILED:"bad", NEEDS_HUMAN:"warn",
  RUNNING:"info" };

// Distribution stats over a numeric series. p95 uses the nearest-rank method
// (sufficient for small n; matches what Prom returns from quantile_over_time).
function stats(arr) {
  if (!arr.length) return {n:0, sum:0, mean:0, p95:0, max:0};
  const sorted = [...arr].sort((a,b) => a-b);
  const sum = arr.reduce((s,n) => s+n, 0);
  const idx = Math.min(sorted.length - 1, Math.ceil(0.95*sorted.length) - 1);
  return { n:arr.length, sum, mean:sum/arr.length, p95:sorted[Math.max(0,idx)],
           max:sorted[sorted.length-1] };
}

const REFRESH_MS = (window.__INITIAL?.ttl ?? 10) * 1000;
const PAGE_SIZE = 10;
let runs = [];
let sortKey = "start_ts", sortDir = -1;
let page = 1;

function passes(r) {
  const t = $("#f-text").value.trim().toLowerCase();
  if (t && !((r.issue_id||"")+" "+(r.repo||"")).toLowerCase().includes(t)) return false;
  for (const [id, k] of [["f-type","task_type"],["f-status","status"],
                         ["f-role","role"],["f-model","model"],
                         ["f-sprint","sprint"]]) {
    const v = $("#"+id).value;
    if (v) {
      // "(no sprint)" → match the empty-string sprint.
      if (id === "f-sprint" && v === "__none__") {
        if ((r.sprint||"") !== "") return false;
      } else if ((r[k]||"") !== v) return false;
    }
  }
  return true;
}

// Status → leading icon HTML. Spinner for RUNNING, glyph for everything else.
function statusIcon(status) {
  if (status === "RUNNING")
    return '<span class="spinner" title="RUNNING"></span>';
  const map = {
    SUCCEEDED:   ["ok",      "&check;", "SUCCEEDED"],
    FAILED:      ["bad",     "&times;", "FAILED"],
    NEEDS_HUMAN: ["warn",    "&#9888;", "NEEDS_HUMAN"],
  };
  const [cls, ch, title] = map[status] || ["neutral", "&bull;", status||"-"];
  return `<span class="ico ${cls}" title="${title}">${ch}</span>`;
}

function render() {
  // Historical runs respect the user's filters; live rows always show
  // (they're "what's happening now" — too valuable to filter out).
  const completed = runs.filter(passes).slice().sort((a,b) => {
    const get = (r) => sortKey === "tokens"
      ? (r.input_tokens||0) + (r.output_tokens||0)
      : r[sortKey];
    const av = get(a), bv = get(b);
    if (typeof av === "number") return (av - bv) * sortDir;
    return String(av||"").localeCompare(String(bv||"")) * sortDir;
  });
  const liveRows = liveAsRunRows().filter(passes);
  // Hard cap the whole table at PAGE_SIZE (10) — live rows take their slots
  // first (truncated if >PAGE_SIZE), completed fills the remainder.
  const liveVisible    = liveRows.slice(0, PAGE_SIZE);
  const remainingSlots = PAGE_SIZE - liveVisible.length;
  const perPage        = Math.max(1, remainingSlots);
  const totalPages     = remainingSlots > 0
    ? Math.max(1, Math.ceil(completed.length / perPage))
    : 1;
  if (page > totalPages) page = totalPages;
  if (page < 1) page = 1;
  const startIdx = (page - 1) * perPage;
  const pageRows = remainingSlots > 0
    ? completed.slice(startIdx, startIdx + remainingSlots)
    : [];
  // RUNNING rows always at the very top.
  const visible = liveVisible.concat(pageRows);

  // Distributions over the FILTERED COMPLETED set — live rows have all-
  // zero numerics by design and would skew averages downward.
  const costS  = stats(completed.map(r => r.cost_usd      || 0));
  const timeS  = stats(completed.map(r => r.wall_s        || 0));
  const tokS   = stats(completed.map(r => (r.input_tokens||0) + (r.output_tokens||0)));
  const okN    = completed.filter(r => r.status === "SUCCEEDED").length;
  const badN   = completed.filter(r => r.status === "FAILED").length;
  const nhN    = completed.filter(r => r.status === "NEEDS_HUMAN").length;

  const card = (label, value, sub) =>
    `<div class="kpi"><div class="label">${label}</div>
       <div class="value">${value}</div><div class="sub">${sub}</div></div>`;
  // stat() splits the label and the number into separately-styled spans.
  // Literal spaces between them defeat the "p9511.99cores" rendering that
  // CSS margins didn't always produce inside flex children.
  const stat = (lbl, val) =>
    `<span><span class="lbl">${lbl}</span> <span class="num">${val}</span></span>`;
  const row = (...parts) => parts.join(' <span class="sep">·</span> ');

  $("#kpis").innerHTML = [
    // Row 1 — totals.
    card("Total runs",   fmt.int(completed.length),
         row(stat("ok",      okN),
             stat("fail",    badN),
             stat("blocked", nhN))),
    card("Total tokens", fmt.compact(tokS.sum),
         row(stat("mean", fmt.compact(tokS.mean)),
             stat("p95",  fmt.compact(tokS.p95)),
             stat("max",  fmt.compact(tokS.max)))),
    card("Total cost",   fmt.usd(costS.sum),
         row(stat("mean", fmt.usd(costS.mean)),
             stat("p95",  fmt.usd(costS.p95)),
             stat("max",  fmt.usd(costS.max)))),
    // Row 2 — per-run averages.
    card("Avg time",     fmt.dur(timeS.mean),
         row(stat("p95",  fmt.dur(timeS.p95)),
             stat("max",  fmt.dur(timeS.max)))),
    card("Avg tokens",   fmt.compact(tokS.mean),
         row(stat("p95",  fmt.compact(tokS.p95)),
             stat("max",  fmt.compact(tokS.max)))),
    card("Avg cost",     fmt.usd(costS.mean),
         row(stat("p95",  fmt.usd(costS.p95)),
             stat("max",  fmt.usd(costS.max)))),
  ].join("");

  $("#empty").hidden = visible.length > 0;
  // For live rows the numeric columns are unknown — render an em-dash
  // instead of a misleading "$0.0000".
  const cellOrDash = (live, val) =>
    live ? `<span style="color:var(--fg-mute)">—</span>` : val;
  const sprintCell = (s) => s
    ? `<a class="sprint-chip" href="#${s}" title="${s}">${s}</a>`
    : `<span class="sprint-chip none">—</span>`;
  $("#rows").innerHTML = visible.map(r => `
    <tr data-run="${r.run}">
      <td class="st">${statusIcon(r.status)}</td>
      <td><strong>${r.issue_id||""}</strong></td>
      <td>${sprintCell(r.sprint)}</td>
      <td>${r.task_type||""}</td>
      <td>${(r.role||"") + (r.model ? ` <span style="color:var(--fg-mute)">(${r.model})</span>` : "")}</td>
      <td class="num">${cellOrDash(r._live, fmt.compact((r.input_tokens||0)+(r.output_tokens||0)))}</td>
      <td class="num">${cellOrDash(r._live, fmt.usd(r.cost_usd))}</td>
      <td class="num">${cellOrDash(r._live, fmt.mins(r.wall_s))}</td>
    </tr>`).join("");

  // Pagination controls — hidden when one page (or zero remaining slots) of completed runs.
  const pager = $("#pager");
  if (remainingSlots === 0 || completed.length <= remainingSlots) {
    pager.hidden = true;
  } else {
    pager.hidden = false;
    const from = startIdx + 1;
    const to   = Math.min(startIdx + remainingSlots, completed.length);
    $("#pager-info").textContent =
      `Showing ${from}–${to} of ${completed.length} · page ${page}/${totalPages}`;
    $("#pager-prev").disabled = page <= 1;
    $("#pager-next").disabled = page >= totalPages;
  }
}

const _FILTER_LABEL = {
  task_type: "All Types",
  status:    "All Statuses",
  role:      "All Roles",
  model:     "All Models",
};
function fillSelect(id, key) {
  const vals = [...new Set(runs.map(r => r[key]).filter(Boolean))].sort();
  const sel = $("#"+id);
  const cur = sel.value;
  sel.innerHTML = `<option value="">${_FILTER_LABEL[key] || ("All "+key)}</option>` +
    vals.map(v => `<option ${v===cur?"selected":""}>${v}</option>`).join("");
}

function fillSprintSelect() {
  // Sprint dropdown — most recent first, plus a "(no sprint)" sentinel for
  // rows whose issue isn't on any promise.
  const vals = [...new Set(runs.map(r => r.sprint).filter(Boolean))]
    .sort((a,b) => {
      const ai = parseInt(a.split("-")[1]||"0", 10);
      const bi = parseInt(b.split("-")[1]||"0", 10);
      return bi - ai;
    });
  const sel = $("#f-sprint");
  const cur = sel.value;
  sel.innerHTML = `<option value="">All Sprints</option>` +
    vals.map(v => `<option value="${v}" ${v===cur?"selected":""}>${v}</option>`).join("") +
    `<option value="__none__" ${cur==="__none__"?"selected":""}>(No Sprint)</option>`;
}

function applyRuns(data) {
  runs = data || [];
  $("#meta").textContent = runs.length + " runs · " +
    new Date().toLocaleTimeString();
  fillSelect("f-type","task_type"); fillSelect("f-status","status");
  fillSelect("f-role","role"); fillSelect("f-model","model");
  fillSprintSelect();
  render();
}

let sprints = [];
function applySprints(data) {
  sprints = data || [];
  // Active-sprint badge — biggest open sprint (most live + non-closed runs).
  const open = sprints.filter(s => s.state !== "closed");
  open.sort((a,b) =>
    (b.pods_live + b.runs) - (a.pods_live + a.runs) || (b.n - a.n));
  const top = open[0];
  if (top) {
    $("#sprint-badge").hidden = false;
    $("#sprint-badge").classList.toggle("in-flight", top.state === "in-flight");
    $("#sprint-badge-name").textContent = top.name;
  } else {
    $("#sprint-badge").hidden = true;
  }
  // Sprint filter — re-fill in case a new sprint appeared.
  fillSprintSelect();
  // Active sprint only — highest-numbered non-closed; falls back to the newest
  // sprint if every one is closed, or hides the section if there are none.
  // Rendered as one unified board (header + stats + progress + wave grid).
  const sec = $("#sprints-section");
  if (!sprints.length) { sec.hidden = true; return; }
  sec.hidden = false;
  const active = sprints.find(s => s.state !== "closed") || sprints[0];
  renderBoard(active);
}

// Unified live board for the active sprint: header (name / state / thesis /
// links / current-wave), one combined stats line, a progress bar with ETA, and
// tickets grouped by planned wave. Re-rendered every poll; cost / runs / wall
// "bump" when they change so updates are visible. The wave grid is omitted
// until the sprint has tickets, so a planned-but-unfired sprint still shows its
// header, stats, and progress.
let _boardPrev = {};
function renderBoard(s) {
  const board = $("#sprint-board");
  if (!s) { board.hidden = true; return; }
  board.hidden = false;
  const esc = (x) => (x||"").replace(/[<>&]/g,
    c => ({"<":"&lt;",">":"&gt;","&":"&amp;"}[c]));
  const prev = _boardPrev[s.name] || {};
  const bump = (k, v) => (prev[k] !== undefined && prev[k] !== v) ? " bump" : "";
  const stat = (lbl, val, b) =>
    `<span class="stat"><span class="lbl">${lbl}</span><span class="num${b||""}">${val}</span></span>`;
  const sep = `<span class="sep">·</span>`;
  const links = [
    `<a href="file://${s.promise_path}" title="${s.promise_path}">promise</a>`,
    s.result_path ? `<a href="file://${s.result_path}" title="${s.result_path}">result</a>` : "",
    `<a target="_blank" rel="noopener" href="https://github.com/issues?q=is%3Apr+label%3A${encodeURIComponent(s.name)}">GitHub</a>`,
  ].filter(Boolean).join('');
  const pct = s.percent || 0;
  const etaTxt = s.state === "closed" ? "done"
               : s.eta_s > 0          ? "~" + fmt.dur(s.eta_s)
                                      : "—";
  const curTxt = s.state === "closed" ? "complete"
              : (s.planned_waves ? `wave ${s.current_wave} / ${s.planned_waves}` : "—");
  // Wave grid — only once the sprint has tickets.
  let waveRows = "";
  if (s.tickets && s.tickets.length) {
    const byWave = new Map();
    for (const t of s.tickets) {
      if (!byWave.has(t.wave)) byWave.set(t.wave, []);
      byWave.get(t.wave).push(t);
    }
    const waves = [...byWave.keys()].sort((a, b) => a - b);
    const waveLabel = (w) => w === 0 ? "unscheduled" : "wave " + w;
    waveRows = waves.map(w => {
      const tix = byWave.get(w).map(t =>
        `<span class="tix ${t.status}" title="${t.issue} · ${t.status}">#${t.num}</span>`).join("");
      const cur = (w === s.current_wave && s.state !== "closed") ? " current" : "";
      return `<div class="sb-wave${cur}"><span class="wv">${waveLabel(w)}</span>` +
             `<div class="sb-tix">${tix}</div></div>`;
    }).join("");
  }
  // Both classes: .sprint-card supplies the .sc-* header/stats/progress styles
  // and the state-coloured progress fill; .sprint-board supplies .sb-* + waves.
  board.className = "sprint-card sprint-board " + s.state;
  board.innerHTML =
    `<div class="sb-head">
      <span class="sc-name">${s.name}</span>
      <span class="sc-chip ${s.state}">${s.state}</span>
      <span class="sc-thesis">${esc(s.thesis)}</span>
      <span class="sc-links">${links}</span>
      <span class="sb-cur">${curTxt}</span>
    </div>
    <div class="sc-stats">
      ${stat("issues", s.done + " / " + (s.total_issues || "?"))}
      ${sep}${stat("runs",     s.runs,             bump('runs', s.runs))}
      ${sep}${stat("live",     s.pods_live)}
      ${sep}${stat("waves",    s.waves)}
      ${sep}${stat("cost",     fmt.usd(s.cost_usd), bump('cost', s.cost_usd))}
      ${sep}${stat("tokens",   fmt.compact(s.tokens))}
      ${sep}${stat("run time", fmt.dur(s.wall_s),   bump('wall', s.wall_s))}
      ${s.failed  ? sep + stat("failed",  s.failed)  : ""}
      ${s.blocked ? sep + stat("blocked", s.blocked) : ""}
    </div>
    <div class="sc-progress">
      <div class="sc-bar"><div class="sc-bar-fill" style="width:${pct}%"></div></div>
      <span class="sc-pct">${pct}%</span>
      <span class="sc-eta"><span class="lbl">ETA</span><span class="num">${etaTxt}</span></span>
    </div>${waveRows}`;
  _boardPrev[s.name] = { cost: s.cost_usd, runs: s.runs, wall: s.wall_s };
}

function applyProm(d) {
  const errHTML = (msg) =>
    `<div class="kpi" style="grid-column:1/-1">
      <div class="label">Prometheus</div>
      <div class="value" style="font-size:13px;color:var(--fg-soft)">${msg}</div>
      <div class="sub">Start with <span class="mono">kubectl -n monitoring port-forward svc/prometheus 9090:9090</span> or LB on :9090.</div>
     </div>`;
  if (!d || d.error) {
    const html = errHTML((d && d.error) || "unreachable");
    $("#prom-agents").innerHTML = html;
    $("#prom-cluster").innerHTML = "";
    return;
  }
  const cell = (label, v, sub) =>
    `<div class="kpi"><div class="label">${label}</div>
      <div class="value">${v}</div><div class="sub">${sub||""}</div></div>`;
  // Literal spaces between spans so we don't end up with "p9511.99cores"
  // when CSS margins get eaten by flex.
  const stat = (lbl, val, unit) =>
    `<span><span class="lbl">${lbl}</span> <span class="num">${val}</span>` +
    (unit ? ` <span class="unit">${unit}</span>` : "") + `</span>`;
  const row = (...parts) => parts.join(' <span class="sep">·</span> ');
  const cores = (n) => fmt.compact(Number(n)||0);
  const memH  = (b) => { const [v,u] = fmt.bytesVU(b); return v + " " + u; };
  // Agents panel (priority — comes first visually).
  $("#prom-agents").innerHTML = [
    cell("Agent CPU (avg)", cores(d.agent_cpu_mean) + " cores",
         row(stat("p95", cores(d.agent_cpu_p95), "cores"),
             stat("max", cores(d.agent_cpu_max), "cores"))),
    cell("Agent RAM (avg)", memH(d.agent_mem_mean),
         row(stat("p95", ...fmt.bytesVU(d.agent_mem_p95)),
             stat("max", ...fmt.bytesVU(d.agent_mem_max)))),
    cell("Agent pods running", fmt.int(d.agent_pods),
         `<span><span class="lbl">namespace</span> <span class="num">agents</span></span>`),
  ].join("");
  // Cluster panel (context — secondary).
  $("#prom-cluster").innerHTML = [
    cell("Cluster CPU (avg)", cores(d.cpu_mean) + " cores",
         row(stat("p95", cores(d.cpu_p95), "cores"),
             stat("max", cores(d.cpu_max), "cores"))),
    cell("Cluster RAM (avg)", memH(d.mem_mean),
         row(stat("p95", ...fmt.bytesVU(d.mem_p95)),
             stat("max", ...fmt.bytesVU(d.mem_max)))),
    cell("Cluster pods", fmt.int(d.cluster_pods),
         row(stat("nodes", fmt.int(d.cluster_nodes)),
             stat("agents", fmt.int(d.agent_pods)))),
  ].join("");
}

async function loadRuns() {
  const r = await fetch("/api/runs");
  applyRuns(await r.json());
}

async function loadProm() {
  const r = await fetch("/api/prom");
  applyProm(await r.json());
}

async function loadLive() {
  const r = await fetch("/api/live");
  applyLive(await r.json());
}

async function loadSprints() {
  const r = await fetch("/api/sprints");
  applySprints(await r.json());
}

let liveRuns = [];  // raw pod list; merged into the runs table below

function applyLive(rows) {
  liveRuns = rows || [];
  // Header counters — how many live pods per role.
  const workers   = liveRuns.filter(r => r.role === "worker").length;
  const reviewers = liveRuns.filter(r => r.role === "reviewer").length;
  $("#live-workers").textContent   = workers;
  $("#live-reviewers").textContent = reviewers;
  // Re-render the runs table so RUNNING rows show at the top.
  render();
}

// Project each live pod into the row shape the runs table expects, so the
// same renderer + sorter can handle it. Zero-valued numerics mean the
// distribution stats ignore it cleanly.
function liveAsRunRows() {
  return liveRuns.map(p => ({
    run:           "live:" + (p.pod || ""),  // unique synthetic id
    issue_id:      p.issue_id,
    task_type:     p.task_type,
    role:          p.role,
    model:         p.model,
    sprint:        p.sprint || "",
    status:        "RUNNING",
    start_ts:      p.started ? Math.floor(new Date(p.started).getTime()/1000) : 0,
    cost_usd:      0, wall_s: 0, num_turns: 0,
    hammers:       0, hammer_max: 3,
    input_tokens:  0, output_tokens: 0, cache_read: 0, cache_creation: 0,
    duration_ms:   0,
    pr_url:        "",
    pod:           p.pod,
    _live:         true,
  }));
}

document.querySelectorAll("thead th[data-sort]").forEach(th => {
  th.addEventListener("click", () => {
    const k = th.dataset.sort;
    sortDir = (sortKey === k) ? -sortDir : -1;
    sortKey = k;
    page = 1;
    render();
  });
});
document.querySelectorAll(".filters input, .filters select").forEach(el => {
  el.addEventListener("input", () => { page = 1; render(); });
});
$("#pager-prev").addEventListener("click", () => { page -= 1; render(); });
$("#pager-next").addEventListener("click", () => { page += 1; render(); });
// Refresh button doubles as a status indicator. Countdown ticks every second;
// at 0 the page auto-refreshes both endpoints. Click forces an immediate
// refresh and resets the countdown.
let _remaining = REFRESH_MS / 1000;
const _btn = $("#refresh");
const _cd  = $("#refresh-countdown");
function paintCountdown() { _cd.textContent = _remaining + "s"; }
async function refreshAll() {
  _btn.classList.add("refreshing");
  try {
    await Promise.all([loadRuns(), loadProm(), loadLive(), loadSprints()]);
  } finally {
    _btn.classList.remove("refreshing");
    _remaining = REFRESH_MS / 1000;
    paintCountdown();
  }
}
_btn.addEventListener("click", refreshAll);
setInterval(() => {
  _remaining -= 1;
  if (_remaining <= 0) { refreshAll(); return; }
  paintCountdown();
}, 1000);
paintCountdown();

$("#rows").addEventListener("click", async (e) => {
  const tr = e.target.closest("tr"); if (!tr) return;
  const id = tr.dataset.run;
  // Look in both completed runs and live rows.
  const r = runs.find(x => x.run === id) ||
            liveAsRunRows().find(x => x.run === id);
  if (!r) return;
  $("#d-title").textContent = `${r.issue_id} — ${r.task_type||""}`;
  const fields = r._live ? [
    ["Issue", r.issue_id], ["Task type", r.task_type], ["Role", r.role],
    ["Model", r.model], ["Status", `<span class="badge info">RUNNING</span>`],
    ["Pod", `<span class="mono">${r.pod}</span>`],
    ["Started", new Date(r.start_ts*1000).toLocaleString()],
    ["Cost / Tokens / Turns", `<span style="color:var(--fg-mute)">pending — run is in progress</span>`],
    ["Tail live", `<span class="mono">hivectl tail ${r.issue_id}</span>`],
  ] : [
    ["Issue", r.issue_id], ["Task type", r.task_type], ["Role", r.role],
    ["Model", r.model], ["Repo", r.repo], ["Status", r.status],
    ["Started", new Date(r.start_ts*1000).toLocaleString()],
    ["Cost", fmt.usd(r.cost_usd)], ["Wall", r.wall_s+"s"],
    ["Duration (model)", (r.duration_ms/1000).toFixed(1)+"s"],
    ["Turns / Hammers", r.num_turns + " / " + r.hammers + " of " + (r.hammer_max||3)],
    ["Tokens in / out", fmt.int(r.input_tokens) + " / " + fmt.int(r.output_tokens)],
    ["Cache read / creation", fmt.int(r.cache_read) + " / " + fmt.int(r.cache_creation)],
    ["PR", r.pr_url ? `<a href="${r.pr_url}" target="_blank">${r.pr_url}</a>` : "—"],
    ["Run id", `<span class="mono">${r.run}</span>`],
  ];
  $("#d-grid").innerHTML = fields.map(([k,v]) =>
    `<div class="k">${k}</div><div class="v">${v ?? "—"}</div>`).join("");
  // Top-of-drawer link pills — GitHub issue, repo, PR. All three are
  // pure links derived from the row + the project's repo URL (baked into
  // window.__INITIAL.repo_url server-side). No server roundtrip.
  const pills = [];
  // Strip trailing .git and any github.com prefix to get owner/name.
  const repoSlug = r.repo_slug ||
    ((window.__INITIAL?.repo_url || "")
       .replace(/\.git$/, "")
       .replace(/^.*github\.com[:/]/, ""));
  // Issue number: prefer explicit r.issue_number; fall back to parsing
  // "issue-42" out of r.issue_id.
  const issueNum = r.issue_number ||
    (r.issue_id || "").replace(/^issue-/, "");
  if (repoSlug && /^\d+$/.test(String(issueNum))) {
    const issueUrl = `https://github.com/${repoSlug}/issues/${issueNum}`;
    pills.push(`<a class="pill gh" href="${issueUrl}" target="_blank" rel="noopener">
      <span class="dot"></span><span class="label">Issue</span>
      <span class="val">#${issueNum}</span></a>`);
  }
  if (repoSlug) {
    const repoUrl = `https://github.com/${repoSlug}`;
    pills.push(`<a class="pill gh" href="${repoUrl}" target="_blank" rel="noopener">
      <span class="dot"></span><span class="label">Repo</span>
      <span class="val">${repoSlug.split("/").pop()}</span></a>`);
  }
  if (r.pr_url) {
    const m = (r.pr_url || "").match(/\/pull\/(\d+)/);
    const label = m ? ("PR #" + m[1]) : "PR";
    pills.push(`<a class="pill gh" href="${r.pr_url}" target="_blank" rel="noopener">
      <span class="dot"></span><span class="label">PR</span>
      <span class="val">${label}</span></a>`);
  }
  $("#d-links").innerHTML = pills.join("");
  $("#drawer").classList.add("open");
  $("#drawer-scrim").classList.add("open");
  drawerRun    = r.run;
  drawerLive   = !!r._live;
  drawerPretty = 1;
  // Reset toggle to Pretty whenever a new row opens.
  $("#d-fmt-pretty").classList.add("active");
  $("#d-fmt-raw").classList.remove("active");
  loadDrawerLog(r.run, 1);
  // Auto-tail only for in-flight pods. Completed runs are static — no point.
  if (drawerLive) startDrawerTail(); else stopDrawerTail();
});

let drawerRun = null;
let drawerLive = false;
let drawerPretty = 1;
let drawerTimer = null;
async function loadDrawerLog(run, pretty, opts) {
  const isRefresh = opts && opts.refresh;
  // Only show "Loading…" on first open — refreshes shouldn't blank the view
  // mid-stream, that'd flash.
  if (!isRefresh) $("#d-log").textContent = "Loading…";
  const logEl = $("#d-log");
  // GitHub-Actions-style sticky bottom: default to auto-follow, but if the
  // user has scrolled up to read, leave their scroll position alone. They
  // resume auto-follow by scrolling back to the bottom.
  const prevTop = logEl.scrollTop;
  const wasAtBottom = isRefresh
    ? (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 24)
    : true;  // first open → snap to latest
  const lr = await fetch("/api/log?run=" + encodeURIComponent(run) +
    "&pretty=" + (pretty ? 1 : 0));
  const body = await lr.text();
  // Pretty mode ships HTML (server returns text/html with per-row classes);
  // raw mode is the untouched log bytes — never inject those as HTML.
  if (pretty) $("#d-log").innerHTML = body;
  else        $("#d-log").textContent = body;
  logEl.scrollTop = wasAtBottom ? logEl.scrollHeight : prevTop;
}
function stopDrawerTail() {
  if (drawerTimer) { clearInterval(drawerTimer); drawerTimer = null; }
}
function startDrawerTail() {
  stopDrawerTail();
  // 5s tail refresh while a live row's drawer is open — fast enough to feel
  // live, slow enough to not hammer kubectl.
  drawerTimer = setInterval(() => {
    if (drawerRun && drawerLive) {
      loadDrawerLog(drawerRun, drawerPretty, {refresh: true});
    }
  }, 5000);
}
function closeDrawer() {
  $("#drawer").classList.remove("open");
  $("#drawer-scrim").classList.remove("open");
  stopDrawerTail();
  drawerRun = null;
  drawerLive = false;
}
$("#d-fmt-pretty").addEventListener("click", () => {
  $("#d-fmt-pretty").classList.add("active");
  $("#d-fmt-raw").classList.remove("active");
  drawerPretty = 1;
  if (drawerRun) loadDrawerLog(drawerRun, 1);
});
$("#d-fmt-raw").addEventListener("click", () => {
  $("#d-fmt-raw").classList.add("active");
  $("#d-fmt-pretty").classList.remove("active");
  drawerPretty = 0;
  if (drawerRun) loadDrawerLog(drawerRun, 0);
});
$("#d-close").addEventListener("click", closeDrawer);
$("#drawer-scrim").addEventListener("click", closeDrawer);
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") closeDrawer();
});

// First paint: use the SSR-baked data if present (instant). If for some
// reason it's missing, fall back to a fetch so we never show an empty page.
if (window.__INITIAL && window.__INITIAL.runs) {
  applyRuns(window.__INITIAL.runs);
  applyProm(window.__INITIAL.prom);
  applyLive(window.__INITIAL.live);
  applySprints(window.__INITIAL.sprints || []);
} else {
  refreshAll();
}
</script>
</body>
</html>
"""
