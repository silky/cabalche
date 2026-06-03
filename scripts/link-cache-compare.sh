#!/usr/bin/env bash
# link-cache-compare.sh — A/B benchmark of two cabal binaries on a
# realistic edit-rebuild loop.
#
# Drives a user-supplied repo through a cold build + N rounds of
# (apply patch → build → revert patch → build), once per cabal,
# and prints the side-by-side wall-clock comparison. Designed to
# answer: "does this fork actually speed up my edit cycles?"
#
# Inputs:
#   --repo=PATH       repo to build in (default: current dir)
#   --package=NAME    target to build (e.g. `hydra-node`, `all`)
#   --patch=PATH      patch file applied each iteration
#   --cabal-a=PATH    baseline cabal binary
#   --cabal-b=PATH    candidate cabal binary
#   --name-a=LABEL    column label for cabal-a (default: "cabal-A")
#   --name-b=LABEL    column label for cabal-b (default: "cabal-B")
#   --iters=N         apply/revert pairs per cabal (default: 3)
#   --report=PATH     markdown report path
#                     (default: ./link-cache-compare-report.md)
#   --cabal-args=STR  extra flags spliced into each `cabal build`
#                     invocation (e.g. `--project-file=/tmp/bench.project`
#                     to bypass a broken cabal.project glob). The string
#                     is word-split on spaces.
#   --a-cache         leave cabal-a's link-cache enabled (default:
#                     `CABAL_LINK_CACHE_DISABLE=1`). Useful for isolating
#                     a *delta between two cache implementations* rather
#                     than the cache's full effect.
#
# Methodology, per cabal:
#   1. `git checkout -- .` (refuses to start if the working tree is
#      already dirty)
#   2. Cold build (timed) — populates dist-newstyle (and, for
#      cabal-B, the link-cache)
#   3. N iterations of:
#        a. `git apply PATCH`   → build (timed)
#        b. `git apply -R PATCH` → build (timed)
#   4. Medians taken over the N edit and N revert samples
#
# cabal-A runs with `CABAL_LINK_CACHE_DISABLE=1` (so if it happens
# to be a link-cache build it still benchmarks as "cache off").
# cabal-B runs with `CABAL_LINK_CACHE_DIR=<tmpdir>` so its cache
# starts cold and doesn't leak into the user's $XDG_CACHE_HOME.
# Each cabal gets its own `--builddir`, so they don't share
# `dist-newstyle` bookkeeping.
#
# Example (hydra; needs nix dev-env for libsodium et al.):
#   nix develop --command bash -c '
#     scripts/link-cache-compare.sh \
#       --repo=$HOME/dev/w/hydra \
#       --package=hydra-node \
#       --patch=/tmp/hydra-prelude.patch \
#       --cabal-a=$(which cabal) \
#       --cabal-b=$HOME/dev/ext/cabal/result-opt/bin/cabal
#   '

set -euo pipefail

REPO="$(pwd)"
PACKAGE=""
PATCH=""
CABAL_A=""
CABAL_B=""
NAME_A="cabal-A"
NAME_B="cabal-B"
ITERS=3
REPORT=""
CABAL_ARGS=""
A_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo=*)        REPO="${1#*=}"; shift ;;
    --package=*)     PACKAGE="${1#*=}"; shift ;;
    --patch=*)       PATCH="${1#*=}"; shift ;;
    --cabal-a=*)     CABAL_A="${1#*=}"; shift ;;
    --cabal-b=*)     CABAL_B="${1#*=}"; shift ;;
    --name-a=*)      NAME_A="${1#*=}"; shift ;;
    --name-b=*)      NAME_B="${1#*=}"; shift ;;
    --iters=*)       ITERS="${1#*=}"; shift ;;
    --report=*)      REPORT="${1#*=}"; shift ;;
    --cabal-args=*)  CABAL_ARGS="${1#*=}"; shift ;;
    --a-cache)       A_CACHE=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    *) echo "error: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$PACKAGE" ]] && { echo "error: --package=NAME is required" >&2; exit 2; }
[[ -z "$PATCH"   ]] && { echo "error: --patch=PATH is required"   >&2; exit 2; }
[[ -z "$CABAL_A" ]] && { echo "error: --cabal-a=PATH is required" >&2; exit 2; }
[[ -z "$CABAL_B" ]] && { echo "error: --cabal-b=PATH is required" >&2; exit 2; }
[[ -d "$REPO"    ]] || { echo "error: --repo not a directory: $REPO" >&2; exit 2; }
[[ -f "$PATCH"   ]] || { echo "error: --patch not a file: $PATCH"   >&2; exit 2; }

REPO=$(cd "$REPO" && pwd)
PATCH=$(readlink -f "$PATCH")

for c in "$CABAL_A" "$CABAL_B"; do
  if ! "$c" --version >/dev/null 2>&1; then
    echo "error: cabal binary not executable: $c" >&2; exit 2
  fi
done

if [[ -z "$REPORT" ]]; then
  REPORT="$PWD/link-cache-compare-report.md"
fi

# Refuse to run if the working tree is dirty -- we'd lose the user's
# changes when reverting between iterations.
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  echo "error: working tree at $REPO is dirty; commit or stash first" >&2
  exit 2
fi

# Verify the patch applies cleanly before we start timing anything.
if ! ( cd "$REPO" && git apply --check "$PATCH" ) 2>/dev/null; then
  echo "error: patch does not apply cleanly to $REPO: $PATCH" >&2
  exit 2
fi

case "$PACKAGE" in
  all) BUILD_TARGET="all" ;;
  *)   BUILD_TARGET="$PACKAGE" ;;
esac

WORK=$(mktemp -d -t link-cache-compare.XXXXXX)
DIST_A="$WORK/dist-a"
DIST_B="$WORK/dist-b"
CACHE_A="$WORK/cache-a"
CACHE_B="$WORK/cache-b"
TSV="$WORK/results.tsv"
mkdir -p "$DIST_A" "$DIST_B" "$CACHE_B"
if (( A_CACHE )); then mkdir -p "$CACHE_A"; fi

cleanup() {
  local rc=$?
  # Try the reverse of the patch first (handles add/remove cleanly),
  # then fall back to a hard checkout for any straggler modifications.
  ( cd "$REPO" && git apply -R "$PATCH" 2>/dev/null ) || true
  git -C "$REPO" checkout -- . 2>/dev/null || true
  if (( rc != 0 )); then
    echo "build logs preserved in: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

echo ">>> repo:    $REPO  (HEAD: $(git -C "$REPO" rev-parse --short HEAD))"
echo ">>> target:  $BUILD_TARGET"
echo ">>> patch:   $PATCH"
echo ">>> $NAME_A: $CABAL_A"
("$CABAL_A" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> $NAME_B: $CABAL_B"
("$CABAL_B" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> iters:   $ITERS"
echo ">>> report:  $REPORT"
echo

time_run() {
  local label="$1"; shift
  local start end
  start=$(date +%s.%N)
  if ! ( cd "$REPO" && "$@" ) >"$WORK/${label}.log" 2>&1; then
    local rc=$?
    echo "error: $label failed (exit $rc); last 30 lines:" >&2
    tail -n 30 "$WORK/${label}.log" >&2
    return $rc
  fi
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }'
}

median() {
  # Median of the numeric args; prints "n/a" if no args.
  if (( $# == 0 )); then echo "n/a"; return; fi
  printf '%s\n' "$@" | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR % 2 == 1) printf "%.3f\n", a[(NR+1)/2]
      else             printf "%.3f\n", (a[NR/2] + a[NR/2+1]) / 2
    }
  '
}

stats_count() {
  local file="$1" outcome="$2"
  if [[ -f "$file" ]]; then
    grep -c "\"outcome\":\"$outcome\"" "$file" 2>/dev/null || true
  else
    echo 0
  fi
}

# Per-label per-iter detail rows, emitted into the report's "Details"
# section.
DETAILS_FILE="$WORK/details.md"
: > "$DETAILS_FILE"

run_pass() {
  local label="$1" cabal="$2" dist="$3" cache="$4"
  local env_pre

  if [[ -n "$cache" ]]; then
    env_pre=("env" "CABAL_LINK_CACHE_DIR=$cache")
  else
    env_pre=("env" "CABAL_LINK_CACHE_DISABLE=1")
  fi

  echo
  echo "=== $label ==="
  ( cd "$REPO" && git apply -R "$PATCH" 2>/dev/null ) || true
  git -C "$REPO" checkout -- . 2>/dev/null || true

  echo "--- cold build (empty dist-newstyle$( [[ -n $cache ]] && echo " + empty cache" ))"
  local cold
  cold=$(time_run "${label}-cold" "${env_pre[@]}" "$cabal" build --builddir="$dist" $CABAL_ARGS "$BUILD_TARGET")
  echo "    cold: ${cold}s"

  local edits=() reverts=() hits_per=() miss_per=()
  for ((i=1; i<=ITERS; i++)); do
    echo "--- iter $i: apply"
    ( cd "$REPO" && git apply "$PATCH" )
    local h0 m0 te
    h0=$(stats_count "$cache/.stats.jsonl" hit)
    m0=$(stats_count "$cache/.stats.jsonl" miss)
    te=$(time_run "${label}-edit-$i" "${env_pre[@]}" "$cabal" build --builddir="$dist" $CABAL_ARGS "$BUILD_TARGET")
    local h1 m1
    h1=$(stats_count "$cache/.stats.jsonl" hit)
    m1=$(stats_count "$cache/.stats.jsonl" miss)
    local dh=$((h1-h0)) dm=$((m1-m0))
    echo "    edit:   ${te}s  (Δhit=$dh Δmiss=$dm)"
    edits+=("$te")

    echo "--- iter $i: revert"
    ( cd "$REPO" && git apply -R "$PATCH" )
    h0=$h1; m0=$m1
    local tr
    tr=$(time_run "${label}-revert-$i" "${env_pre[@]}" "$cabal" build --builddir="$dist" $CABAL_ARGS "$BUILD_TARGET")
    h1=$(stats_count "$cache/.stats.jsonl" hit)
    m1=$(stats_count "$cache/.stats.jsonl" miss)
    dh=$((h1-h0)); dm=$((m1-m0))
    echo "    revert: ${tr}s  (Δhit=$dh Δmiss=$dm)"
    reverts+=("$tr")
  done

  local em rm
  em=$(median "${edits[@]}")
  rm=$(median "${reverts[@]}")

  printf '%s\t%s\t%s\t%s\n' "$label" "$cold" "$em" "$rm" >> "$TSV"

  {
    echo
    echo "### $label"
    printf -- "- cold:       %ss\n" "$cold"
    printf -- "- edits:      %s → median %s\n" "$(IFS=, ; echo "${edits[*]}")" "$em"
    printf -- "- reverts:    %s → median %s\n" "$(IFS=, ; echo "${reverts[*]}")" "$rm"
  } >> "$DETAILS_FILE"
}

printf 'label\tcold_s\tedit_median_s\trevert_median_s\n' > "$TSV"

if (( A_CACHE )); then
  run_pass "$NAME_A" "$CABAL_A" "$DIST_A" "$CACHE_A"
else
  run_pass "$NAME_A" "$CABAL_A" "$DIST_A" ""
fi
run_pass "$NAME_B" "$CABAL_B" "$DIST_B" "$CACHE_B"

# Extract per-label medians.
COLD_A=$(awk -v L="$NAME_A" -F'\t' '$1==L {print $2}' "$TSV")
COLD_B=$(awk -v L="$NAME_B" -F'\t' '$1==L {print $2}' "$TSV")
EDIT_A=$(awk -v L="$NAME_A" -F'\t' '$1==L {print $3}' "$TSV")
EDIT_B=$(awk -v L="$NAME_B" -F'\t' '$1==L {print $3}' "$TSV")
REV_A=$( awk -v L="$NAME_A" -F'\t' '$1==L {print $4}' "$TSV")
REV_B=$( awk -v L="$NAME_B" -F'\t' '$1==L {print $4}' "$TSV")

fmt_delta()   { awk -v a="$1" -v b="$2" 'BEGIN { printf "%+.3f", a - b }'; }
fmt_speedup() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      if (a + 0 == 0) print "n/a";
      else            printf "%+.1f%%", (a - b) * 100 / a
    }
  '
}

# Aggregate link-cache stats for cabal-B over the whole pass.
HITS_B=$(stats_count "$CACHE_B/.stats.jsonl" hit)
MISS_B=$(stats_count "$CACHE_B/.stats.jsonl" miss)

# Markdown report.
{
  echo "# link-cache compare: $NAME_A vs $NAME_B"
  echo
  echo "- Repo: \`$REPO\` (HEAD: \`$(git -C "$REPO" rev-parse --short HEAD)\`)"
  echo "- Target: \`$BUILD_TARGET\`"
  echo "- Patch: \`$PATCH\`"
  echo "- Iterations: $ITERS apply/revert pairs"
  if (( A_CACHE )); then
    echo "- $NAME_A: \`$CABAL_A\` (env: \`CABAL_LINK_CACHE_DIR=$CACHE_A\`)"
  else
    echo "- $NAME_A: \`$CABAL_A\` (env: \`CABAL_LINK_CACHE_DISABLE=1\`)"
  fi
  echo "- $NAME_B: \`$CABAL_B\` (env: \`CABAL_LINK_CACHE_DIR=$CACHE_B\`)"
  echo
  echo "Each pass: cold build, then $ITERS rounds of"
  echo "\`apply patch\` → build → \`revert patch\` → build."
  echo "Medians taken over the $ITERS edit and $ITERS revert samples."
  echo
  echo "| Stage              | $NAME_A (s) | $NAME_B (s) | Δ (s)   | $NAME_B speedup |"
  echo "|---|---:|---:|---:|---:|"
  printf "| cold                | %s | %s | %s | %s |\n" \
    "$COLD_A" "$COLD_B" "$(fmt_delta "$COLD_A" "$COLD_B")" "$(fmt_speedup "$COLD_A" "$COLD_B")"
  printf "| edit (median × %d)   | %s | %s | %s | %s |\n" \
    "$ITERS" "$EDIT_A" "$EDIT_B" "$(fmt_delta "$EDIT_A" "$EDIT_B")" "$(fmt_speedup "$EDIT_A" "$EDIT_B")"
  printf "| revert (median × %d) | %s | %s | %s | %s |\n" \
    "$ITERS" "$REV_A" "$REV_B" "$(fmt_delta "$REV_A" "$REV_B")" "$(fmt_speedup "$REV_A" "$REV_B")"
  echo
  echo "**$NAME_B link-cache stats** (whole pass, all build steps):"
  echo
  echo "- HITs:    $HITS_B"
  echo "- misses:  $MISS_B"
  echo
  echo "## Details (per-iteration)"
  cat "$DETAILS_FILE"
} | tee "$REPORT"

echo
echo ">>> report written to: $REPORT"
