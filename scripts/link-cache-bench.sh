#!/usr/bin/env bash
# Benchmark the link-output cache on a target project.
#
# Methodology: perturb a source file in the dep cone (rewrite a
# trailing marker comment line), then build. Cabal v3 does not
# check whether link outputs (.a / .so / exe) exist on disk before
# deciding to skip a build -- built-state is tracked through the
# package db and per-component cache files, so deleting an .a
# between builds does not trigger a relink. Cabal v3 ALSO
# content-hashes source files (via Distribution.Client.FileMonitor's
# MonitorFileHashed), so a plain `touch -mtime` does not invalidate
# anything either -- cabal sees the bytes are unchanged and
# short-circuits the entire rebuild. The bench rewrites a marker
# line to actually mutate the file's bytes, which forces cabal to
# invoke GHC and the link step. The marker is a Haskell line
# comment, so GHC's lexer drops it before parsing -- a content-
# deterministic GHC emits a byte-equal .o for every marker value,
# the lib's link inputs hash to the same cache key, and the
# cascade can HIT the cache.
#
# Conditions per iteration:
#
#   noop-no-cache
#       Plain `cabal build` with no source perturbation. Nothing
#       to do -- cabal just runs plan resolution + filesystem
#       scan. The wall-clock here is the per-build overhead floor
#       that touch-no-cache and touch-warm-cache both inherit.
#
#   touch-no-cache
#       Perturb the file, build with the link cache disabled.
#       Realistic edit-rebuild baseline: cabal recompiles the
#       touched module and re-links the cascade with ar /
#       ghc-link, no caching.
#
#   touch-warm-cache
#       Same perturbation, but with the link cache enabled. If
#       GHC is producing bitwise-identical .o files (i.e. the
#       perturbation is a semantic no-op and GHC is content-
#       deterministic), every relink in the cascade should HIT
#       the cache and skip the underlying ar / ghc-link
#       invocation.
#
# The headline comparison is touch-no-cache vs touch-warm-cache.
# noop-no-cache is the noise-floor reference.
#
# Usage:
#   scripts/link-cache-bench.sh <project-dir> \
#       --touch=PATH \
#       [--cabal=PATH] [--bench-iters=N] [--target=TARGET]
#
# --touch is required: path to a source file (relative to
# <project-dir> or absolute) inside a library transitively
# imported by --target. Pick something low in the dep cone for
# maximum cascade depth -- e.g.
# hydra-prelude/src/Hydra/Prelude.hs for the hydra worktree.
# Prefer a non-Template-Haskell module: TH splices are a known
# source of non-determinism in stock GHC and will manifest as
# unexpected misses.
#
# --target defaults to "all". For multi-package worktrees that
# dilute the signal (hydra, cardano-*), pass a specific component
# (e.g. --target=hydra-node) to focus on one link cone.
#
# Outputs the bench table to stdout, including per-condition HIT
# and MISS counts. Per-link telemetry is collected in an isolated
# cache root and aggregated via scripts/link-cache-summary.sh at
# the end.

set -euo pipefail

PROJECT=""
CABAL="cabal"
ITERS=3
TARGET="all"
TOUCH_FILE=""

# Sentinel string used for the marker comment line we write into
# $TOUCH_FILE. Chosen to be unlikely to collide with anything a
# real Haskell project would contain; the restore_source path
# removes any line starting with this exact prefix.
readonly MARKER="-- LINK_CACHE_BENCH_MARKER"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cabal=*)       CABAL="${1#*=}"; shift ;;
    --bench-iters=*) ITERS="${1#*=}"; shift ;;
    --target=*)      TARGET="${1#*=}"; shift ;;
    --touch=*)       TOUCH_FILE="${1#*=}"; shift ;;
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
  echo "usage: $0 <project-dir> --touch=PATH [--cabal=PATH] [--bench-iters=N] [--target=TARGET]" >&2
  exit 2
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "error: project dir does not exist: $PROJECT" >&2
  exit 2
fi
if [[ -z "$TOUCH_FILE" ]]; then
  echo "error: --touch=PATH is required (a source file in the dep cone of --target)" >&2
  exit 2
fi

PROJECT="$(cd "$PROJECT" && pwd)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve --touch: absolute path stays as-is, relative resolves
# against the project root.
case "$TOUCH_FILE" in
  /*) ;;
  *)  TOUCH_FILE="$PROJECT/$TOUCH_FILE" ;;
esac
if [[ ! -f "$TOUCH_FILE" ]]; then
  echo "error: --touch file does not exist: $TOUCH_FILE" >&2
  exit 2
fi

# Sanity-check the cabal binary up front: if the user accidentally
# fell back to a system cabal that doesn't know about the link cache,
# the env vars below are silently ignored and the bench reports a
# flat "no speedup" identical to a real miss. Printing the resolved
# path and version makes that visible in one glance.
CABAL_RESOLVED="$(command -v "$CABAL" 2>/dev/null || true)"
if [[ -z "$CABAL_RESOLVED" ]]; then
  echo "error: cabal not found: $CABAL" >&2
  exit 2
fi
echo ">>> cabal:  $CABAL_RESOLVED"
("$CABAL" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> target: $TARGET"
echo ">>> touch:  $TOUCH_FILE"

WORK="$(mktemp -d -t link-cache-bench.XXXXXX)"
CACHE_DIR="$WORK/cache"
LOG_DIR="$WORK/logs"
RESULT_TSV="$WORK/results.tsv"

# Rewrite (or insert) the marker line in $1 to the value $2. Cabal's
# rebuild tracker hashes the file's content, so this byte-level
# mutation is what gets it to invalidate the build plan and invoke
# GHC + the link step. Idempotent: any existing marker line is
# replaced, not duplicated.
perturb_source() {
  local file="$1" tag="$2"
  sed -i "/^${MARKER}/d" "$file"
  printf '%s: %s\n' "$MARKER" "$tag" >> "$file"
}

# Strip the marker line. Best-effort -- if the file isn't writable
# at script exit (unlikely; we just wrote to it), we don't want a
# trap failure to mask the real exit code.
restore_source() {
  local file="$1"
  if [[ -n "$file" && -f "$file" ]]; then
    sed -i "/^${MARKER}/d" "$file" 2>/dev/null || true
  fi
}

# Preserve $WORK on non-zero exit so the per-condition build logs are
# available to diagnose a failure. Always strip the marker from the
# touch file -- otherwise an aborted run leaves the source tree
# dirty.
cleanup() {
  local rc=$?
  restore_source "${TOUCH_FILE:-}"
  if [[ $rc -ne 0 ]]; then
    echo "build artifacts preserved in: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# Pre-emptively strip any marker left over from an aborted previous
# run, so the populate baseline matches the original file content.
restore_source "$TOUCH_FILE"

mkdir -p "$CACHE_DIR" "$LOG_DIR"
printf 'condition\titer\twall_seconds\thits\tmisses\n' > "$RESULT_TSV"

run_in_project() {
  ( cd "$PROJECT" && "$@" )
}

run_iteration() {
  local condition="$1" iter="$2"
  local -a env_overrides=()
  case "$condition" in
    noop-no-cache)
      env_overrides=( "CABAL_LINK_CACHE_DISABLE=1" )
      # Deliberately do NOT touch -- this measures the
      # plan/scan overhead that the touch conditions also pay.
      ;;
    touch-no-cache)
      env_overrides=( "CABAL_LINK_CACHE_DISABLE=1" )
      perturb_source "$TOUCH_FILE" "iter-$iter-$condition"
      ;;
    touch-warm-cache)
      env_overrides=( "CABAL_LINK_CACHE_DIR=$CACHE_DIR" )
      perturb_source "$TOUCH_FILE" "iter-$iter-$condition"
      ;;
    *)
      echo "error: unknown condition $condition" >&2
      return 2
      ;;
  esac

  # Build output goes to a per-condition logfile so we can count
  # [link-cache] HIT/MISS notices for this run. Without this the
  # script would have no observability into whether the cache is
  # actually engaging -- the user would see only wall-clock numbers
  # and have to trust that the cache was on.
  #
  # Timing is inlined here rather than going through a helper: the
  # build's stdout/stderr need to be redirected to $log, and folding
  # both inside a single command-substitution would also swallow the
  # seconds output the helper would otherwise print.
  local log="$LOG_DIR/iter-$iter-$condition.log"
  local start end seconds
  start=$(date +%s.%N)
  env "${env_overrides[@]}" \
    bash -c "cd '$PROJECT' && '$CABAL' build '$TARGET'" \
    >"$log" 2>&1
  end=$(date +%s.%N)
  seconds=$(awk -v s="$start" -v e="$end" \
              'BEGIN { printf("%.3f", e - s) }')

  local hits misses
  hits=$(grep -c '\[link-cache\] HIT' "$log" 2>/dev/null || true)
  misses=$(grep -c '\[link-cache\] MISS' "$log" 2>/dev/null || true)
  hits=${hits:-0}
  misses=${misses:-0}

  printf '    -> %ss  (hits=%s, misses=%s)\n' \
    "$seconds" "$hits" "$misses"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$condition" "$iter" "$seconds" "$hits" "$misses" >> "$RESULT_TSV"
}

# Warmup: ensure deps and the target are built to a steady state, so
# the populate/iteration timings don't include dep installation.
echo ">>> warmup build (excluded from results)"
run_in_project "$CABAL" build "$TARGET" >/dev/null 2>&1 || true

# Populate the cache for the post-touch state. Without this step,
# the first touch-warm-cache iteration would miss everything: the
# cache would be empty, every relink would fall through to a real
# ar / ghc-link, and the result would be indistinguishable from
# touch-no-cache. Doing a touch + cache-on build here primes the
# cache with the exact link inputs that the iterations will
# subsequently produce.
echo ">>> populating cache (perturb + cache-on build)"
perturb_source "$TOUCH_FILE" "populate"
env "CABAL_LINK_CACHE_DIR=$CACHE_DIR" \
  bash -c "cd '$PROJECT' && '$CABAL' build '$TARGET'" \
  >"$LOG_DIR/populate.log" 2>&1 || true

for i in $(seq 1 "$ITERS"); do
  echo ">>> iteration $i / $ITERS"
  for cond in noop-no-cache touch-no-cache touch-warm-cache; do
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
{
  vals[$1, ++n[$1]] = $3
  hitsum[$1] += $4
  misssum[$1] += $5
}
END {
  for (c in n) {
    cnt = n[c]
    for (i = 1; i <= cnt; i++) a[i] = vals[c, i]
    asort(a)
    mid = int((cnt + 1) / 2)
    printf("%s\tmedian=%.3fs\tn=%d\thits=%d\tmisses=%d\n",
           c, a[mid], cnt, hitsum[c], misssum[c])
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

# Headline speedup: touch-no-cache vs touch-warm-cache. The signal
# we care about is "how much wall-clock does the cache save in a
# realistic edit-rebuild loop?" The cabal per-build overhead floor
# (visible in noop-no-cache) is inherited by both numbers and
# washes out of the delta.
echo
echo "=== speedup: touch-no-cache vs touch-warm-cache ==="
awk -F'\t' '
NR == 1 { next }
$1 == "touch-no-cache"   { off += $3; offN += 1 }
$1 == "touch-warm-cache" { on  += $3; onN  += 1 }
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
