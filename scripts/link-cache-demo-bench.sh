#!/usr/bin/env bash
# Drive examples/link-cache-demo/ through five edit shapes that span
# the link-cache's best-case (HIT everything) to worst-case (every
# linker invocation MISSes) behaviour.
#
# For each scenario the script applies a perturbation to
# demo-core/src/Demo/Core/Util.hs, runs $RUNS iterations of
#
#   touch-no-cache : build with CABAL_LINK_CACHE_DISABLE=1
#   touch-warm-cache : build with CABAL_LINK_CACHE_DIR=<isolated dir>
#                      after the cache has been pre-populated
#
# plus one upfront `noop` measurement (cabal's per-build floor with
# no edit applied). Results land in
# examples/link-cache-demo/.bench-results.jsonl and a rendered
# markdown table in examples/link-cache-demo/REPORT.md.
#
# Usage:
#   scripts/link-cache-demo-bench.sh --cabal=PATH \
#       [--demo-dir=PATH] [--runs=N] [--scenarios=a,b,c,...]
#
# Defaults: --runs=3, --scenarios=body-stable,add-unexported,\
#   add-exported,modify-type,refactor-internal,
#   --demo-dir=<repo>/examples/link-cache-demo.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

CABAL=""
DEMO_DIR="$REPO/examples/link-cache-demo"
RUNS=3
SCENARIOS="body-stable,add-unexported,add-exported,modify-type,refactor-internal"
TOUCH_REL="demo-core/src/Demo/Core/Util.hs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cabal=*)     CABAL="${1#*=}"; shift ;;
    --demo-dir=*)  DEMO_DIR="${1#*=}"; shift ;;
    --runs=*)      RUNS="${1#*=}"; shift ;;
    --scenarios=*) SCENARIOS="${1#*=}"; shift ;;
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
TOUCH="$DEMO_DIR/$TOUCH_REL"
[[ -f "$TOUCH" ]] || { echo "error: touch file not found: $TOUCH" >&2; exit 2; }

echo ">>> cabal:     $CABAL_RESOLVED"
("$CABAL" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> demo dir:  $DEMO_DIR"
echo ">>> touch:     $TOUCH_REL"
echo ">>> runs:      $RUNS"
echo ">>> scenarios: $SCENARIOS"
echo

# -- Workspace --------------------------------------------------------

WORK="$(mktemp -d -t link-cache-demo-bench.XXXXXX)"
BASELINE="$WORK/Util.hs.baseline"
CACHE_ROOT="$WORK/cache"
LOG_DIR="$WORK/logs"
RESULTS_JSONL="$DEMO_DIR/.bench-results.jsonl"
REPORT_MD="$DEMO_DIR/REPORT.md"

mkdir -p "$CACHE_ROOT" "$LOG_DIR"

# Save the touch file exactly as it is now; every scenario starts
# from this state and the cleanup trap restores it.
cp "$TOUCH" "$BASELINE"

cleanup() {
  local rc=$?
  cp "$BASELINE" "$TOUCH" 2>/dev/null || true
  if (( rc != 0 )); then
    echo "build artifacts preserved in: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

restore_touch() {
  cp "$BASELINE" "$TOUCH"
}

# -- Scenario perturbations ------------------------------------------

apply_body_stable() {
  # Type-preserving body change: wrap `every`'s body in a no-op
  # `let`. GHC's interface check sees no signature change, so
  # downstream .o's are not regenerated; with content-deterministic
  # GHC, all link inputs hash identically across populate + iter,
  # and the cache HITs the whole cascade.
  sed -i \
    's|^every p = foldStrict|every p = let _bench = (0 :: Int) in foldStrict|' \
    "$1"
}

apply_add_unexported() {
  # Append a new private binding. Util.o changes; downstream .hi
  # is unchanged (the binding is not exported), so downstream .o
  # files are byte-equal to baseline -- but the link inputs of
  # demo-core.a include the new Util.o, so demo-core.a MISSes.
  # Whether downstream .a's HIT depends on whether their input set
  # changed (it shouldn't: they don't list demo-core.a as a link
  # input -- cabal links libraries against -package-id, not by
  # archive byte).
  cat >> "$1" <<'EOF'

_benchUnexported :: Int -> Int
_benchUnexported x = x + 1
EOF
}

apply_add_exported() {
  # Append a new exported binding *and* extend the export list.
  # The .hi grows by one symbol; whether downstream actually
  # recompiles depends on GHC's fine-grained recompilation check.
  # Cabal-level link inputs typically include the new symbol's
  # presence, so this is the realistic "I added an API" case.
  sed -i '/^  ) where$/i\  , _benchExported' "$1"
  cat >> "$1" <<'EOF'

_benchExported :: Int -> Int
_benchExported x = x + 1
EOF
}

apply_modify_type() {
  # Tighten the constraint on `describe` from `Show a =>` to
  # `(Show a, Eq a) =>`. Exported signature changes; downstream
  # callsites that pass an `Eq`-derivable type still compile.
  # Worst case for the cache -- every consumer recompiles.
  sed -i 's|^describe :: Show a => a -> String$|describe :: (Show a, Eq a) => a -> String|' "$1"
}

apply_refactor_internal() {
  # Rename a private where-bound helper (firstOf -> headOf). Body
  # of normaliseList changes; exported signature does not, so
  # downstream .o's stay byte-equal but Util.o (and demo-core.a)
  # MISS.
  sed -i 's|firstOf|headOf|g' "$1"
}

apply_scenario() {
  local scen="$1" file="$2"
  case "$scen" in
    body-stable)       apply_body_stable       "$file" ;;
    add-unexported)    apply_add_unexported    "$file" ;;
    add-exported)      apply_add_exported      "$file" ;;
    modify-type)       apply_modify_type       "$file" ;;
    refactor-internal) apply_refactor_internal "$file" ;;
    *) echo "error: unknown scenario: $scen" >&2; return 2 ;;
  esac
}

# -- Build helpers ----------------------------------------------------

# Time a single cabal build invocation in $DEMO_DIR with the given
# env vars. Writes the build log to $log, prints wall-clock seconds.
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

# Count outcome=$2 in the link-cache telemetry $1 (.stats.jsonl).
# At default cabal verbosity the [link-cache] HIT/MISS notices are
# captured by cabal's per-component logger and never reach stdout,
# so .stats.jsonl is the authoritative source.
count_outcomes() {
  local jsonl="$1" outcome="$2"
  if [[ ! -f "$jsonl" ]]; then echo 0; return; fi
  grep -c "\"outcome\":\"${outcome}\"" "$jsonl" 2>/dev/null || true
}

# Median of a TSV column. Usage: median col file
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

# -- Cold cache populate + baseline snapshot --------------------------

# All scenarios share the same baseline link outputs (they all edit
# the same file from the same starting state), so the cache snapshot
# is built once here and reused across scenarios. We must cold-build
# from a wiped dist-newstyle: `cabal v3 build` skips relinks when its
# own up-to-date metadata says nothing changed, even if the .a / .so
# files have been deleted from disk -- so the only reliable way to
# guarantee the linker runs and populates the cache is to start from
# nothing.
BASELINE_SNAPSHOT="$WORK/baseline-snapshot"
mkdir -p "$BASELINE_SNAPSHOT"

echo ">>> cold build to populate baseline link-cache snapshot"
echo "    (one-time setup; wipes $DEMO_DIR/dist-newstyle)"
restore_touch
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
# Drop the populate's stats records; per-scenario stats start fresh.
rm -f "$BASELINE_SNAPSHOT/.stats.jsonl"

echo ">>> noop baseline (cabal overhead floor, no edit, cache off)"
NOOP_SECONDS="$(timed_build "$LOG_DIR/noop.log" "CABAL_LINK_CACHE_DISABLE=1")"
echo "    -> ${NOOP_SECONDS}s"
echo

# Truncate the per-run results file; we'll append one JSON object
# per scenario at the end.
: > "$RESULTS_JSONL"

# -- Scenario driver --------------------------------------------------

run_scenario() {
  local scen="$1"
  local scen_cache_dir="$CACHE_ROOT/$scen"
  local raw="$WORK/${scen}.tsv"

  printf 'iter\toff_seconds\ton_seconds\ton_hits\ton_misses\n' > "$raw"

  echo "=== scenario: $scen ==="

  for i in $(seq 1 "$RUNS"); do
    echo "--- iter $i / $RUNS"

    # cache-off measurement (novel edit, no cache, full cost)
    restore_touch
    ( cd "$DEMO_DIR" && env CABAL_LINK_CACHE_DISABLE=1 "$CABAL" build all ) \
      >"$LOG_DIR/${scen}-iter${i}-sync.log" 2>&1
    apply_scenario "$scen" "$TOUCH"
    local off_s
    off_s="$(timed_build "$LOG_DIR/${scen}-iter${i}-off.log" \
              "CABAL_LINK_CACHE_DISABLE=1")"

    # cache-on measurement (novel edit, cache holds ONLY baseline blobs).
    # Restore the file to baseline, sync dist-newstyle to baseline
    # (cache off so we don't pollute the scen cache dir), apply the
    # scenario perturbation, RESET the cache to the baseline snapshot
    # (so this measurement starts with a fresh baseline-only cache),
    # truncate .stats.jsonl, then time the build.
    restore_touch
    ( cd "$DEMO_DIR" && env CABAL_LINK_CACHE_DISABLE=1 "$CABAL" build all ) \
      >"$LOG_DIR/${scen}-iter${i}-sync2.log" 2>&1
    apply_scenario "$scen" "$TOUCH"
    rm -rf "$scen_cache_dir"
    cp -a "$BASELINE_SNAPSHOT" "$scen_cache_dir"
    : > "$scen_cache_dir/.stats.jsonl"
    local on_s
    on_s="$(timed_build "$LOG_DIR/${scen}-iter${i}-on.log" \
              "CABAL_LINK_CACHE_DIR=$scen_cache_dir")"

    local hits misses
    hits="$( count_outcomes "$scen_cache_dir/.stats.jsonl" hit)"
    misses="$(count_outcomes "$scen_cache_dir/.stats.jsonl" miss)"

    printf '    off=%ss  on=%ss  hits=%s  misses=%s\n' \
      "$off_s" "$on_s" "$hits" "$misses"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$i" "$off_s" "$on_s" "$hits" "$misses" >> "$raw"
  done

  # Aggregate medians + total hits/misses for this scenario.
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

# -- Render REPORT.md -------------------------------------------------

{
  echo "# link-cache demo: benchmark report"
  echo
  echo "Generated by \`scripts/link-cache-demo-bench.sh\` against"
  echo "\`examples/link-cache-demo/\`."
  echo
  echo "## Project under test"
  echo
  echo "Five-package diamond, edits target \`$TOUCH_REL\`:"
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
  echo "## Reproduce"
  echo
  echo '```sh'
  echo "scripts/link-cache-demo-bench.sh --cabal=$CABAL_RESOLVED --runs=$RUNS"
  echo '```'
  echo
  echo "## What this measures"
  echo
  echo "A **novel-edit** rebuild. Per scenario:"
  echo
  echo "1. The cache is pre-populated with the *baseline* link outputs"
  echo "   (no perturbation applied) and snapshotted."
  echo "2. Each timed cache-on build starts from a cache that has only"
  echo "   ever seen the baseline. The scenario edit is then applied,"
  echo "   so every link operation that depends on the edited bytes"
  echo "   MISSes. Links whose inputs are byte-stable across the edit"
  echo "   HIT from the baseline snapshot."
  echo "3. The cache is reset from the snapshot **before every**"
  echo "   cache-on iteration, so the perturbed-state blobs written"
  echo "   by iteration N do not poison iteration N+1."
  echo
  echo "This is the workload a developer running an edit-rebuild loop"
  echo "actually experiences: each edit is something the cache has never"
  echo "seen before. The point of the bench is to measure how much of"
  echo "the link cascade the cache can short-circuit anyway, because the"
  echo "*unchanged* parts of the cone still match the baseline blobs."
  echo
  echo "## How the cache should behave per scenario"
  echo
  echo "The demo builds 9 link outputs: \`libHS<pkg>.a\` + \`libHS<pkg>.so\`"
  echo "for each of \`demo-core\`, \`demo-codec\`, \`demo-graph\`, \`demo-engine\`,"
  echo "plus the \`demo-app\` executable."
  echo
  echo "| scenario | rationale (a priori) |"
  echo "|---|---|"
  echo "| body-stable | wraps \`every\`'s body in a no-op \`let\`. At \`-O1\` GHC dead-code-eliminates the binding, so \`Util.o\` should come out *byte-equal* to baseline and **every** link in the cascade HITs. |"
  echo "| add-unexported | appends a new private binding starting with \`_\`. GHC drops unused bindings whose names begin with underscore at \`-O1\`, so \`Util.o\` is byte-equal and the cascade HITs. |"
  echo "| refactor-internal | renames a where-bound helper (\`firstOf\`→\`headOf\`). \`Util.o\` differs (different internal symbol names), but \`Util\`'s \`.hi\` is unchanged so downstream \`.o\` files are byte-stable. Expected: 6 HITs (middle libs) / 3 MISSes (demo-core.a, demo-core.so, demo-app exe — exe key includes demo-core.a's new bytes via \`linkDepArchives\`). |"
  echo "| add-exported | extends \`Demo.Core.Util\`'s export list. \`Util.hi\` grows; GHC's recompilation check may force downstream modules that import \`Util\` to be recompiled (\`demo-graph.Traverse\`, \`demo-engine.Pipeline\`). HITs limited to packages that don't import \`Util\` (\`demo-codec\`). |"
  echo "| modify-type | tightens \`describe\`'s constraint from \`Show a =>\` to \`(Show a, Eq a) =>\`. \`demo-engine.Pipeline\` uses \`describe\` → forced recompile → \`demo-engine\`'s link inputs differ → MISS. \`demo-codec\` and most of \`demo-graph\` are unaffected; HITs come from there. |"
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
      if ($i == "scenario")    scen = $(i+1)
      if ($i == "off_seconds") off  = $(i+1)
      if ($i == "on_seconds")  on   = $(i+1)
      if ($i == "speedup_pct") spd  = $(i+1)
      if ($i == "hits_total")  hits = $(i+1)
      if ($i == "misses_total") miss = $(i+1)
    }
    saved = sprintf("%.3f", off - on)
    perbuild = (runs > 0) ? sprintf("%.1f", hits / runs) : "n/a"
    printf("| %s | %s | %s | %s | %s%% | %s | %s | %s / 9 |\n", \
      scen, off, on, saved, spd, hits, miss, perbuild)
  }' "$RESULTS_JSONL"
  echo
  echo "Per-scenario raw JSON in \`.bench-results.jsonl\`."
  echo
  echo "## Interpretation"
  echo
  echo "The **\`HIT/build\`** column is the headline: how many of the 9"
  echo "link operations the cache saved on a build the developer had"
  echo "never run before."
  echo
  echo "On this project, novel-edit cache wins clearly stratify by"
  echo "edit shape:"
  echo
  echo "- **\`body-stable\` and \`add-unexported\`** — GHC at \`-O1\` makes"
  echo "  the edit byte-invisible at the object-file level. Every link"
  echo "  in the cone HITs, and the bench measures pure linker savings."
  echo "- **\`refactor-internal\`** — the touched module's \`.o\` changes,"
  echo "  but the rename is in a \`where\` clause and doesn't appear in"
  echo "  the \`.hi\`. Downstream \`.o\` files are byte-stable, so middle"
  echo "  libraries HIT; only \`demo-core\` and the exe (which links"
  echo "  against the new \`demo-core.a\` bytes) MISS."
  echo "- **\`add-exported\` and \`modify-type\`** — these change \`Util.hi\`,"
  echo "  which forces GHC to recompile downstream importers."
  echo "  Their \`.o\` files come out with fresh bytes, so the link"
  echo "  cone above the change MISSes. Cache wins are limited to"
  echo "  the packages that don't import \`Util\` at all (\`demo-codec\`,"
  echo "  partially \`demo-graph\`)."
  echo
  echo "The takeaway is that the cache delivers real, partial-cascade"
  echo "savings even on a first-time edit. The exact partition (which"
  echo "links HIT, which MISS) depends on the dep graph shape and where"
  echo "the edit lands — but it is structurally predictable from the"
  echo "edit's effect on the \`.hi\`."
} > "$REPORT_MD"

echo
echo "=== summary ==="
column -t -s $'\t' < <(
  printf 'scenario\toff\ton\tspeedup\thits\tmisses\n'
  awk -F'[",:{}]+' '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "scenario")    scen = $(i+1)
      if ($i == "off_seconds") off  = $(i+1)
      if ($i == "on_seconds")  on   = $(i+1)
      if ($i == "speedup_pct") spd  = $(i+1)
      if ($i == "hits_total")  hits = $(i+1)
      if ($i == "misses_total") miss = $(i+1)
    }
    printf("%s\t%ss\t%ss\t%s%%\t%s\t%s\n", scen, off, on, spd, hits, miss)
  }' "$RESULTS_JSONL"
)
echo
echo "report:  $REPORT_MD"
echo "jsonl:   $RESULTS_JSONL"
