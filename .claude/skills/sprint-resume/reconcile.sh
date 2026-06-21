#!/bin/bash
# Reconcile the TRUE state of an in-progress sprint from the three DURABLE
# sources — GitHub issue labels, GitHub PRs, and live pods — so a resuming
# driver never re-fires work that's already in flight. Read-only: prints a
# per-issue classification table. The labels lag reality, so pods + PRs win.
#
# Usage: APP=<app> bash reconcile.sh <sprint-label>
#   e.g. APP=chain-monitor bash reconcile.sh sprint-3
# Env: NS (default "agents").
#
# Verdicts — the Iron Law: never re-fire an issue that is IN-FLIGHT or has an open PR.
# The PR gate is the worker's IN-POD review, surfaced as the issue status label
# (the worker sets status:in-review on review PASS, status:changes-requested on
# CHANGES_REQUESTED). GitHub reviewDecision stays empty — never key off it.
#   DONE       issue done / PR merged                       -> nothing
#   SHIP       open PR, status:in-review (review PASS)       -> driver merges (Action A)
#   REFIRE-REV open PR, status:changes-requested            -> re-fire worker to fix (Action B)
#   REVIEW     open PR, review not yet returned             -> WAIT for the in-pod review
#   IN-FLIGHT  live pod, no PR yet                           -> WAIT, do NOT re-fire
#   BLOCKED    status:needs-human                            -> driver NEEDS_HUMAN play / human
#   REFIRE     no pod, no PR, status not ready               -> pod died mid-flight; safe to re-fire
#   FIREABLE   no pod, no PR, status:ready                   -> fire when its wave's deps are done
set -u
SPRINT="${1:?usage: APP=<app> reconcile.sh <sprint-label>}"
APP="${APP:?APP=<app> required}"
NS="${NS:-agents}"

issues=$(gh issue list --label "$SPRINT" --state all --limit 300 --json number,labels)
prs=$(gh pr list --label "$SPRINT" --state all --limit 300 --json number,headRefName,state)
# issue numbers with a NON-terminal pod. Pods carry label issue_id="issue-<N>".
live=$(kubectl -n "$NS" get pods -l "app=$APP,app.kubernetes.io/name=coding-agent" \
  -o jsonpath='{range .items[*]}{.metadata.labels.issue_id}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="Succeeded" && $2!="Failed" && $1!="" {sub(/^issue-/,"",$1); print $1}' | sort -u)

is_live(){ printf "%s\n" "$live" | grep -qx "$1"; }

printf "%-7s %-14s %-6s %-20s %s\n" "issue" "status" "pod" "pr" "verdict"
printf -- "---------------------------------------------------------------------\n"

echo "$issues" | jq -r '.[] | "\(.number)\t\([.labels[].name | select(startswith("status:"))][0] // "status:none")"' \
 | while IFS=$'\t' read -r num status; do
    pr=$(echo "$prs" | jq -r --arg b "agent/issue-$num" --arg b2 "agent/$num" '.[] | select(.headRefName==$b or .headRefName==$b2) | "\(.state)"' | head -1)
    pstate=$(echo "$pr" | awk '{print $1}')
    pod="no"; is_live "$num" && pod="LIVE"
    if   [ "$pstate" = "MERGED" ] || [ "$status" = "status:done" ];      then v="DONE"
    elif [ "$pstate" = "OPEN" ] && [ "$status" = "status:in-review" ];   then v="SHIP"
    elif [ "$status" = "status:changes-requested" ];                    then v="REFIRE-REV"
    elif [ "$pstate" = "OPEN" ];                                         then v="REVIEW"
    elif [ "$pod" = "LIVE" ];                                            then v="IN-FLIGHT"
    elif [ "$status" = "status:needs-human" ];                          then v="BLOCKED"
    elif [ "$status" = "status:ready" ];                                then v="FIREABLE"
    else                                                                     v="REFIRE"; fi
    printf "%-7s %-14s %-6s %-20s %s\n" "$num" "${status#status:}" "$pod" "${pstate:-none}" "$v"
 done
