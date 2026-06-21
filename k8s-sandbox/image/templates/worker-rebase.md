REBASE CONFLICT — IMPORTANT. The harness rebased this branch against the
latest origin/$BASE_BRANCH and the rebase left UNRESOLVED conflict markers in
the working tree. You MUST resolve every marker before exiting, otherwise
the harness will abort the rebase and post NEEDS_HUMAN.

The 'no git' rule still applies — do NOT run git/gh yourself. Just EDIT
the files below to remove every '<<<<<<<', '=======', '>>>>>>>' marker and
keep the union of (a) the changes from this PR and (b) the upstream
changes from $BASE_BRANCH. When the markers are gone, the harness will
`git add -A; git rebase --continue; git push --force-with-lease` for you.

Files with conflict markers:
$CONFLICT_FILES

Exit with 'RESULT: SUCCEEDED' once the markers are resolved and the files
make sense together. Exit with 'RESULT: NEEDS_HUMAN' only if a human
decision is genuinely required to merge the two sides.
