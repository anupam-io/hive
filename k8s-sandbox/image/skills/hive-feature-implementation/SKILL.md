---
name: hive-feature-implementation
description: Systematic stages for implementing a feature on a GitHub issue — explore, understand the existing code, follow conventions, implement, test, then leave the tree compiling and lint-clean. Follow these stages in order for any feature-implementation fire.
---

# Feature implementation — systematic stages

Work these stages in order. Do not skip ahead to writing code before you have
explored and understood the area — wrong code is more expensive than reading.

## 1. Explore
Map the part of the project this feature touches. Find the entry points, the
modules involved, the relevant config, and how similar features are wired
today. Read before you write.

## 2. Understand the existing implementation
Look for an existing pattern, helper, or component you can extend or reuse.
Prefer reuse over reinvention. Note the data shapes, interfaces, and naming the
surrounding code already uses.

## 3. Follow best practices
Match the conventions of the code around you — structure, naming, error
handling, types, comment density. The diff should read like the rest of the
repo, not like a transplant.

## 4. Implement the feature
Build exactly what the issue's `## Plan` and `## Definition of Done` describe —
no more. If you discover the Plan is wrong or missing a constraint, stop with
`RESULT: NEEDS_HUMAN` rather than silently expanding scope.

## 5. Test and confirm
Verify the feature actually does what the issue asks. Add or extend tests where
the repo has them; otherwise confirm behaviour the way the project's CLAUDE.md
prescribes. Every Definition-of-Done line must be verifiably true.

## 6. Compile and lint
Leave the working tree building and lint-clean — run the project's
build/typecheck/lint/format steps and fix what you broke. A red tree is not done.

## 7. Write the brief
With the work done and the tree green, fill
`/opt/hive/templates/feature-implementation-brief.md` and output the filled
brief wrapped exactly between a `<!--HIVE_BRIEF-->` line and a `<!--/HIVE_BRIEF-->`
line, placed immediately before your `RESULT:` line. The harness posts what's
between those markers to the PR for the reviewer and the human; anything outside
them is not posted.

An independent self-review and a separate reviewer both check that the diff
reflects these stages, so the work has to genuinely follow them, not just claim to.
