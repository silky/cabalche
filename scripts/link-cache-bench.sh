#!/usr/bin/env bash
# Benchmark the link-output cache on a target project.
#
# Runs the project's link step under four conditions and prints a
# table. The interesting comparisons are:
#
#   forced-relink-no-cache  vs  forced-relink-warm-cache
#       --> wall-clock saved when the cache hits
#
#   clean-build-no-cache    vs  clean-build-no-cache (repeat)
#       --> noise floor / measurement variance
#
# The "forced relink" condition deletes link outputs (.a, .so, exe)
# but keeps .o/.hi files, so GHC re-emits byte-identical objects and
# the link step is the only thing that has to run.
#
# Usage:
#   scripts/link-cache-bench.sh <project-dir> \
#       [--cabal=PATH] [--bench-iters=N] [--target=TARGET]
#
# --target defaults to "all"; pass a specific component name for
# multi-package projects (e.g. "hydra-node" to focus on one exe's
# link cone). Anything that 'cabal build' accepts works.
#
# Outputs the bench table to stdout. Per-link telemetry is collected
# alongside (cache root is isolated) and aggregated via
# scripts/link-cache-summary.sh.

set -euo pipefail

PROJECT=""
CABAL="cabal"
ITERS=3
TARGET="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cabal=*)       CABAL="${1#*=}"; shift ;;
    --bench-iters=*) ITERS="${1#*=}"; shift ;;
    --target=*)      TARGET="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        echo "error: extra positional argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "error: <project-dir> is required" >&2
  echo "usage: $0 <project-dir> [--cabal=PATH] [--bench-iters=N]" >&2
  exit 2
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "error: project dir does not exist: $PROJECT" >&2
  exit 2
fi

PROJECT="$(cd "$PROJECT" && pwd)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

WORK="$(mktemp -d -t link-cache-bench.XXXXXX)"
CACHE_DIR="$WORK/cache"
RESULT_TSV="$WORK/results.tsv"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$CACHE_DIR"
printf 'condition\titer\twall_seconds\n' > "$RESULT_TSV"

run_in_project() {
  ( cd "$PROJECT" && "$@" )
}

# Returns wall-clock seconds (3-decimal). Uses bash's $SECONDS doesn't
# have sub-second resolution; use `date +%s.%N`.
time_cmd() {
  local start end
  start="$(date +%s.%N)"
  "$@"
  end="$(date +%s.%N)"
  awk -v s="$start" -v e="$end" 'BEGIN { printf("%.3f", e - s) }'
}

# Remove link outputs (everything that looks like a library archive or
# an exe) from dist-newstyle. Leaves .o/.hi alone so the link step is
# the only thing that re-runs on the next build.
remove_link_outputs() {
  local root="$PROJECT/dist-newstyle"
  if [[ ! -d "$root" ]]; then
    return
  fi
  find "$root" -type f \
    \( -name '*.a' -o -name '*.so' -o -name '*.dylib' -o -name '*.dll' \
       -o \( -executable ! -name '*.h' ! -name '*.hs' \) \) \
    -print0 2>/dev/null \
    | xargs -0 -r rm -f 2>/dev/null || true
}

run_iteration() {
  local condition="$1" iter="$2"
  local -a env_overrides=()
  case "$condition" in
    clean-no-cache)
      env_overrides=( "CABAL_LINK_CACHE_DISABLE=1" )
      run_in_project "$CABAL" clean >/dev/null 2>&1 || true
      ;;
    relink-no-cache)
      env_overrides=( "CABAL_LINK_CACHE_DISABLE=1" )
      remove_link_outputs
      ;;
    clean-cold-cache)
      env_overrides=( "CABAL_LINK_CACHE_DIR=$CACHE_DIR" )
      run_in_project "$CABAL" clean >/dev/null 2>&1 || true
      ;;
    relink-warm-cache)
      env_overrides=( "CABAL_LINK_CACHE_DIR=$CACHE_DIR" )
      remove_link_outputs
      ;;
    *)
      echo "error: unknown condition $condition" >&2
      return 2
      ;;
  esac

  local seconds
  seconds="$(time_cmd env "${env_overrides[@]}" \
              bash -c "cd '$PROJECT' && '$CABAL' build '$TARGET' >/dev/null 2>&1")"
  printf '%s\t%s\t%s\n' "$condition" "$iter" "$seconds" >> "$RESULT_TSV"
}

# Warmup: ensure deps are built so we don't measure dep installation.
echo ">>> warmup build (excluded from results)"
run_in_project "$CABAL" build "$TARGET" >/dev/null 2>&1 || true

# Populate the warm cache before measuring the relink-warm conditions.
echo ">>> populating cache"
env "CABAL_LINK_CACHE_DIR=$CACHE_DIR" \
  bash -c "cd '$PROJECT' && '$CABAL' build '$TARGET' >/dev/null 2>&1" || true

for i in $(seq 1 "$ITERS"); do
  echo ">>> iteration $i / $ITERS"
  for cond in clean-no-cache relink-no-cache clean-cold-cache relink-warm-cache; do
    echo "    $cond ..."
    run_iteration "$cond" "$i"
  done
done

echo
echo "=== raw results ==="
column -t -s $'\t' "$RESULT_TSV"

echo
echo "=== aggregated (median of $ITERS iterations) ==="
awk -F'\t' '
NR == 1 { next }
{ vals[$1, ++n[$1]] = $3 }
END {
  for (c in n) {
    cnt = n[c]
    # gather sorted values
    for (i = 1; i <= cnt; i++) a[i] = vals[c, i]
    asort(a)
    mid = int((cnt + 1) / 2)
    printf("%s\tmedian=%.3fs\tn=%d\n", c, a[mid], cnt)
  }
}
' "$RESULT_TSV" | sort | column -t -s $'\t'

echo
if command -v jq >/dev/null 2>&1; then
  echo "=== link-cache telemetry summary ==="
  CABAL_LINK_CACHE_DIR="$CACHE_DIR" "$REPO/scripts/link-cache-summary.sh" \
    "$CACHE_DIR/.stats.jsonl" || true
else
  echo "(install jq to see per-link telemetry)"
fi

# Compute the headline speedup.
echo
echo "=== speedup: relink-no-cache vs relink-warm-cache ==="
awk -F'\t' '
NR == 1 { next }
$1 == "relink-no-cache"   { off += $3; offN += 1 }
$1 == "relink-warm-cache" { on  += $3; onN  += 1 }
END {
  if (offN == 0 || onN == 0) {
    print "  (not enough samples)"
    exit
  }
  offMean = off / offN
  onMean  = on  / onN
  printf("  cache off : mean %.3fs (n=%d)\n", offMean, offN)
  printf("  cache on  : mean %.3fs (n=%d)\n", onMean,  onN)
  if (offMean > 0) {
    printf("  speedup   : %.1f%% (%.3fs saved per build)\n",
           (offMean - onMean) * 100 / offMean,
           offMean - onMean)
  }
}
' "$RESULT_TSV"
