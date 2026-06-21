NOTE: branch '$BRANCH' already has PR $EXISTING_PR_URL. BEFORE doing any
other work, run `gh pr view $EXISTING_PR_URL --json comments,reviews` and
read every comment / review submitted AFTER the most recent bot commit on
this branch. Filter what you read:
  - Ignore any comment whose body starts with `**coding-agent run**` or
    `**coding-agent (` — those are bot status posts, not human input.
  - Inside a `**coding-agent review**` comment, treat ONLY the
    `**Changes requested:**` block (numbered list) as relevant — those are the
    gating review's required fixes you MUST address. Ignore the rest.
  - Inside any other bot-authored comment, treat ONLY a `**Open questions:**`
    block (numbered list) as relevant. Everything else in such comments is
    another agent's reasoning trail and must be ignored.
  - Human comments are always relevant in full.
Address each relevant item (edit code to answer it, or reply with
`gh pr comment $EXISTING_PR_URL -b "<reply>"` if no code change is
needed). Only then continue with the original task.
