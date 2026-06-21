---
name: hive-bug-fix
description: Systematic stages for fixing a bug on a GitHub issue — explore, understand the code, reproduce and confirm the bug, fix the root cause (not the symptom), test, then leave the tree compiling and lint-clean. Follow these stages in order for any bug-fix fire.
---

# Bug fix — systematic stages

Work these stages in order. The defining discipline of a bug fix is to
*reproduce and confirm* before changing anything, and to fix the root cause
rather than paper over a symptom.

## 1. Explore
Map the part of the project the bug lives in. Find the entry points, the modules
involved, and the code path the report implicates. Read before you write.

## 2. Understand the existing implementation
Trace how the affected code is supposed to work. Identify the invariant or
assumption that is being violated. Note the surrounding patterns and types.

## 3. Confirm the bug
Reproduce it. Write or run a test, a command, or a minimal case that
demonstrates the wrong behaviour, so you have proof of the defect *before* the
fix and proof of the cure *after*. If you cannot reproduce it, say so in
`RESULT: NEEDS_HUMAN` rather than guessing.

## 4. Fix the root cause
Change the actual cause, not the symptom. Keep the diff minimal and scoped to
the bug — do not fold in unrelated refactors. Match the surrounding conventions.

## 5. Test and confirm
Show the reproduction now passes, and that you have not regressed nearby
behaviour. Add a regression test where the repo supports it. Every
Definition-of-Done line must be verifiably true.

## 6. Compile and lint
Leave the working tree building and lint-clean — run the project's
build/typecheck/lint/format steps and fix what you broke. A red tree is not done.

## 7. Write the brief
With the work done and the tree green, fill `/opt/hive/templates/bug-fix-brief.md`
and output the filled brief wrapped exactly between a `<!--HIVE_BRIEF-->` line and
a `<!--/HIVE_BRIEF-->` line, placed immediately before your `RESULT:` line. The
harness posts what's between those markers to the PR for the reviewer and the
human; anything outside them is not posted.

An independent self-review and a separate reviewer both check that the diff
reflects these stages, so the work has to genuinely follow them, not just claim to.
