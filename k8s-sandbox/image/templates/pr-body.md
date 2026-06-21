<!-- hive pr-body template — rendered by k8s-sandbox/image/agent.sh -->
<!-- DO NOT edit the metadata footer; downstream tooling parses it. -->

## What changed

${COMMIT_BODY}

## Closes

Closes #${ISSUE_NUMBER} — ${ISSUE_TITLE}

## How this PR was graded

- The worker ran an independent in-pod review against the issue's
  `## Definition of Done` and `## Plan` — see the `**coding-agent review**`
  comment below for the DoD verdict. Its verdict (PASS / CHANGES_REQUESTED)
  gates the merge.
- A human can re-grade the same way: verify each DoD line against this diff,
  and flag anything that exceeds the `## Plan` scope.

<details><summary>Agent run metadata</summary>

| field | value |
|---|---|
| agent chatid | `${CHATID}` |
| role | `${ROLE}` |
| task type | `${TASK_TYPE}` |
| model | `${MODEL}` |
| hammers | `${HAMMERS_USED}` / `${HAMMER_MAX}` |
| cost (USD) | `${COST_USD}` |
| branch | `${BRANCH}` |
| base branch | `${BASE_BRANCH}` |
| issue | [#${ISSUE_NUMBER}](${ISSUE_URL}) |
| hive | `${HIVE_VERSION}` |

</details>
