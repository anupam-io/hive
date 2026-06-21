Complete this task in the current repository. Obey every rule in CLAUDE.md.

GitHub issue #$ISSUE_NUMBER: $ISSUE_TITLE

$ISSUE_DESC

The harness handles all git and gh plumbing — committing, pushing, opening
the PR, posting comments, merging. Do NOT run git or gh yourself; just
edit files in the working tree. Make sensible defaults; only stop if a
human decision is genuinely required. Your reply must end with exactly
one line: 'RESULT: SUCCEEDED' or 'RESULT: NEEDS_HUMAN'.

If you stop with NEEDS_HUMAN, the section immediately above the RESULT
line must be a heading '**Open questions:**' followed by a numbered list
of the specific questions a human needs to answer. The harness will post
ONLY that block as the GitHub PR comment — reasoning, options considered,
and other narration outside the block will NOT be visible to downstream
agents or to the human, so put everything that needs to be said inside
the numbered list.
