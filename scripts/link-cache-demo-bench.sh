#!/usr/bin/env bash
# Drive examples/link-cache-demo/ through a set of edit shapes the
# link-cache has never seen before and report:
#
#   * cache off vs cache on wall-clock per scenario
#   * per-link target outcome (HIT/MISS) breakdown — the diagnostic
#     layer that turns "27 hits / 0 misses" into "core.a MISS, codec.a
#     HIT, codec.so HIT, …"
#   * optional soundness sweep (CABAL_LINK_CACHE_VERIFY=1) that proves
#     no HIT is a false HIT
#
# Methodology, in short:
#
#   1. Cold-build the demo with CABAL_LINK_CACHE_DIR=<snapshot>; this
#      populates the cache with the baseline link outputs.
#   2. For each scenario × iteration: restore the touched file, sync
#      dist-newstyle to baseline (cache off, so we don't pollute the
#      snapshot), apply the scenario's perturbation, time the rebuild
#      twice — once with the cache disabled, once with the cache
#      reset to the baseline snapshot. Every cache-on iteration starts
#      from a baseline-only cache, so each is a *novel-edit* test.
#   3. Optionally re-run each scenario with VERIFY=1 + VERIFY_FAIL=1;
#      a true HIT must produce byte-identical linker output. Any
#      divergence aborts the bench.
#
# Outputs land in:
#
#   examples/link-cache-demo/REPORT.md             — human-readable
#   examples/link-cache-demo/.bench-results.jsonl  — per-scenario
#                                                    aggregated JSONL
#   examples/link-cache-demo/.per-target.tsv       — per-(scenario,
#                                                    target, iter)
#                                                    outcome rows
#
# Usage:
#   scripts/link-cache-demo-bench.sh --cabal=PATH \
#       [--demo-dir=PATH] [--runs=N] [--scenarios=a,b,c,...] [--verify]
#
# Defaults: --runs=3, all nine scenarios, demo-dir=<repo>/examples/
#   link-cache-demo. The default scenarios are:
#
#     body-stable, add-unexported, add-exported, modify-type,
#     refactor-internal, whitespace-only, comment-only,
#     reorder-exports, edit-leaf-of-mid-lib

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

CABAL=""
DEMO_DIR="$REPO/examples/link-cache-demo"
RUNS=3
SCENARIOS="body-stable,add-unexported,add-exported,modify-type,refactor-internal,whitespace-only,comment-only,reorder-exports,edit-leaf-of-mid-lib"
WITH_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cabal=*)     CABAL="${1#*=}"; shift ;;
    --demo-dir=*)  DEMO_DIR="${1#*=}"; shift ;;
    --runs=*)      RUNS="${1#*=}"; shift ;;
    --scenarios=*) SCENARIOS="${1#*=}"; shift ;;
    --verify)      WITH_VERIFY=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    *) echo "error: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$CABAL" ]] && { echo "error: --cabal=PATH is required" >&2; exit 2; }
CABAL_RESOLVED="$(command -v "$CABAL" 2>/dev/null || true)"
[[ -z "$CABAL_RESOLVED" ]] && { echo "error: cabal not executable: $CABAL" >&2; exit 2; }
[[ -d "$DEMO_DIR" ]]      || { echo "error: demo-dir not found: $DEMO_DIR" >&2; exit 2; }
DEMO_DIR="$(cd "$DEMO_DIR" && pwd)"

echo ">>> cabal:     $CABAL_RESOLVED"
("$CABAL" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> demo dir:  $DEMO_DIR"
echo ">>> runs:      $RUNS"
echo ">>> scenarios: $SCENARIOS"
echo ">>> verify:    $WITH_VERIFY"
echo

# -- Workspace --------------------------------------------------------

WORK="$(mktemp -d -t link-cache-demo-bench.XXXXXX)"
BASELINE_DIR="$WORK/baselines"
CACHE_ROOT="$WORK/cache"
LOG_DIR="$WORK/logs"
RESULTS_JSONL="$DEMO_DIR/.bench-results.jsonl"
PER_TARGET_TSV="$DEMO_DIR/.per-target.tsv"
REPORT_MD="$DEMO_DIR/REPORT.md"

mkdir -p "$CACHE_ROOT" "$LOG_DIR" "$BASELINE_DIR"

# Files that any scenario may touch. Saved at script start, restored
# from the baseline copy by `restore_touch_all` and by the EXIT trap.
TOUCH_FILES=(
  "demo-core/src/Demo/Core/Util.hs"
  "demo-codec/src/Demo/Codec/Frame.hs"
)
for rel in "${TOUCH_FILES[@]}"; do
  src="$DEMO_DIR/$rel"
  dst="$BASELINE_DIR/$rel"
  [[ -f "$src" ]] || { echo "error: touch file not found: $src" >&2; exit 2; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
done

cleanup() {
  local rc=$?
  if [[ -d "$BASELINE_DIR" ]]; then
    for rel in "${TOUCH_FILES[@]}"; do
      cp "$BASELINE_DIR/$rel" "$DEMO_DIR/$rel" 2>/dev/null || true
    done
  fi
  if (( rc != 0 )); then
    echo "build artifacts preserved in: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

restore_touch_all() {
  for rel in "${TOUCH_FILES[@]}"; do
    cp "$BASELINE_DIR/$rel" "$DEMO_DIR/$rel"
  done
}

# -- Scenario perturbations ------------------------------------------

# Each scenario knows which source file it edits. The bench saves and
# restores all listed touch files before/after every iteration, so a
# scenario only has to mutate the one it cares about.
scenario_target_file() {
  case "$1" in
    edit-leaf-of-mid-lib) echo "$DEMO_DIR/demo-codec/src/Demo/Codec/Frame.hs" ;;
    *)                    echo "$DEMO_DIR/demo-core/src/Demo/Core/Util.hs" ;;
  esac
}

apply_body_stable() {
  sed -i \
    's|^every p = foldStrict|every p = let _bench = (0 :: Int) in foldStrict|' \
    "$1"
}

apply_add_unexported() {
  cat >> "$1" <<'EOF'

_benchUnexported :: Int -> Int
_benchUnexported x = x + 1
EOF
}

apply_add_exported() {
  sed -i '/^  ) where$/i\  , _benchExported' "$1"
  cat >> "$1" <<'EOF'

_benchExported :: Int -> Int
_benchExported x = x + 1
EOF
}

apply_modify_type() {
  sed -i 's|^describe :: Show a => a -> String$|describe :: (Show a, Eq a) => a -> String|' "$1"
}

apply_refactor_internal() {
  sed -i 's|firstOf|headOf|g' "$1"
}

apply_whitespace_only() {
  # Append a blank line. .hi should be byte-stable (whitespace is
  # dropped by the lexer); Util.o should be byte-equal to baseline.
  echo "" >> "$1"
}

apply_comment_only() {
  # Append a comment line. Direct analogue of what link-cache-bench.sh
  # does. Expected: 9/9 HITs.
  echo "-- bench: comment-only marker" >> "$1"
}

apply_reorder_exports() {
  # Swap two adjacent exports in Demo.Core.Util's export list. GHC
  # canonicalises the export set when computing the ABI hash, so the
  # .hi should be byte-equal -- a positive control.
  awk '
    /^  , groupRuns$/     { stash = $0; next }
    /^  , normaliseList$/ {
      print
      if (stash != "") { print stash; stash = "" }
      next
    }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

apply_edit_leaf_of_mid_lib() {
  # Add an unused private helper to Demo.Codec.Frame. Nothing else in
  # the project imports Frame, so demo-core and demo-graph should HIT
  # fully; demo-codec, demo-engine, and the exe should MISS.
  cat >> "$1" <<'EOF'

_benchPrivate :: Int -> Int
_benchPrivate x = x * 2
EOF
}

apply_scenario() {
  local scen="$1"
  local file
  file="$(scenario_target_file "$scen")"
  case "$scen" in
    body-stable)          apply_body_stable          "$file" ;;
    add-unexported)       apply_add_unexported       "$file" ;;
    add-exported)         apply_add_exported         "$file" ;;
    modify-type)          apply_modify_type          "$file" ;;
    refactor-internal)    apply_refactor_internal    "$file" ;;
    whitespace-only)      apply_whitespace_only      "$file" ;;
    comment-only)         apply_comment_only         "$file" ;;
    reorder-exports)      apply_reorder_exports      "$file" ;;
    edit-leaf-of-mid-lib) apply_edit_leaf_of_mid_lib "$file" ;;
    *) echo "error: unknown scenario: $scen" >&2; return 2 ;;
  esac
}

# -- Build helpers ----------------------------------------------------

timed_build() {
  local log="$1"; shift
  local -a env_overrides=("$@")
  local start end
  start=$(date +%s.%N)
  ( cd "$DEMO_DIR" && env "${env_overrides[@]}" "$CABAL" build all ) \
    >"$log" 2>&1
  end=$(date +%s.%N)
  awk -v s="$start" -v e="$end" 'BEGIN { printf("%.3f", e - s) }'
}

count_outcomes() {
  local jsonl="$1" outcome="$2"
  if [[ ! -f "$jsonl" ]]; then echo 0; return; fi
  grep -c "\"outcome\":\"${outcome}\"" "$jsonl" 2>/dev/null || true
}

# Extract per-link (target_basename, outcome) pairs from a
# .stats.jsonl and append them to $PER_TARGET_TSV tagged with
# scenario + iter.
capture_per_target() {
  local stats="$1" scen="$2" iter="$3"
  [[ -f "$stats" ]] || return 0
  # Each row in stats.jsonl is one JSON object on its own line. Pull
  # the target's basename and outcome via a single sed.
  sed -nE 's|.*"target":"[^"]*/([^"]+)".*"outcome":"([^"]+)".*|\1\t\2|p' "$stats" \
    | while IFS=$'\t' read -r target outcome; do
        printf '%s\t%d\t%s\t%s\n' "$scen" "$iter" "$target" "$outcome" \
          >> "$PER_TARGET_TSV"
      done
}

median() {
  local col="$1" file="$2"
  awk -F'\t' -v c="$col" 'NR > 1 { a[NR-1] = $c } END {
    n = NR - 1
    if (n == 0) { print "n/a"; exit }
    asort(a)
    if (n % 2 == 1) printf("%.3f", a[(n+1)/2])
    else            printf("%.3f", (a[n/2] + a[n/2+1]) / 2)
  }' "$file"
}

# Abbreviate a target basename for the report's per-target table.
abbrev_target() {
  case "$1" in
    libHSdemo-core-*-inplace.a)      echo "core.a" ;;
    libHSdemo-core-*-inplace-*.so)   echo "core.so" ;;
    libHSdemo-codec-*-inplace.a)     echo "codec.a" ;;
    libHSdemo-codec-*-inplace-*.so)  echo "codec.so" ;;
    libHSdemo-graph-*-inplace.a)     echo "graph.a" ;;
    libHSdemo-graph-*-inplace-*.so)  echo "graph.so" ;;
    libHSdemo-engine-*-inplace.a)    echo "engine.a" ;;
    libHSdemo-engine-*-inplace-*.so) echo "engine.so" ;;
    demo-app)                        echo "demo-app" ;;
    *)                               echo "$1" ;;
  esac
}

# -- Cold cache populate + baseline snapshot --------------------------

BASELINE_SNAPSHOT="$WORK/baseline-snapshot"
mkdir -p "$BASELINE_SNAPSHOT"

echo ">>> cold build to populate baseline link-cache snapshot"
echo "    (one-time setup; wipes $DEMO_DIR/dist-newstyle)"
restore_touch_all
rm -rf "$DEMO_DIR/dist-newstyle"
( cd "$DEMO_DIR" && \
    env "CABAL_LINK_CACHE_DIR=$BASELINE_SNAPSHOT" \
      "$CABAL" build all ) >"$LOG_DIR/cold-populate.log" 2>&1
SNAP_BLOBS=$(find "$BASELINE_SNAPSHOT" -name '*.blob' | wc -l)
echo "    baseline snapshot: ${SNAP_BLOBS} blobs"
if (( SNAP_BLOBS == 0 )); then
  echo "error: baseline snapshot is empty; see $LOG_DIR/cold-populate.log" >&2
  exit 1
fi
rm -f "$BASELINE_SNAPSHOT/.stats.jsonl"

echo ">>> noop baseline (cabal overhead floor, no edit, cache off)"
NOOP_SECONDS="$(timed_build "$LOG_DIR/noop.log" "CABAL_LINK_CACHE_DISABLE=1")"
echo "    -> ${NOOP_SECONDS}s"
echo

: > "$RESULTS_JSONL"
: > "$PER_TARGET_TSV"
echo -e 'scenario\titer\ttarget\toutcome' > "$PER_TARGET_TSV"

# -- Scenario driver --------------------------------------------------

run_scenario() {
  local scen="$1"
  local scen_cache_dir="$CACHE_ROOT/$scen"
  local raw="$WORK/${scen}.tsv"

  printf 'iter\toff_seconds\ton_seconds\ton_hits\ton_misses\n' > "$raw"

  echo "=== scenario: $scen ==="

  for i in $(seq 1 "$RUNS"); do
    echo "--- iter $i / $RUNS"

    # Hard-reset dist-newstyle so a prior scenario's cascade doesn't
    # leave polluted .o/.hi files lying around for this iter to
    # encounter. Without this, the canonical 9/9-HIT scenarios in the
    # second half of the sweep (whitespace-only, comment-only,
    # reorder-exports, refactor-internal) silently degrade to ~4/9
    # because cabal's incremental-build heuristics don't always
    # roll forward downstream .o files that GHC compiled
    # non-deterministically under a prior cascade. The cost is one
    # cold rebuild per iter (~15s for this demo), which we accept
    # for measurement honesty.
    rm -rf "$DEMO_DIR/dist-newstyle"

    # cache-off measurement (novel edit, no cache, full cost)
    restore_touch_all
    ( cd "$DEMO_DIR" && env CABAL_LINK_CACHE_DISABLE=1 "$CABAL" build all ) \
      >"$LOG_DIR/${scen}-iter${i}-sync.log" 2>&1
    apply_scenario "$scen"
    local off_s
    off_s="$(timed_build "$LOG_DIR/${scen}-iter${i}-off.log" \
              "CABAL_LINK_CACHE_DISABLE=1")"

    # cache-on measurement (novel edit, baseline-only cache).
    rm -rf "$DEMO_DIR/dist-newstyle"
    restore_touch_all
    ( cd "$DEMO_DIR" && env CABAL_LINK_CACHE_DISABLE=1 "$CABAL" build all ) \
      >"$LOG_DIR/${scen}-iter${i}-sync2.log" 2>&1
    apply_scenario "$scen"
    rm -rf "$scen_cache_dir"
    cp -a "$BASELINE_SNAPSHOT" "$scen_cache_dir"
    : > "$scen_cache_dir/.stats.jsonl"
    local on_s
    on_s="$(timed_build "$LOG_DIR/${scen}-iter${i}-on.log" \
              "CABAL_LINK_CACHE_DIR=$scen_cache_dir")"

    capture_per_target "$scen_cache_dir/.stats.jsonl" "$scen" "$i"

    local hits misses already
    hits="$(   count_outcomes "$scen_cache_dir/.stats.jsonl" hit)"
    already="$(count_outcomes "$scen_cache_dir/.stats.jsonl" hit-already-current)"
    misses="$( count_outcomes "$scen_cache_dir/.stats.jsonl" miss)"
    hits=$(( hits + already ))

    printf '    off=%ss  on=%ss  hits=%s  misses=%s\n' \
      "$off_s" "$on_s" "$hits" "$misses"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$i" "$off_s" "$on_s" "$hits" "$misses" >> "$raw"
  done

  local off_med on_med hit_tot miss_tot speedup
  off_med="$(median 2 "$raw")"
  on_med="$( median 3 "$raw")"
  hit_tot=$( awk -F'\t' 'NR>1 { s+=$4 } END { print s+0 }' "$raw")
  miss_tot=$(awk -F'\t' 'NR>1 { s+=$5 } END { print s+0 }' "$raw")
  speedup="$(awk -v off="$off_med" -v on="$on_med" \
              'BEGIN { if (off > 0) printf("%.1f", (off - on) * 100 / off); else printf("n/a") }')"

  printf '{"scenario":"%s","off_seconds":%s,"on_seconds":%s,"speedup_pct":%s,"hits_total":%d,"misses_total":%d,"runs":%d}\n' \
    "$scen" "$off_med" "$on_med" "$speedup" "$hit_tot" "$miss_tot" "$RUNS" \
    >> "$RESULTS_JSONL"

  echo ">>> $scen: off=${off_med}s on=${on_med}s speedup=${speedup}% hits=${hit_tot} misses=${miss_tot}"
  echo
}

IFS=',' read -ra SCEN_LIST <<< "$SCENARIOS"
for s in "${SCEN_LIST[@]}"; do
  run_scenario "$s"
done

# -- Soundness verify sweep (optional) -------------------------------

VERIFY_LOG="$WORK/verify-results.tsv"
echo -e 'scenario\tverdict\treason' > "$VERIFY_LOG"
VERIFY_FAILURES=()

if (( WITH_VERIFY )); then
  echo
  echo "=== soundness verify sweep =="
  echo "(CABAL_LINK_CACHE_VERIFY=1 + VERIFY_FAIL=1; one pass per scenario)"
  for scen in "${SCEN_LIST[@]}"; do
    echo "--- verify: $scen"
    local_cache="$CACHE_ROOT/${scen}-verify"
    rm -rf "$local_cache"
    cp -a "$BASELINE_SNAPSHOT" "$local_cache"
    : > "$local_cache/.stats.jsonl"

    restore_touch_all
    ( cd "$DEMO_DIR" && env CABAL_LINK_CACHE_DISABLE=1 "$CABAL" build all ) \
      >"$LOG_DIR/${scen}-verify-sync.log" 2>&1
    apply_scenario "$scen"

    verify_log="$LOG_DIR/${scen}-verify.log"
    set +e
    ( cd "$DEMO_DIR" && env "CABAL_LINK_CACHE_DIR=$local_cache" \
                            CABAL_LINK_CACHE_VERIFY=1 \
                            CABAL_LINK_CACHE_VERIFY_FAIL=1 \
                            "$CABAL" build all ) \
      >"$verify_log" 2>&1
    rc=$?
    set -e

    diverged=$(grep -c 'HIT-DIVERGED' "$verify_log" 2>/dev/null || true)
    diverged=${diverged:-0}

    if (( rc != 0 )); then
      echo "    FAIL (rc=$rc); see $verify_log"
      printf '%s\tfail\trc=%d diverged=%d\n' "$scen" "$rc" "$diverged" >> "$VERIFY_LOG"
      VERIFY_FAILURES+=("$scen")
    elif (( diverged > 0 )); then
      echo "    DIVERGED ($diverged HIT-DIVERGED); see $verify_log"
      printf '%s\tdiverged\t%d records\n' "$scen" "$diverged" >> "$VERIFY_LOG"
      VERIFY_FAILURES+=("$scen")
    else
      verified=$(count_outcomes "$local_cache/.stats.jsonl" hit-verified)
      misses=$(  count_outcomes "$local_cache/.stats.jsonl" miss)
      echo "    PASS (verified=$verified, misses=$misses)"
      printf '%s\tpass\tverified=%d misses=%d\n' "$scen" "$verified" "$misses" >> "$VERIFY_LOG"
    fi
  done
fi

# -- Render REPORT.md -------------------------------------------------

{
  echo "# link-cache demo: benchmark report"
  echo
  echo "Generated by \`scripts/link-cache-demo-bench.sh\` against"
  echo "\`examples/link-cache-demo/\`."
  echo
  echo "## Project under test"
  echo
  echo "Five-package diamond:"
  echo
  echo '```'
  echo 'demo-core              (no internal deps)'
  echo '   ↑       ↑'
  echo 'demo-codec   demo-graph'
  echo '       ↑    ↑'
  echo '       demo-engine'
  echo '            ↑'
  echo '         demo-app      (executable)'
  echo '```'
  echo
  echo "Most scenarios edit \`demo-core/src/Demo/Core/Util.hs\` (the deepest"
  echo "module in the cone, so every link in the cascade is potentially"
  echo "affected). One scenario (\`edit-leaf-of-mid-lib\`) edits"
  echo "\`demo-codec/src/Demo/Codec/Frame.hs\` to probe what happens when"
  echo "the edit lands halfway up the cone instead."
  echo
  echo "## Reproduce"
  echo
  echo '```sh'
  printf "scripts/link-cache-demo-bench.sh --cabal=%s --runs=%s" \
    "$CABAL_RESOLVED" "$RUNS"
  if (( WITH_VERIFY )); then printf " --verify"; fi
  printf "\n"
  echo '```'
  echo
  echo "## What this measures"
  echo
  echo "A **novel-edit** rebuild. The link-cache is pre-populated with"
  echo "the *baseline* link outputs and snapshotted. Each timed"
  echo "cache-on iteration starts from that baseline-only cache, then"
  echo "the scenario edit is applied and the build is timed. Links"
  echo "whose inputs are byte-stable across the edit can still HIT"
  echo "from the baseline snapshot; links whose inputs changed bytes"
  echo "MISS and write the perturbed-state output to the cache. The"
  echo "cache is reset to the baseline snapshot **before every**"
  echo "iteration so the perturbed-state blobs written by iteration N"
  echo "do not poison iteration N+1."
  echo
  echo "## How each scenario should behave (a priori)"
  echo
  echo "| scenario | rationale |"
  echo "|---|---|"
  echo "| body-stable | wraps \`every\`'s body in a no-op \`let\`; at \`-O1\` GHC dead-code-eliminates the let. \`Util.o\` should be byte-equal to baseline → full cascade HIT (9/9). |"
  echo "| add-unexported | appends a new private \`_bench…\` binding; underscore-prefixed unused bindings are dropped at \`-O1\` → 9/9. |"
  echo "| add-exported | extends the export list. \`Util.hi\` grows; GHC may force downstream importers to recompile even when they don't use the new symbol. Expected: HITs only on packages that don't import \`Util\`. |"
  echo "| modify-type | tightens \`describe\`'s constraint. Downstream importers of \`describe\` must recompile → cascade MISS. |"
  echo "| refactor-internal | private \`firstOf\`→\`headOf\` rename. \`Util.o\` differs but \`Util.hi\` doesn't, so downstream \`.o\` files stay byte-stable. Expected: 6 HITs (middle libs) + 3 misses (demo-core×2 + exe — exe key includes demo-core.a bytes). |"
  echo "| whitespace-only | append a blank line to \`Util.hs\`. Lexer should drop it → \`Util.o\` byte-equal → 9/9. |"
  echo "| comment-only | append a \`--\` comment line. Same expectation as whitespace-only → 9/9. |"
  echo "| reorder-exports | swap two adjacent exports without adding/removing any. GHC canonicalises the export order for the ABI hash, so \`Util.hi\` should be byte-equal → 9/9. |"
  echo "| edit-leaf-of-mid-lib | append a private binding to \`Demo.Codec.Frame\`. Nothing imports \`Frame\` in this project, so \`demo-core\` + \`demo-graph\` should fully HIT; \`demo-codec\`, \`demo-engine\`, and the exe MISS. |"
  echo
  echo "## Results"
  echo
  echo "- \`cabal\`     : $CABAL_RESOLVED"
  echo "- \`runs\`      : $RUNS"
  echo "- \`noop floor\`: ${NOOP_SECONDS}s (cabal plan + scan, no edit; inherited by every row below)"
  echo
  printf '| scenario | cache off (s) | cache on (s) | saved (s) | speedup | HIT | MISS | HIT/build |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|---:|\n'
  awk -F'[",:{}]+' -v runs="$RUNS" '
  {
    scen = ""; off = ""; on = ""; spd = ""; hits = ""; miss = ""
    for (i = 1; i <= NF; i++) {
      if ($i == "scenario")     scen = $(i+1)
      if ($i == "off_seconds")  off  = $(i+1)
      if ($i == "on_seconds")   on   = $(i+1)
      if ($i == "speedup_pct")  spd  = $(i+1)
      if ($i == "hits_total")   hits = $(i+1)
      if ($i == "misses_total") miss = $(i+1)
    }
    saved = sprintf("%.3f", off - on)
    perbuild = (runs > 0) ? sprintf("%.1f", hits / runs) : "n/a"
    printf("| %s | %s | %s | %s | %s%% | %s | %s | %s / 9 |\n", \
      scen, off, on, saved, spd, hits, miss, perbuild)
  }' "$RESULTS_JSONL"
  echo
  echo "## Per-target outcomes"
  echo
  echo "Every build performs nine link operations: \`libHS<pkg>.a\` +"
  echo "\`libHS<pkg>.so\` for each of the four libraries plus the"
  echo "\`demo-app\` executable. The table below shows, for each scenario,"
  echo "how many of the cache-on iterations resulted in a HIT for that"
  echo "specific target (HIT counts include the \`hit-already-current\`"
  echo "stamp-fast-path)."
  echo
  echo "Target abbreviations: \`core.a\` = \`libHSdemo-core-*.a\`, etc."
  echo
  # Header
  printf '| scenario | core.a | core.so | codec.a | codec.so | graph.a | graph.so | engine.a | engine.so | demo-app |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'
  for scen in "${SCEN_LIST[@]}"; do
    printf '| %s' "$scen"
    for abbrev in core.a core.so codec.a codec.so graph.a graph.so engine.a engine.so demo-app; do
      hit_count=$(awk -F'\t' -v scen="$scen" -v want="$abbrev" '
        function abbrev_t(t) {
          if (t ~ /^libHSdemo-core-.*-inplace\.a$/)      return "core.a"
          if (t ~ /^libHSdemo-core-.*-inplace-.*\.so$/)  return "core.so"
          if (t ~ /^libHSdemo-codec-.*-inplace\.a$/)     return "codec.a"
          if (t ~ /^libHSdemo-codec-.*-inplace-.*\.so$/) return "codec.so"
          if (t ~ /^libHSdemo-graph-.*-inplace\.a$/)     return "graph.a"
          if (t ~ /^libHSdemo-graph-.*-inplace-.*\.so$/) return "graph.so"
          if (t ~ /^libHSdemo-engine-.*-inplace\.a$/)    return "engine.a"
          if (t ~ /^libHSdemo-engine-.*-inplace-.*\.so$/) return "engine.so"
          if (t == "demo-app")                            return "demo-app"
          return t
        }
        NR == 1 { next }
        $1 == scen && abbrev_t($3) == want \
          && ($4 == "hit" || $4 == "hit-already-current") { c++ }
        END { print c+0 }
      ' "$PER_TARGET_TSV")
      printf ' | %s/%s' "$hit_count" "$RUNS"
    done
    printf ' |\n'
  done
  echo
  if (( WITH_VERIFY )); then
    echo "## Soundness"
    echo
    echo "Each scenario was re-run once with \`CABAL_LINK_CACHE_VERIFY=1\`"
    echo "and \`CABAL_LINK_CACHE_VERIFY_FAIL=1\`. In this mode the linker"
    echo "is re-invoked on every cache HIT and the cached blob is"
    echo "byte-compared against the freshly-produced output; any"
    echo "divergence is escalated to a hard build error."
    echo
    printf '| scenario | verdict | detail |\n'
    printf '|---|---|---|\n'
    awk -F'\t' 'NR > 1 { printf("| %s | %s | %s |\n", $1, $2, $3) }' "$VERIFY_LOG"
    echo
    if (( ${#VERIFY_FAILURES[@]} == 0 )); then
      echo "All scenarios passed: every HIT reported by the cache produced"
      echo "byte-identical linker output. The HIT counts in the tables"
      echo "above are real cache wins, not false positives."
    else
      echo "**${#VERIFY_FAILURES[@]} scenario(s) failed the soundness check.**"
      echo "Build artifacts preserved in \`$WORK\` for inspection."
    fi
    echo
  fi
  echo "Raw per-scenario JSON in \`.bench-results.jsonl\`."
  echo "Raw per-(scenario, iter, target) outcomes in \`.per-target.tsv\`."
  echo
  echo "## Interpretation"
  echo
  echo "The **\`HIT/build\`** column and the per-target outcomes table"
  echo "together tell the story. On this project, novel-edit cache"
  echo "wins stratify by the edit's effect on the touched module's"
  echo "\`.hi\`:"
  echo
  echo "- Edits GHC reduces to a byte-equal \`.o\` at \`-O1\` (body-stable,"
  echo "  add-unexported, whitespace-only, comment-only) HIT the full"
  echo "  cascade."
  echo "- Edits whose \`.o\` differs but whose \`.hi\` is stable"
  echo "  (refactor-internal) keep middle libraries on the HIT side;"
  echo "  the touched library and the exe (which links against the"
  echo "  touched library's bytes via \`linkDepArchives\`) MISS."
  echo "- Edits that change the \`.hi\` (add-exported, modify-type)"
  echo "  force GHC to recompile downstream importers; their \`.o\` files"
  echo "  come out fresh, so the link cone above the change misses."
  echo "  Cache wins are confined to packages that don't import the"
  echo "  touched module at all."
  echo "- \`reorder-exports\` is a positive control: GHC canonicalises"
  echo "  export ordering for the ABI hash, so reordering should be"
  echo "  invisible to downstream."
  echo "- \`edit-leaf-of-mid-lib\` probes the same partitioning logic"
  echo "  from a different starting point: an edit to \`demo-codec\`"
  echo "  leaves \`demo-core\` + \`demo-graph\` HITting, and only the"
  echo "  ancestors of \`demo-codec\` in the cone MISS."
} > "$REPORT_MD"

echo
echo "=== summary ==="
column -t -s $'\t' < <(
  printf 'scenario\toff\ton\tspeedup\thits\tmisses\n'
  awk -F'[",:{}]+' '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "scenario")     scen = $(i+1)
      if ($i == "off_seconds")  off  = $(i+1)
      if ($i == "on_seconds")   on   = $(i+1)
      if ($i == "speedup_pct")  spd  = $(i+1)
      if ($i == "hits_total")   hits = $(i+1)
      if ($i == "misses_total") miss = $(i+1)
    }
    printf("%s\t%ss\t%ss\t%s%%\t%s\t%s\n", scen, off, on, spd, hits, miss)
  }' "$RESULTS_JSONL"
)
echo
if (( WITH_VERIFY )); then
  if (( ${#VERIFY_FAILURES[@]} > 0 )); then
    echo "VERIFY FAILED for: ${VERIFY_FAILURES[*]}" >&2
    exit 3
  fi
  echo "verify: all scenarios passed"
fi
echo "report:    $REPORT_MD"
echo "jsonl:     $RESULTS_JSONL"
echo "per-tgt:   $PER_TARGET_TSV"
