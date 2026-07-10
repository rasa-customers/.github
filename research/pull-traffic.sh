#!/usr/bin/env bash
#
# pull-traffic.sh — snapshot clone & view traffic for every repo in a GitHub org.
#
# GitHub's traffic API only retains the LAST 14 DAYS of clone/view data and
# discards anything older, so this script exists to capture point-in-time
# snapshots you can archive and later stack together.
#
# Output: research/<org>-traffic-YYYY-MM-DD.csv (one row per repo), with the
# collection date and the actual 14-day window (read from the API, not assumed)
# recorded on every row.
#
# Requirements:
#   - gh (GitHub CLI), authenticated with a token that has `repo` + `read:org`.
#     Traffic endpoints require push access to each repo, so run as a member
#     with sufficient permissions or the counts come back empty.
#   - jq
#
# Usage:
#   ./research/pull-traffic.sh                # defaults to rasa-customers
#   ./research/pull-traffic.sh some-other-org
#
set -euo pipefail

ORG="${1:-rasa-customers}"
PARALLEL="${PARALLEL:-12}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTED="$(date +%F)"
OUT_CSV="$OUT_DIR/${ORG}-traffic-${COLLECTED}.csv"

command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Listing repos in '$ORG'..." >&2
# visibility <tab> archived <tab> name
gh api --paginate "/orgs/${ORG}/repos?per_page=100&type=all" \
  --jq '.[] | [.visibility, .archived, .name] | @tsv' > "$WORK/repos.tsv"
REPO_COUNT=$(wc -l < "$WORK/repos.tsv" | tr -d ' ')
echo "Found $REPO_COUNT repos. Fetching traffic (parallel=$PARALLEL)..." >&2

# Per-repo fetcher: prints "name<tab>count<tab>uniques" for the given metric.
# Missing access / errors yield zeros so one bad repo never aborts the run.
fetch_metric() {
  local name="$1" metric="$2"
  local resp
  if resp=$(gh api "/repos/${ORG}/${name}/traffic/${metric}" 2>/dev/null); then
    echo "$resp" | jq -r --arg n "$name" '[$n, (.count // 0), (.uniques // 0)] | @tsv'
  else
    printf '%s\t0\t0\n' "$name"
  fi
}
export -f fetch_metric
export ORG

cut -f3 "$WORK/repos.tsv" | xargs -P "$PARALLEL" -I {} bash -c 'fetch_metric "$1" clones' _ {} \
  | sort -t$'\t' -k1,1 > "$WORK/clones.tsv"
cut -f3 "$WORK/repos.tsv" | xargs -P "$PARALLEL" -I {} bash -c 'fetch_metric "$1" views' _ {} \
  | sort -t$'\t' -k1,1 > "$WORK/views.tsv"

# Determine the real 14-day window from any repo's clone payload.
FIRST_REPO=$(head -1 "$WORK/repos.tsv" | cut -f3)
WINDOW=$(gh api "/repos/${ORG}/${FIRST_REPO}/traffic/clones" \
  --jq '(.clones[0].timestamp[0:10]) + "," + (.clones[-1].timestamp[0:10])' 2>/dev/null || echo ",")
WSTART="${WINDOW%,*}"; WEND="${WINDOW#*,}"

# Join: clones + views by name, then attach visibility/archived; sort by clones desc, views desc.
join -t$'\t' -1 1 -2 1 "$WORK/clones.tsv" "$WORK/views.tsv" > "$WORK/traffic.tsv"  # name c_cnt c_uniq v_cnt v_uniq

{
  echo "collected_on,window_start,window_end,repo,visibility,archived,clones_14d,clone_uniques_14d,views_14d,view_uniques_14d"
  join -t$'\t' -1 3 -2 1 \
    <(sort -t$'\t' -k3,3 "$WORK/repos.tsv") \
    "$WORK/traffic.tsv" \
    | awk -v c="$COLLECTED" -v s="$WSTART" -v e="$WEND" -F'\t' 'BEGIN{OFS=","}
        {print c, s, e, $1, $2, $3, $4, $5, $6, $7}' \
    | sort -t, -k7,7nr -k9,9nr
} > "$OUT_CSV"

TOTAL_CLONES=$(tail -n +2 "$OUT_CSV" | awk -F, '{s+=$7} END{print s+0}')
TOTAL_VIEWS=$(tail -n +2 "$OUT_CSV" | awk -F, '{s+=$9} END{print s+0}')
echo "Wrote $OUT_CSV" >&2
echo "  repos=$REPO_COUNT  window=${WSTART}..${WEND}  clones=${TOTAL_CLONES}  views=${TOTAL_VIEWS}" >&2
