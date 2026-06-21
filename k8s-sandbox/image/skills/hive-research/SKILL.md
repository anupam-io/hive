---
name: hive-research
description: hive's systematic stages for a research fire on a GitHub issue — assess feasibility, map integrations, pin down data formats and APIs, separate what's proven from what's theoretical, and produce a findings document (not code). Follow these stages for any research fire, alongside any app-specific research skill this repo ships.
---

# hive research — systematic stages

A research fire produces a **findings document**, not a feature. The deliverable
is a clear, honest write-up a human can act on — not working code.

## 1. Feasibility
State whether the thing the issue asks about is actually implementable here, and
at what cost. Lead with the answer, then the evidence.

## 2. Integrations
Identify what this would have to touch — existing modules, external services,
APIs, auth. Note what already exists to build on versus what is missing.

## 3. Data formats & config
Pin down the concrete shapes: request/response formats, schemas, the config or
credentials required, rate limits. Quote real examples where you found them.

## 4. Exploration (APIs / surfaces)
Where an API or surface is involved, explore it concretely — endpoints, fields,
auth, quirks — rather than describing it in the abstract.

## 5. Proven vs theoretical
Separate what you VERIFIED (ran, read, confirmed) from what you are inferring.
Mark assumptions explicitly. Do not present a guess as a finding.

## 6. Write the findings
Produce a single findings document with: the bottom-line answer, the evidence
per stage above, open questions, and a recommendation. Cite sources (files,
URLs, endpoints). If a decision is genuinely blocked on a human, stop with
`RESULT: NEEDS_HUMAN` and list the questions.

## 7. Write the brief
With the findings written, fill `/opt/hive/templates/research-findings-brief.md`
and output the filled brief wrapped exactly between a `<!--HIVE_BRIEF-->` line and
a `<!--/HIVE_BRIEF-->` line, placed immediately before your `RESULT:` line. The
harness posts what's between those markers to the PR for the reviewer and the
human; anything outside them is not posted.
