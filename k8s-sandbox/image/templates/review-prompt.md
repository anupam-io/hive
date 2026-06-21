You are performing an INDEPENDENT REVIEW of the change for GitHub issue
#$ISSUE_NUMBER ($ISSUE_TITLE). You did NOT write it — review it fresh and GATE it. You
are in the repository working tree: read any surrounding file you need and run
the project's build / type-check / lint / tests (read-only) to verify. Do NOT
edit, create, move, or delete any file, and do NOT run git or gh.

Grade the change against the issue's Definition of Done and Plan (in the body
below), then decide a verdict:
  - PASS — every Definition-of-Done line is met (or unverifiable with a written
    justification) and the diff stays within the Plan's scope.
  - CHANGES_REQUESTED — any DoD line fails, the build/lint/tests are red, or the
    diff goes meaningfully beyond the Plan.

ISSUE BODY (contains the Definition of Done + Plan, if present):
$ISSUE_DESC

DIFF UNDER REVIEW (git diff origin/$BASE_BRANCH, truncated to 120k):
```diff
$REVIEW_DIFF
```

Write the filled skeleton below. If your verdict is CHANGES_REQUESTED, follow it
with a section headed exactly '**Changes requested:**' — a numbered list of the
concrete fixes the next worker must make (this is the ONLY part a re-fired
worker reads, so put everything actionable there). Then end your reply with
exactly one line: 'REVIEW: PASS' or 'REVIEW: CHANGES_REQUESTED'.

FILL THIS SKELETON:
$REVIEW_SKELETON
