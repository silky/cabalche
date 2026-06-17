#!/usr/bin/env bash
# Summarise the link-output cache hit/miss telemetry recorded by
# Distribution.Simple.GHC.LinkManifest into .stats.jsonl.
#
# Usage:
#   scripts/link-cache-summary.sh [STATS_FILE]
#
# Default path: $CABAL_LINK_CACHE_DIR/.stats.jsonl, falling back to
# $XDG_CACHE_HOME/cabal/link-cache/.stats.jsonl (or ~/.cache/...).
#
# Estimated saved time per tool is computed as
#
#     hits * mean(miss ms) - sum(hit ms)
#
# i.e. how much wall-clock would have been spent re-linking on the
# hits if the cache had been absent, minus the actual time spent
# servicing those hits from the cache. Coarse but useful.

set -euo pipefail

if [[ -n "${1:-}" ]]; then
  STATS="$1"
elif [[ -n "${CABAL_LINK_CACHE_DIR:-}" ]]; then
  STATS="$CABAL_LINK_CACHE_DIR/.stats.jsonl"
else
  base="${XDG_CACHE_HOME:-$HOME/.cache}"
  STATS="$base/cabal/link-cache/.stats.jsonl"
fi

if [[ ! -r "$STATS" ]]; then
  echo "no stats file at $STATS" >&2
  echo "(set CABAL_LINK_CACHE_DIR or pass the path as an argument)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not in PATH" >&2
  exit 1
fi

records=$(wc -l < "$STATS" | tr -d ' ')
if [[ "$records" -eq 0 ]]; then
  echo "$STATS is empty -- nothing to summarise" >&2
  exit 0
fi

echo "Link-output cache telemetry: $STATS"
echo "Records: $records"
echo

jq -rs '
{
  n:        length,
  hits:     [ .[] | select(.outcome=="hit") ]            | length,
  nocopy:   [ .[] | select(.outcome=="hit-nocopy") ]     | length,
  verified: [ .[] | select(.outcome=="hit-verified") ]   | length,
  diverged: [ .[] | select(.outcome=="hit-diverged") ]   | length,
  misses:   [ .[] | select(.outcome=="miss") ]           | length,
  disabled: [ .[] | select(.outcome=="disabled") ]       | length
} as $o |
def pct(num): if $o.n == 0 then "0%" else
  ((num * 1000 / $o.n | floor) | tostring) as $tenths |
  (((num * 1000 / $o.n | floor) / 10) | tostring + "%") end;
"  hit          : \($o.hits)\n"   +
"  hit-nocopy   : \($o.nocopy)\n" +
"  hit-verified : \($o.verified)\n" +
"  hit-diverged : \($o.diverged)\n" +
"  miss         : \($o.misses)\n" +
"  disabled     : \($o.disabled)\n" +
"  hit rate     : \(pct($o.hits + $o.nocopy + $o.verified))"
' "$STATS"

echo
echo "Per-tool (sorted by estimated saved seconds):"
(
  printf "tool\tcalls\thits\tmisses\tavg_miss_ms\tsaved_s\n"
  jq -rs '
group_by(.tool) | map({
  tool: .[0].tool,
  n: length,
  hits:    ([ .[] | select(.outcome | startswith("hit")) ] | length),
  misses:  ([ .[] | select(.outcome == "miss") ]           | length),
  avg_miss_ms: ([ .[] | select(.outcome=="miss") | .ms ] |
                 if length == 0 then 0 else ((add / length) | floor) end),
  total_hit_ms: ([ .[] | select(.outcome | startswith("hit")) | .ms ] | add // 0)
}) |
map(.saved_ms = (.hits * .avg_miss_ms - .total_hit_ms)) |
sort_by(- .saved_ms) |
.[] | "\(.tool)\t\(.n)\t\(.hits)\t\(.misses)\t\(.avg_miss_ms)\t\((.saved_ms / 1000) | (. * 100 | floor) / 100)"
' "$STATS"
) | column -t -s $'\t'
