// Stage-0 (lean) baseline capture for the QA loop. We ONLY collect what the
// agent can't get cheaply from its Playwright MCP later: console events and
// network errors (those need page-level listeners attached BEFORE navigation,
// MCP can't replay them). Plus an `01-initial.png` + `02-loaded.png` so the
// feedback issue has at least two ground-truth screenshots regardless of what
// the agent decided to explore.
//
// Everything else — scroll, hover, mobile breakpoint, interaction, full-page
// shot — is the agent's job via Playwright MCP. We are NOT pre-canning the QA.
//
//   node qa-capture.mjs <URL> <OUTDIR>
//
// Produces in $OUTDIR:
//   01-initial.png    first paint (DOMContentLoaded)
//   02-loaded.png     after networkidle (or load fallback)
//   page.txt          document.body.innerText
//   console.log       every browser console event during load
//   network.log       every failed request / non-2xx response during load
//   meta.json         url, viewport, timings, errors

import { chromium } from 'playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const URL_ARG = process.argv[2];
const OUTDIR  = process.argv[3];
if (!URL_ARG || !OUTDIR) {
  console.error('usage: qa-capture.mjs <URL> <OUTDIR>');
  process.exit(2);
}
mkdirSync(OUTDIR, { recursive: true });
const out = (n) => resolve(OUTDIR, n);

const VIEWPORT = { width: 1280, height: 720 };
const consoleLog = [];
const networkLog = [];
const meta = { url: URL_ARG, viewport: VIEWPORT, started_at: new Date().toISOString(), errors: [] };

const t0 = Date.now();
const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const ctx = await browser.newContext({ viewport: VIEWPORT });
const page = await ctx.newPage();

page.on('console',   (m)   => consoleLog.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e)   => { consoleLog.push(`[pageerror] ${e.message}`); meta.errors.push({ kind: 'pageerror', message: e.message }); });
page.on('requestfailed', (r) => networkLog.push(`[failed] ${r.method()} ${r.url()} — ${r.failure()?.errorText ?? '?'}`));
page.on('response',  (r)   => { if (r.status() >= 400) networkLog.push(`[${r.status()}] ${r.request().method()} ${r.url()}`); });

try {
  await page.goto(URL_ARG, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.screenshot({ path: out('01-initial.png'), fullPage: false });

  await page
    .waitForLoadState('networkidle', { timeout: 20_000 })
    .catch(() => page.waitForLoadState('load', { timeout: 20_000 }).catch(() => {}));
  await page.waitForTimeout(1500);
  await page.screenshot({ path: out('02-loaded.png'), fullPage: false });

  writeFileSync(out('page.txt'), await page.evaluate(() => document.body.innerText ?? ''));
  meta.status = 'ok';
} catch (err) {
  meta.status = 'capture_error';
  meta.errors.push({ kind: 'capture', message: String(err?.message ?? err) });
} finally {
  meta.duration_ms = Date.now() - t0;
  meta.finished_at = new Date().toISOString();
  writeFileSync(out('console.log'), consoleLog.join('\n'));
  writeFileSync(out('network.log'), networkLog.join('\n'));
  writeFileSync(out('meta.json'),   JSON.stringify(meta, null, 2));
  await ctx.close();
  await browser.close();
}

console.log(JSON.stringify({ outdir: OUTDIR, ...meta }, null, 2));
