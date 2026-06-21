---
name: hive-improvement
description: Systematic stages for an improvement on a GitHub issue — explore, understand the code, follow conventions, make the targeted improvement without scope creep, test that behaviour is preserved, then leave the tree compiling and lint-clean. Follow these stages in order for any improvement fire.
---

# Improvement — systematic stages

Work these stages in order. The defining discipline of an improvement is to
make the targeted change *without scope creep* and *without altering behaviour*
unless the issue says to.

## 1. Explore
Map the part of the project the improvement touches. Find the modules involved
and how they are used elsewhere, so a change here does not break a caller there.
Read before you write.

## 2. Understand the existing implementation
Understand why the current code is the way it is before changing it — comments
and structure hold intent you may lack. Identify exactly what the improvement
should and should not affect.

## 3. Follow best practices
Match the conventions of the code around you — structure, naming, error
handling, types, comment density. The diff should read like the rest of the repo.

## 4. Make the improvement
Make the targeted change the issue's `## Plan` describes — no more. Resist
folding in adjacent cleanups; one concern per fire. If the Plan is wrong or
ambiguous, stop with `RESULT: NEEDS_HUMAN`.

## 5. Test and confirm
Confirm existing behaviour is preserved (unless the issue intends to change it)
and that the improvement is real. Lean on the repo's tests; add coverage where
it makes sense. Every Definition-of-Done line must be verifiably true.

## 6. Compile and lint
Leave the working tree building and lint-clean — run the project's
build/typecheck/lint/format steps and fix what you broke. A red tree is not done.

## 7. Write the brief
With the work done and the tree green, fill
`/opt/hive/templates/improvement-brief.md` and output the filled brief wrapped
exactly between a `<!--HIVE_BRIEF-->` line and a `<!--/HIVE_BRIEF-->` line, placed
immediately before your `RESULT:` line. The harness posts what's between those
markers to the PR for the reviewer and the human; anything outside them is not
posted.

An independent self-review and a separate reviewer both check that the diff
reflects these stages, so the work has to genuinely follow them, not just claim to.
