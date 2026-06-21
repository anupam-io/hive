#!/usr/bin/env node
// Wave planner — deterministic topological layering with file-collision splitting.
//
// Reads a JSON array of issues and produces a wave schedule. Each wave is a set
// of issues that (a) have every dep satisfied by an earlier wave and (b) own no
// file in common with another issue in the SAME wave. A shared file is a
// scheduling edge: the later issue is pushed to a subsequent wave even with no
// logical dep, so two pods never edit one file in parallel. This is the rule the
// driver used to discover at fire time and shrink waves over — here it's precomputed.
//
// Usage:
//   node wave-sort.mjs issues.json                       # text table + writes dag.mmd + dag.html beside input
//   node wave-sort.mjs issues.json --out DIR             # write artifacts into DIR
//   node wave-sort.mjs issues.json --max-wave-width 16   # cap each wave to cluster headroom (default 16)
//   cat issues.json | node wave-sort.mjs -               # read stdin (then --out is required for files)
//
// issues.json schema — one object per issue:
//   [{ "id": 12, "title": "transfers schema", "type": "feature",
//      "deps": [], "files": ["db/schema/transfers.ts"] }, ...]
//   deps  = issue ids this one blocks on (logical prerequisite). [] for a leaf.
//   files = paths/globs this issue will own. Used only for collision splitting.
//
// Exit: 0 ok · 1 cycle detected (remaining ids printed) · 2 bad input.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

function die(code, msg) { console.error(msg); process.exit(code); }

// Escape chars that break Mermaid node labels (rendered inside "..."), using
// numeric HTML entities Mermaid understands — keeps dag.html from silently
// failing to render when a title contains [] {} <> or quotes.
const mermaidLabel = s => String(s)
  .replace(/"/g, "#34;").replace(/\[/g, "#91;").replace(/\]/g, "#93;")
  .replace(/\{/g, "#123;").replace(/\}/g, "#125;")
  .replace(/</g, "#60;").replace(/>/g, "#62;");

// ---- args ----
const argv = process.argv.slice(2);
const inPath = argv[0];
if (!inPath) die(2, "usage: wave-sort.mjs <issues.json|-> [--out DIR]");
const outIdx = argv.indexOf("--out");
const outDir = outIdx >= 0 ? argv[outIdx + 1] : (inPath === "-" ? null : dirname(inPath));
const wIdx = argv.indexOf("--max-wave-width");
const MAX_WIDTH = wIdx >= 0 ? Number(argv[wIdx + 1]) : 16;   // never fire a wave wider than cluster headroom
if (!(MAX_WIDTH >= 1)) die(2, "--max-wave-width must be >= 1");

let raw;
try { raw = inPath === "-" ? readFileSync(0, "utf8") : readFileSync(inPath, "utf8"); }
catch (e) { die(2, `cannot read input: ${e.message}`); }

let issues;
try { issues = JSON.parse(raw); } catch (e) { die(2, `bad JSON: ${e.message}`); }
if (!Array.isArray(issues) || issues.length === 0) die(2, "input must be a non-empty JSON array");

// ---- normalise + validate ----
const byId = new Map();
const GLOB = /[*?[\]{}]/;        // the collision check is literal string equality — a glob would silently never collide
for (const it of issues) {
  if (it.id == null) die(2, `issue missing id: ${JSON.stringify(it)}`);
  it.id = Number(it.id);         // coerce once so deps / placed / waveOf all speak the same type
  if (Number.isNaN(it.id)) die(2, `issue id is not a number: ${JSON.stringify(it)}`);
  if (byId.has(it.id)) die(2, `duplicate issue id: #${it.id}`);
  it.deps = (it.deps || []).map(Number);
  it.files = it.files || [];
  for (const f of it.files)
    if (GLOB.test(f)) die(2, `issue #${it.id} file "${f}" contains a glob — list exact paths only (the collision check is literal, so a glob would never split a wave)`);
  it.type = it.type || "feature";
  it.title = String(it.title || `issue ${it.id}`);
  byId.set(it.id, it);
}
for (const it of issues)
  for (const d of it.deps)
    if (!byId.has(d)) die(2, `issue #${it.id} deps on #${d} which is not in the set`);

// ---- topological layering with file-disjoint packing ----
const placed = new Set();
const waveOf = new Map();          // id -> wave number (1-based)
const collisionEdges = [];        // [laterId, earlierId] pushed apart by a shared file
const waves = [];

while (placed.size < issues.length) {
  const ready = issues
    .filter(it => !placed.has(it.id) && it.deps.every(d => placed.has(d)))
    .sort((a, b) => a.id - b.id);
  if (ready.length === 0) {
    const stuck = issues.filter(it => !placed.has(it.id)).map(it => `#${it.id}`);
    die(1, `dependency cycle — cannot place: ${stuck.join(", ")}`);
  }
  const wave = [];
  const usedFiles = new Map();     // file -> id that claimed it this wave
  for (const it of ready) {
    if (wave.length >= MAX_WIDTH) break;   // wave full — remaining ready issues form the next (sub-)wave
    const clash = it.files.find(f => usedFiles.has(f));
    if (clash) { collisionEdges.push([it.id, usedFiles.get(clash)]); continue; } // defer to a later wave
    wave.push(it);
    for (const f of it.files) usedFiles.set(f, it.id);
  }
  const n = waves.length + 1;
  for (const it of wave) { placed.add(it.id); waveOf.set(it.id, n); }
  waves.push(wave);
}

// ---- text table ----
const pad = (s, w) => String(s).padEnd(w);
console.log(`\n${issues.length} issues → ${waves.length} waves\n`);
console.log(`${pad("wave", 5)}${pad("#", 6)}${pad("type", 14)}${pad("deps", 10)}title`);
console.log("-".repeat(72));
for (const [i, wave] of waves.entries())
  for (const it of wave)
    console.log(`${pad(i + 1, 5)}${pad("#" + it.id, 6)}${pad(it.type, 14)}${pad(it.deps.map(d => "#" + d).join(",") || "-", 10)}${it.title}`);
console.log("");

// ---- mermaid ----
const nid = id => `n${id}`;
let mmd = "flowchart LR\n";
for (const [i, wave] of waves.entries()) {
  mmd += `  subgraph W${i + 1}["Wave ${i + 1}"]\n`;
  for (const it of wave) mmd += `    ${nid(it.id)}["#${it.id} ${mermaidLabel(it.title)}"]\n`;
  mmd += "  end\n";
}
for (const it of issues)
  for (const d of it.deps) mmd += `  ${nid(d)} --> ${nid(it.id)}\n`;
for (const [later, earlier] of collisionEdges)
  mmd += `  ${nid(earlier)} -. shared file .-> ${nid(later)}\n`;

// ---- html ----
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sprint Wave DAG</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#0d1117; color:#e6edf3; font:15px/1.5 system-ui,sans-serif; }
  header { padding:20px 28px; border-bottom:1px solid #21262d; }
  header h1 { margin:0; font-size:18px; }
  header p { margin:6px 0 0; color:#8b949e; font-size:13px; }
  .legend { display:flex; gap:18px; margin-top:10px; font-size:12px; color:#8b949e; }
  .legend b { color:#e6edf3; font-weight:600; }
  .wrap { padding:24px 28px; overflow:auto; }
  .mermaid { background:#0d1117; }
</style></head>
<body>
<header>
  <h1>Sprint Wave DAG</h1>
  <p>${issues.length} issues · ${waves.length} waves · solid = dependency · dotted = same-file split</p>
  <div class="legend"><span><b>Wave N</b> fires as one parallel shot</span><span>edges point from prerequisite → dependent</span></div>
</header>
<div class="wrap">
<pre class="mermaid">
${mmd}</pre>
</div>
<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({ startOnLoad:true, theme:"dark", flowchart:{ curve:"basis" } });
</script>
</body></html>`;

if (outDir) {
  writeFileSync(join(outDir, "dag.mmd"), mmd);
  writeFileSync(join(outDir, "dag.html"), html);
  console.log(`wrote ${join(outDir, "dag.mmd")} and ${join(outDir, "dag.html")}`);
} else {
  console.log("(no --out and stdin input — skipping file artifacts; mermaid below)\n");
  console.log(mmd);
}
