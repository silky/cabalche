#!/usr/bin/env bash
# Demonstrate the link-output cache.
#
# Builds a small library + executable twice with the patched cabal:
#
#   1. cold cache  -> every link step prints "[link-cache] MISS"
#                     (the cache is populating; this build pays full price)
#   2. warm cache  -> we delete the whole dist directory and rebuild
#                     from scratch. GHC re-emits byte-identical .o
#                     files (the compiler is deterministic), so every
#                     link-step input hashes the same way as build #1
#                     and prints "[link-cache] HIT" instead of running
#                     the linker.
#
# Then it tails the per-link telemetry that the cache appends to
# .stats.jsonl and runs the existing aggregator.
#
# Usage:
#   scripts/link-cache-demo.sh [path/to/cabal]
#
# If no cabal is given the script uses ./result/bin/cabal (the nix
# flake's `nix build .#cabal` output).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CABAL="${1:-$REPO/result/bin/cabal}"

if [[ ! -x "$CABAL" ]]; then
  echo "error: cabal binary not found or not executable: $CABAL" >&2
  echo "       hint: run 'nix build .#cabal -o result' first" >&2
  exit 1
fi

# Temp project + isolated cache root so we never touch the user's
# XDG_CACHE_HOME / dist-newstyle / global config.
DEMO_DIR="$(mktemp -d -t link-cache-demo.XXXXXX)"
CACHE_DIR="$DEMO_DIR/cache"
PROJ_DIR="$DEMO_DIR/proj"
trap 'rm -rf "$DEMO_DIR"' EXIT

mkdir -p "$CACHE_DIR" "$PROJ_DIR/src/Lib" "$PROJ_DIR/app"

cat > "$PROJ_DIR/cabal.project" <<EOF
packages: .
EOF

cat > "$PROJ_DIR/demo.cabal" <<EOF
cabal-version: 2.2
name: demo
version: 0.1
build-type: Simple

library
  hs-source-dirs: src
  default-language: Haskell2010
  exposed-modules: Lib.M0, Lib.M1, Lib.M2, Lib.M3, Lib.M4
  build-depends: base

executable demo
  hs-source-dirs: app
  default-language: Haskell2010
  main-is: Main.hs
  build-depends: base, demo
EOF

for i in 0 1 2 3 4; do
  cat > "$PROJ_DIR/src/Lib/M$i.hs" <<EOF
module Lib.M$i where

greeting$i :: String
greeting$i = "hello from M$i"
EOF
done

cat > "$PROJ_DIR/app/Main.hs" <<'EOF'
module Main where

import qualified Lib.M0
import qualified Lib.M1
import qualified Lib.M2
import qualified Lib.M3
import qualified Lib.M4

main :: IO ()
main = do
  putStrLn Lib.M0.greeting0
  putStrLn Lib.M1.greeting1
  putStrLn Lib.M2.greeting2
  putStrLn Lib.M3.greeting3
  putStrLn Lib.M4.greeting4
EOF

export CABAL_LINK_CACHE_DIR="$CACHE_DIR"
export CABAL_DIR="$DEMO_DIR/cabal-home"

# --store-dir is a top-level option (not a build option). The demo
# only depends on `base`, which is in the GHC global db, so --offline
# works without a populated Hackage index.
TOPOPTS=(--store-dir="$DEMO_DIR/store")
BUILDOPTS=(--offline --builddir="$PROJ_DIR/dist")

section() {
  printf '\n\033[1;36m===== %s =====\033[0m\n\n' "$*"
}

section "1/4  Build #1 (cold cache, expect MISS lines)"
( cd "$PROJ_DIR" && "$CABAL" "${TOPOPTS[@]}" build "${BUILDOPTS[@]}" 2>&1 ) | tee "$DEMO_DIR/build1.log"

if ! grep -q "\[link-cache\] MISS" "$DEMO_DIR/build1.log"; then
  echo "FAIL: cold build did not emit any [link-cache] MISS lines" >&2
  exit 2
fi

section "2/4  Wipe dist (simulates a fresh checkout / cabal clean)"
# cabal v2-build's incremental tracking would otherwise treat the
# build as up-to-date and skip both compile and link. Nuking dist
# forces a full rebuild; GHC's deterministic .o output means the
# link inputs still hash to the same cache key.
rm -rf "$PROJ_DIR/dist"

section "3/4  Build #2 (warm cache, expect HIT lines, no MISS)"
( cd "$PROJ_DIR" && "$CABAL" "${TOPOPTS[@]}" build "${BUILDOPTS[@]}" 2>&1 ) | tee "$DEMO_DIR/build2.log"

if grep -q "\[link-cache\] MISS" "$DEMO_DIR/build2.log"; then
  echo "FAIL: warm build emitted MISS lines (cache did not engage)" >&2
  exit 3
fi
if ! grep -q "\[link-cache\] HIT" "$DEMO_DIR/build2.log"; then
  echo "FAIL: warm build did not emit any [link-cache] HIT lines" >&2
  exit 4
fi

section "4/4  Telemetry"
printf 'Raw per-link records (%s):\n' "$CACHE_DIR/.stats.jsonl"
cat "$CACHE_DIR/.stats.jsonl"
echo

if command -v jq >/dev/null 2>&1; then
  echo "Aggregated via scripts/link-cache-summary.sh:"
  "$REPO/scripts/link-cache-summary.sh" "$CACHE_DIR/.stats.jsonl"
else
  echo "(install jq to see the per-tool aggregation)"
fi

section "Demo complete"
echo "Cold build  : $(grep -c "\[link-cache\] MISS" "$DEMO_DIR/build1.log") MISS, $(grep -c "\[link-cache\] HIT" "$DEMO_DIR/build1.log") HIT"
echo "Warm build  : $(grep -c "\[link-cache\] MISS" "$DEMO_DIR/build2.log") MISS, $(grep -c "\[link-cache\] HIT" "$DEMO_DIR/build2.log") HIT"
