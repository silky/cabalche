#!/usr/bin/env bash
# Bench the link-output cache against realistic edit-rebuild scenarios.
#
# Drives hydra (~/dev/w/hydra by default) through five edit shapes
# that span the spectrum from "library .hi stays byte-stable" (the
# cache's best case) to "exported type changes, every downstream
# .o has to be regenerated" (where the cache can't help). For each
# scenario we run hyperfine twice -- once with the cache disabled,
# once with it enabled -- and a diagnostic build afterwards to
# count [link-cache] HIT/MISS lines. The summary table lets us
# see the cache benefit per edit shape, not just on the
# comment-only microbench.
#
# Usage:
#   scripts/link-cache-bench-real.sh [<hydra-dir>] \
#       --cabal=PATH \
#       [--target=NAME] [--touch=PATH-REL-TO-HYDRA] \
#       [--runs=N] [--scenarios=a,b,c]
#
# Defaults: <hydra-dir>=~/dev/w/hydra, --target=hydra-node,
# --touch=hydra-prelude/src/Hydra/Prelude.hs, --runs=3,
# --scenarios=all (i.e. body-stable,add-unexported,add-exported,
# modify-type,refactor-internal).
#
# The script self-sources hydra's nix dev-env via
# `nix print-dev-env`, so it can be invoked from any shell.
# It also moves $HYDRA/.direnv aside for the duration of the
# run (restored on EXIT) so cabal.project's `packages: **/*.cabal`
# glob doesn't pull in HLS test fixtures with broken SPDX
# licenses.

set -euo pipefail

# `nix print-dev-env` doesn't reproduce the full hydra build env --
# in particular PKG_CONFIG_PATH comes out empty, so libsodium et al.
# aren't visible to cabal's dependency solver and the build dies in
# resolution. To get the same env an interactive `nix develop`
# would, we re-exec ourselves *through* `nix develop --command`.
# Hyperfine sub-bashes inherit our env, so every timed run gets
# the same setup.
#
# Pre-scan args for a positional --hydra override so we know which
# flake to enter. Full arg parsing happens after the re-exec.
HYDRA="$HOME/dev/w/hydra"
for arg in "$@"; do
  if [[ "$arg" != --* && "$arg" != "-h" ]]; then
    HYDRA="$arg"
    break
  fi
done

if [[ -z "${LINK_CACHE_BENCH_NIX_REEXEC:-}" && -d "$HYDRA" ]]; then
  HYDRA="$(cd "$HYDRA" && pwd)"
  echo ">>> entering hydra nix develop shell ($HYDRA)"
  export LINK_CACHE_BENCH_NIX_REEXEC=1
  # Use git+file:// rather than path:// so nix enumerates the
  # source via git and skips untracked junk -- e.g. unix sockets
  # left over from `demo/devnet` runs, which `path:` can't copy
  # into the store and which would otherwise blow up with
  # "unsupported file type".
  exec nix develop "git+file://$HYDRA" --command bash "$0" "$@"
fi

CABAL=""
TARGET="hydra-node"
TOUCH_REL="hydra-prelude/src/Hydra/Prelude.hs"
RUNS=3
SCENARIOS="body-stable,add-unexported,add-exported,modify-type,refactor-internal"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cabal=*)       CABAL="${1#*=}"; shift ;;
    --target=*)      TARGET="${1#*=}"; shift ;;
    --touch=*)       TOUCH_REL="${1#*=}"; shift ;;
    --runs=*)        RUNS="${1#*=}"; shift ;;
    --scenarios=*)   SCENARIOS="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    *)
      if [[ ! "$1" == --* && -z "${HYDRA_OVERRIDE:-}" ]]; then
        HYDRA="$1"
        HYDRA_OVERRIDE=1
      else
        echo "error: unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

[[ -z "$CABAL" ]] && { echo "error: --cabal=PATH is required" >&2; exit 2; }
[[ -d "$HYDRA" ]] || { echo "error: hydra-dir does not exist: $HYDRA" >&2; exit 2; }
HYDRA="$(cd "$HYDRA" && pwd)"
TOUCH="$HYDRA/$TOUCH_REL"
[[ -f "$TOUCH" ]] || { echo "error: touch file not found: $TOUCH" >&2; exit 2; }

# Sanity-check the nix dev-env actually provided what cabal needs.
# If pkg-config can't see libsodium, the build will fail in
# resolution -- catch that here with a clear message rather than
# letting cabal's error confuse things.
if ! command -v pkg-config >/dev/null 2>&1 \
   || ! pkg-config --exists libsodium 2>/dev/null; then
  echo "error: nix dev-env did not provide pkg-config + libsodium" >&2
  echo "       (PKG_CONFIG_PATH=$PKG_CONFIG_PATH)" >&2
  exit 2
fi

# Startup checks.
for cmd in hyperfine jq nix git sed grep awk column; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "error: required command not found on PATH: $cmd" >&2; exit 2; }
done
CABAL_RESOLVED="$(command -v "$CABAL" 2>/dev/null || true)"
[[ -z "$CABAL_RESOLVED" ]] && { echo "error: cabal binary not executable: $CABAL" >&2; exit 2; }

# Refuse to run if the user has uncommitted edits on the touch
# file -- we'd lose them when restoring with `git checkout`.
if [[ -n "$(git -C "$HYDRA" status --porcelain -- "$TOUCH_REL" 2>/dev/null)" ]]; then
  echo "error: working-tree changes on $TOUCH_REL -- commit or stash first" >&2
  exit 2
fi

echo ">>> hydra:   $HYDRA"
echo ">>> cabal:   $CABAL_RESOLVED"
("$CABAL" --version 2>/dev/null || true) | sed 's/^/    /'
echo ">>> target:  $TARGET"
echo ">>> touch:   $TOUCH_REL"
echo ">>> runs:    $RUNS"
echo ">>> scens:   $SCENARIOS"
echo

WORK="$(mktemp -d -t link-cache-bench-real.XXXXXX)"
CACHE_DIR="$WORK/cache"
LOG_DIR="$WORK/logs"
JSON_DIR="$WORK/json"
RESULT_TSV="$WORK/results.tsv"
BENCH_PROJECT="$WORK/bench.project"
DIRENV_BACKUP=""

mkdir -p "$CACHE_DIR" "$LOG_DIR" "$JSON_DIR"

cleanup() {
  local rc=$?
  # Restore the touch file no matter what, otherwise an aborted
  # mid-scenario run leaves the working tree dirty.
  git -C "$HYDRA" checkout -- "$TOUCH_REL" 2>/dev/null || true
  # Restore .direnv if we moved it aside.
  if [[ -n "$DIRENV_BACKUP" && -d "$DIRENV_BACKUP" ]]; then
    mv "$DIRENV_BACKUP" "$HYDRA/.direnv" 2>/dev/null || true
  fi
  if (( rc != 0 )); then
    echo "build artifacts preserved in: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# Move .direnv aside: its HLS test fixtures contain intentionally-
# malformed .cabal files that crash cabal's parser when the
# project's `packages: **/*.cabal` glob pulls them in.
if [[ -d "$HYDRA/.direnv" ]]; then
  DIRENV_BACKUP="$WORK/direnv-stash"
  echo ">>> stashing $HYDRA/.direnv to $DIRENV_BACKUP for the run"
  mv "$HYDRA/.direnv" "$DIRENV_BACKUP"
fi

# Build a bench.project that imports hydra's cabal.project but
# strips the `packages: **/*.cabal` glob and substitutes an
# explicit list of hydra-* dirs. This is the second half of the
# .direnv defense -- if `direnv reload` re-runs during the bench
# we still won't scan flake-inputs.
{
  grep -v '^packages:' "$HYDRA/cabal.project"
  echo
  echo "packages:"
  for d in "$HYDRA"/hydra-*/ "$HYDRA"/hydraw/; do
    [[ -d "$d" ]] || continue
    [[ -n "$(find "$d" -maxdepth 1 -name '*.cabal' -print -quit)" ]] || continue
    printf '  %s\n' "$d"
  done
} > "$BENCH_PROJECT"

# -- Scenarios --------------------------------------------------
#
# Each apply_* function mutates $1 (the touch file) in a specific
# shape. Restore is a uniform `git checkout -- $TOUCH_REL`,
# called from prepare_state.
#
# All scenarios assume the file is in its just-checked-out (clean
# upstream) state when the apply_* function runs. The setup phase
# below ensures dist-newstyle is in sync with the clean upstream
# content before any iterations start.

apply_scenario_body_stable() {
  # Wrap padRight's body in a no-op `let`. Type-preserving body
  # change inside an exported function. .hi should stay
  # interface-hash-stable -- GHC's recompilation checker is
  # supposed to see no change in the exported signature, so
  # downstream .o files shouldn't be regenerated and the cache
  # should HIT all the way down.
  sed -i 's|^padRight c n str = T\.take n|padRight c n str = let _bench = (0 :: Int) in T.take n|' "$1"
}

apply_scenario_add_unexported() {
  # Append a new top-level binding that is NOT in the export
  # list. Touched lib's own .a misses (new .o); downstream
  # should still HIT because the .hi-visible interface is
  # unchanged (this binding is private to the module).
  cat >> "$1" <<'EOF'

_benchUnexported :: Int -> Int
_benchUnexported x = x + 1
EOF
}

apply_scenario_add_exported() {
  # Append a new top-level binding AND extend the export list.
  # The .hi grows by one symbol -- probes whether GHC's
  # fine-grained interface check keeps downstream stable when
  # the new export is unused, or whether cabal-install
  # pessimistically cascades.
  sed -i '/^) where$/i\  _benchExported,' "$1"
  cat >> "$1" <<'EOF'

_benchExported :: Int -> Int
_benchExported x = x + 1
EOF
}

apply_scenario_modify_type() {
  # Real signature change to an exported function: change spy's
  # `Show a => a -> a` to `(Show a, Eq a) => a -> a` (additional
  # constraint). Downstream callsites typically have Eq for
  # whatever they're passing through (most hydra types derive
  # Eq), so the build should succeed. The exported signature
  # changes meaningfully -- worst case for the cache.
  sed -i 's|^spy :: Show a => a -> a$|spy :: (Show a, Eq a) => a -> a|' "$1"
}

apply_scenario_refactor_internal() {
  # Day-to-day refactor: eta-expand decodeBase16 and inline the
  # composition into a parenthesised expression. Pure body
  # change, signature unchanged, .hi stable, downstream
  # should HIT.
  sed -i 's|^decodeBase16 =$|decodeBase16 input =|' "$1"
  sed -i 's|^  either fail pure \. Base16\.decode \. encodeUtf8$|  either fail pure (Base16.decode (encodeUtf8 input))|' "$1"
}

# Export functions so hyperfine's sub-shell (--shell bash) can
# invoke them from inside --prepare.
export -f apply_scenario_body_stable apply_scenario_add_unexported \
          apply_scenario_add_exported apply_scenario_modify_type \
          apply_scenario_refactor_internal

# -- Driver -----------------------------------------------------

cabal_build() {
  "$CABAL" build --project-file="$BENCH_PROJECT" "$TARGET" "$@"
}
export -f cabal_build
export CABAL BENCH_PROJECT TARGET HYDRA TOUCH_REL TOUCH

# One-time setup: get dist-newstyle fully built for the clean
# upstream state. Every hyperfine --prepare brings the file back
# to this state, so the subsequent no-op cabal build inside
# prepare is cheap (cabal sees content matches its tracked
# hash).
echo ">>> setup build (untimed)"
( cd "$HYDRA" && cabal_build ) >"$LOG_DIR/setup.log" 2>&1 \
  || { echo "error: setup build failed; last 50 lines of log:" >&2; tail -n 50 "$LOG_DIR/setup.log" >&2; exit 1; }

printf 'scenario\tcache_off_ms\tcache_off_stddev_ms\tcache_on_ms\tcache_on_stddev_ms\tdelta_ms\tspeedup_pct\thits\tmisses\thit_pct\n' \
  > "$RESULT_TSV"

run_scenario() {
  local scen="$1"
  local scen_func="apply_scenario_${scen//-/_}"

  if ! declare -F "$scen_func" >/dev/null; then
    echo "error: unknown scenario '$scen' (no function $scen_func)" >&2
    return 2
  fi

  echo
  echo "=== scenario: $scen ==="

  # Hyperfine --prepare for this scenario. Restore the file,
  # let cabal re-sync (cheap no-op since content matches the
  # cached state), then apply the scenario perturbation.
  local prep
  prep="git -C '$HYDRA' checkout -- '$TOUCH_REL' \
        && cd '$HYDRA' && cabal_build >/dev/null 2>&1 \
        && $scen_func '$TOUCH'"

  # Cache-off measurement.
  echo "--- cache off"
  hyperfine \
    --shell bash \
    --prepare "$prep" \
    --warmup 1 \
    --runs "$RUNS" \
    --export-json "$JSON_DIR/${scen}-off.json" \
    "cd '$HYDRA' && CABAL_LINK_CACHE_DISABLE=1 cabal_build"

  # Clear cache so cache-on starts from a clean cold state for
  # this scenario. Hyperfine's --warmup will populate.
  rm -rf "$CACHE_DIR"/* 2>/dev/null || true

  # Cache-on measurement.
  echo "--- cache on"
  hyperfine \
    --shell bash \
    --prepare "$prep" \
    --warmup 1 \
    --runs "$RUNS" \
    --export-json "$JSON_DIR/${scen}-on.json" \
    "cd '$HYDRA' && CABAL_LINK_CACHE_DIR='$CACHE_DIR' cabal_build"

  # Diagnostic build: cache is now populated (from hyperfine's
  # --warmup + timed runs). One more build gives a representative
  # steady-state HIT/MISS line count for this scenario.
  echo "--- diagnostic (steady-state HIT/MISS)"
  eval "$prep"
  ( cd "$HYDRA" && CABAL_LINK_CACHE_DIR="$CACHE_DIR" cabal_build ) \
    >"$LOG_DIR/${scen}-diag.log" 2>&1 || true
  local hits misses total hit_pct
  hits=$(grep -c '\[link-cache\] HIT' "$LOG_DIR/${scen}-diag.log" 2>/dev/null || true)
  misses=$(grep -c '\[link-cache\] MISS' "$LOG_DIR/${scen}-diag.log" 2>/dev/null || true)
  hits=${hits:-0}
  misses=${misses:-0}
  total=$(( hits + misses ))
  if (( total > 0 )); then
    hit_pct=$(awk -v h="$hits" -v t="$total" 'BEGIN { printf "%.1f", h * 100 / t }')
  else
    hit_pct="n/a"
  fi

  # Pull medians out of hyperfine's JSON.
  local off_med off_sd on_med on_sd delta speedup
  off_med=$(jq -r '.results[0].median * 1000 | floor' "$JSON_DIR/${scen}-off.json")
  off_sd=$(jq -r  '.results[0].stddev * 1000 | floor' "$JSON_DIR/${scen}-off.json")
  on_med=$(jq -r  '.results[0].median * 1000 | floor' "$JSON_DIR/${scen}-on.json")
  on_sd=$(jq -r   '.results[0].stddev * 1000 | floor' "$JSON_DIR/${scen}-on.json")
  delta=$(( off_med - on_med ))
  if (( off_med > 0 )); then
    speedup=$(awk -v d="$delta" -v o="$off_med" 'BEGIN { printf "%.1f", d * 100 / o }')
  else
    speedup="n/a"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scen" "$off_med" "$off_sd" "$on_med" "$on_sd" "$delta" "$speedup" \
    "$hits" "$misses" "$hit_pct" >> "$RESULT_TSV"

  echo ">>> $scen: off=${off_med}ms on=${on_med}ms Δ=${delta}ms speedup=${speedup}% hits=$hits misses=$misses hit%=${hit_pct}"
}

IFS=',' read -ra SCEN_LIST <<< "$SCENARIOS"
for s in "${SCEN_LIST[@]}"; do
  run_scenario "$s"
done

echo
echo "=== summary ==="
column -t -s $'\t' "$RESULT_TSV"
