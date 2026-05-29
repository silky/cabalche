# Link-output cache: release-gate criteria

The content-addressed link cache implemented in
`Distribution.Simple.GHC.LinkManifest` is a correctness-preserving
optimisation: by construction, every cache HIT replaces a linker
invocation with a byte-copy of an output that the linker is *claimed*
to have produced from byte-equal inputs on this toolchain.

That claim is asserted in `Note [Link manifest cache]` in
`Distribution.Simple.GHC.Build.Link`. It is **not yet verified** for
the toolchain matrix Cabal ships against. This document records the
gate that has to be cleared before the cache is enabled by default.

## Default-off until verified

Until the criteria below are met:

* The cache stays opt-in via the environment. A user who sets
  `CABAL_LINK_CACHE_DIR=/some/path` (or relies on the default XDG
  cache root being writable) gets the cache.
* No build configuration writes a cabal-default that turns the
  cache on for users who have not opted in.
* The changelog entry continues to label the feature
  **experimental**.

## The canary gate

The `CABAL_LINK_CACHE_VERIFY=1` mode re-runs the linker on every HIT
and byte-compares its fresh output against the cached blob. Any
mismatch emits `[link-cache] HIT-DIVERGED` and dumps both files
under `<cacheDir>/divergences/<key>/` for offline inspection.

Before flipping the cache to default-on, we need canary data that
covers the supported toolchain matrix.

**Coverage matrix** (intersected with what Cabal CI already runs):

| Platform   | GHC versions      | Linker(s)         |
|------------|-------------------|-------------------|
| Linux/x64  | All in `bootstrap/linux-*.json` | gold, lld, mold (when packaged) |
| Linux/arm  | All ditto          | system ld         |
| macOS/x64  | Whatever the macos runner ships | ld64              |
| macOS/arm  | Same as above      | ld64              |
| Windows/x64| Same as above      | mingw ld          |

For each cell we want:

1. **Volume**: at least 100k cache HITs observed under VERIFY mode
   across non-trivial projects (Cabal's own test-suite hits this
   threshold quickly; large downstream consumers help saturate).
2. **Duration**: at least 30 consecutive days with zero
   `HIT-DIVERGED` lines on that cell.
3. **Diversity**: HITs spread across all six wrapped tools
   (`ar-static`, `ar-prof`, `ld-ghci`, `ld-ghci-prof`,
   `ghc-shared`, `ghc-shared-prof`, `ghc-staticlib`,
   `ghc-bytecode-dyn`, `ghc-bytecode-static`, `ghc-link-exe`,
   `ghc-link-flib`). A clean Linux/x64 canary that never exercised
   `ghc-link-flib` does not clear that tool for default-on.

## Failure handling

A `HIT-DIVERGED` event during the canary period blocks default-on
across the whole matrix, not just the cell where it fired:

1. Reproduce on the affected cell with `CABAL_LINK_CACHE_VERIFY_FAIL=1`
   so the build halts at the divergence and the dumped pair is
   preserved.
2. Diff the linker output against the cached blob; classify the
   source (PE timestamp, Mach-O LC_UUID, build-id leakage, debug
   info path, ad-hoc signature, etc.).
3. Add the offending input to the cache key (most cases) or extend
   `wipeMetadata`-style scrubbing to the tool (when the
   non-determinism is in the tool's output and easy to suppress).
4. Restart the clock. The 30-day count is reset on every fix; we
   are looking for **stability**, not absence of historical
   divergence.

## Telemetry sources

The canary cells consume these streams:

* Cabal CI itself, with `CABAL_LINK_CACHE_VERIFY=1` exported across
  the link-cache test job. Already wired (see `link-cache-ci.md`);
  the verify mode just needs to be enabled there.
* A handful of downstream maintainers running with VERIFY on. The
  ask is small: set the env var, ship us the `.stats.jsonl` and any
  `divergences/` dumps once a month.
* A nightly CI job that does a clean checkout, populates the cache,
  then runs a second clean build under VERIFY against the populated
  cache. Catches divergence on the first warm hit, which is when
  the cache is most likely to be wrong (everything else is a copy
  of an already-verified blob).

The aggregator in `scripts/link-cache-summary.sh` already reports
hit-vs-verify counts; a future commit will add a `--verify-only`
flag that filters telemetry down to the cells we are gating on.

## When the gate clears

When the matrix above is green for the required duration and HIT
volume:

1. Flip the changelog entry from `experimental` to a stability
   statement.
2. Update `Note [Link manifest cache]` to cite the canary results
   as evidence rather than as an unsupported claim.
3. Consider a `cabal-install` flag that turns the cache on by
   default for new projects, leaving the env vars as the override
   mechanism.

Cross-machine sharing (the nix-store and bespoke-HTTP sketches in
`link-cache-future.md`) requires a stricter version of the same
gate: at minimum, the canary period continues uninterrupted for
the duration that the cross-machine cache has been receiving writes
from untrusted-but-signed peers, and divergence-of-signed-blob is
treated as a build error not a warning.
