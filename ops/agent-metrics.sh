#!/usr/bin/env bash
set -euo pipefail
# Aggregate per-run METRICS lines from <project>/.hive/runs/<issue-N>-<ts>/run.log
# (default $HOME/.hive/.agents/...) into a table for cost/token/time justification.
#
#   ./ops/agent-metrics.sh               # all runs (newest first)
#   ./ops/agent-metrics.sh issue-7       # only issue-7 runs (prefix match)
#   ./ops/agent-metrics.sh --json        # raw JSON lines, one per run
#   ./ops/agent-metrics.sh --write-jsonl # rebuild $AGENTS_DIR/all.jsonl and exit

HIVE_STATE_DIR="${HIVE_STATE_DIR:-${HIVE_STATE_DIR:-$HOME/.hive}}"
AGENTS_DIR="${HIVE_AGENTS_DIR:-$HIVE_STATE_DIR/.agents}"

[ -d "$AGENTS_DIR" ] || { echo "(no runs at $AGENTS_DIR)"; exit 0; }

FILTER="${1:-}"
JSON=0
WRITE_JSONL=0
case "$FILTER" in
  --json)         JSON=1; FILTER="" ;;
  --write-jsonl)  WRITE_JSONL=1; FILTER="" ;;
  -h|--help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

# Collect one METRICS json per run dir, augmented with run dir, start ts,
# last status (SUCCEEDED|NEEDS_HUMAN|FAILED|RUNNING), and the run.log path.
# The UI consumes these fields.
collect() {
  for d in "$AGENTS_DIR"/*/; do
    name="$(basename "$d")"
    [ -n "$FILTER" ] && [[ "$name" != "$FILTER"* ]] && continue
    log="$d/run.log"
    [ -f "$log" ] || continue
    m=$(grep -E '^METRICS: ' "$log" 2>/dev/null | tail -1 | sed 's/^METRICS: //' || true)
    [ -n "$m" ] || continue
    ts="${name##*-}"   # trailing unix-ts on the dir name
    status=$(grep -E '^STATUS: ' "$log" 2>/dev/null | tail -1 | sed -E 's/^STATUS: ([A-Z_]+).*/\1/' || true)
    [ -n "$status" ] || status="RUNNING"
    pr_url=$(grep -Eo 'https://github\.com/[^ ]*/pull/[0-9]+' "$log" 2>/dev/null | tail -1 || true)
    echo "$m" | jq -c \
      --arg run "$name" --arg ts "$ts" --arg status "$status" \
      --arg log "$log" --arg pr "$pr_url" \
      '. + {run:$run, start_ts:($ts|tonumber), status:$status, log_path:$log, pr_url:$pr}'
  done
}

if [ "$WRITE_JSONL" = 1 ]; then
  out="$AGENTS_DIR/all.jsonl"
  tmp="$out.tmp"
  collect | jq -cs 'sort_by(-.start_ts)[]' > "$tmp"
  mv "$tmp" "$out"
  n=$(wc -l < "$out" | tr -d ' ')
  echo "wrote $out ($n run(s))"
  exit 0
fi

if [ "$JSON" = 1 ]; then
  collect
  exit 0
fi

rows=$(collect)
if [ -z "$rows" ]; then
  echo "(no METRICS lines found in $AGENTS_DIR)"; exit 0
fi

# Pretty table. Newest first.
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    ISSUE TYPE COST_USD WALL_S TURNS IN_TOK OUT_TOK CACHE_R
  echo "$rows" | jq -rs 'sort_by(-.start_ts)[] |
    [.issue_id, .task_type, (.cost_usd|tostring), (.wall_s|tostring),
     (.num_turns|tostring), (.input_tokens|tostring),
     (.output_tokens|tostring), (.cache_read|tostring)] | @tsv'
} | column -t -s $'\t'

# Totals row.
echo
echo "$rows" | jq -rs \
  'reduce .[] as $r ({c:0,w:0,t:0,i:0,o:0,cr:0,cw:0,n:0};
     .c+=$r.cost_usd | .w+=$r.wall_s | .t+=$r.num_turns
     | .i+=$r.input_tokens | .o+=$r.output_tokens
     | .cr+=$r.cache_read | .cw+=$r.cache_creation | .n+=1) |
   "totals: \(.n) runs   $\(.c|tostring|.[0:8])   wall=\(.w)s   turns=\(.t)   in=\(.i)   out=\(.o)   cache_r=\(.cr)   cache_w=\(.cw)"'
