# Plan: experimental Hermes Agent worker

Status: **draft, not approved for execution.** No code written.
Owner: ak
Last updated: 2026-06-07

## Goal & non-goals

**Goal:** fire a single ticket against Hermes Agent (Nous Research) in a pod, observe quality / cost / wall-time vs the Claude Code baseline. Side-by-side, not a replacement.

**Non-goals:** replacing Claude Code, touching reviewer / qa / driver, changing `.env` structure (USER handles that), removing anything.

## Shape of the experiment

Keep it a **parallel track** — separate image, separate worker script, new `--runtime=hermes` flag on `hivectl fire`. The existing Claude flow stays untouched. If Hermes is bad, delete one image tag and one script.

| Piece | Claude (today) | Hermes (proposed) |
|---|---|---|
| Image tag | `coding-agent:dev-<ts>` | `hermes-agent:dev-<ts>` |
| Worker script | `worker/agent.sh` | `worker/hermes-agent.sh` (new) |
| Auth | Claude OAuth (`credentials.json`) | `OPENROUTER_API_KEY` env |
| Headless invocation | `claude -p "$msg" --model … --max-budget-usd` | UNKNOWN — likely `hermes chat -p` or stdin pipe |
| Cost cap | native `--max-budget-usd` | UNKNOWN — may need to wrap & kill |
| Output for METRICS | `--output-format stream-json` (final summary line) | UNKNOWN — may need to parse last line / hit OpenRouter usage API |
| Hammer loop | yes, 3-8 attempts | mirror it — same `RESULT: SUCCEEDED` marker |
| Git / GH / Linear plumbing | unchanged | unchanged |
| Fire surface | `hivectl fire ANU-N --type=research` | `hivectl fire ANU-N --type=research --runtime=hermes` |

## Six unknowns to resolve BEFORE writing code

Each takes one local command to answer:

1. **Install path.** `pip install hermes-agent`? `npx`? Source build? → `docker run --rm -it python:3.12 bash` then try.
2. **Headless mode.** Does `hermes` accept a one-shot prompt and exit, or only `chat`/`--tui`? → `hermes --help` after step 1.
3. **Prompt input.** Arg, stdin, or file? → same `--help`.
4. **Output format.** Is there JSON streaming with cost + tokens + model per turn? → run a tiny prompt, inspect stdout.
5. **Cost cap.** Native flag, or wrap with a watchdog that kills the process at $X? → `hermes chat --help` for budget flag.
6. **Repo context.** Does Hermes auto-load files in cwd, or do we need `--workspace .` / similar? → docs or test run.

USER should run steps 1+2 locally and paste output, OR explicitly authorise me to docker-run the install in a throwaway container to discover it.

## The memory question — actually load-bearing

Hermes' headline feature is persistent memory + self-distilled skills. But worker pods have `emptyDir` workspaces that die when the pod exits. **Out of the box, a Hermes pod gets all the cost of Hermes with none of the memory benefit** — it's just OpenRouter-routed Claude with weirder tooling.

| Approach | Effort | What you give up |
|---|---|---|
| **A. Ephemeral (do nothing)** | 0 | Memory. Hermes is a fancier Claude Code with cheaper model routing. |
| **B. PVC for `~/.hermes/`** | Small — one PVC, one volumeMount in `02-sandbox.yaml`. Single-attach: only one Hermes pod runs at a time. | Parallelism. |
| **C. Shared Postgres memory store** | Medium — reuse chain-monitor Postgres or stand up a second one, point Hermes config at it, handle concurrent writes. | Time. Cross-ticket memory may leak context (ANU-7 learns from ANU-3 — usually good, sometimes weird). |

**Recommendation:** start with **A** for the very first fire to confirm the binary works end-to-end. Move to **B** as soon as it's decided worth keeping. Skip **C** until ≥3 Hermes fires have landed successfully.

## Minimal experimental fire — what would actually change

Once the six unknowns are answered:

1. **New Dockerfile** `worker/Dockerfile.hermes` — base `python:3.12-slim`, install `hermes-agent`, install `git`/`gh`/`jq`, copy `entrypoint.sh` + `hermes-agent.sh`. Lives next to existing `Dockerfile`, doesn't touch it.
2. **New `worker/hermes-agent.sh`** — mirrors `agent.sh`'s clone → loop → push → PR → METRICS flow but calls `hermes` instead of `claude`. Same `RESULT: SUCCEEDED` markers. Same Linear / Telegram plumbing.
3. **`run.sh` dispatch** — if `RUNTIME=hermes`, use `hermes-agent:dev-<ts>` image and set `ENTRY=hermes-agent.sh`. Default stays `claude`. No effect on existing fires.
4. **`hivectl fire` flag** — `--runtime=claude|hermes` (default `claude`).
5. **`.env` addition** *(USER does this)* — `OPENROUTER_API_KEY=sk-or-...`. Single new var.
6. **METRICS line** — same JSON shape, plus `runtime: "hermes"` field. Goes through the same pushgateway / aggregator unchanged.

**No changes** to: `02-sandbox.yaml` (unless going path B), reviewer flow, qa flow, driver flow, metrics aggregator, UI.

## Success criteria

Fire 5 research tickets on Claude (Sonnet, the research default) and 5 on Hermes (default model via OpenRouter). Compare:

- `cost_usd` per fire — Hermes should be cheaper if it routes to haiku/DeepSeek
- `wall_s` — likely worse on Hermes (extra orchestration overhead)
- **PR quality** — eyeball it. This is the only metric that matters; cost/time are noise if PRs are bad.
- `hammers_used` — convergence rate. Higher = wandering.

5 tickets is enough to spot a 2× cost win or a 50% quality drop. Not enough for anything subtler.

## Open questions for USER

1. **Confirm scope** — A-only experiment (ephemeral, just prove it boots), or A→B (also wire the PVC so memory actually matters)?
2. **Run `hermes --help` and `hermes chat --help` locally** and paste output, OR authorise docker-run install in a throwaway container.
3. **OpenRouter key** — already have one, or new sign-up?

## Epistemic caveat

The OpenRouter "Hermes integration cookbook" page returned a lot of "Not documented" blanks for things a real official cookbook would specify (install command, headless `-p` mode, stdout format, cost cap flag). That's either an early docs page or possibly AI-generated SEO content describing a tool whose surface isn't quite real yet. Do NOT commit to any code path that depends on Hermes specifics until `hermes --help` has been run on a real install.

## Risks

- **Hermes turns out to be vapourware / pre-alpha.** Mitigation: epistemic caveat above. Don't sink time before the binary is verified.
- **Hermes' headless mode doesn't exist.** Then this whole plan is dead — Hermes is only an interactive TUI tool, can't run in a one-shot pod. Fail fast in unknown #2.
- **OpenRouter cost cap doesn't propagate.** Mitigation: wrap with a watchdog that polls OpenRouter usage API every 30s and kills the pod if over.
- **Memory benefit never materialises** (we stay on path A). Then Hermes is just OpenRouter-routed Claude with worse tooling — kill the experiment.
- **Image bloat.** Two worker images mean longer rebuilds and more disk in Docker Desktop. Tolerable for an experiment.

## Decision log

- 2026-06-07: USER asked for plan, no code. Drafted. Awaiting answers on three open questions before any implementation.
