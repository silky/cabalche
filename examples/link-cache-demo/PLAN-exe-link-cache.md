# Plan: cache the exe link properly (was SKIPPED in `--make` mode)

> **Status: ✅ Implemented.** Plan kept for the record. The
> follow-up section "Measured outcome" near the bottom captures the
> deltas the implementation actually delivered against the demo and
> against the hydra A/B that motivated the work.

This is a focused follow-up to Finding 1 in
[`INVESTIGATION.md`](./INVESTIGATION.md). That finding closed the
*soundness* gap (a spurious HIT) by SKIPPING the exe cache whenever
cabal sees `--make` mode. Safe, but it left **the biggest single
link step in most projects uncached** — and a real-world A/B
measurement (see "Motivating evidence" below) suggested this was
the largest unrealized win on the table.

## TL;DR

- **Before.** Every exe link in cabal v3's default flow logged
  `[link-cache] SKIPPED (ghc-link-exe) … cache key not trusted` and
  ran the full linker, regardless of whether the cache already
  held a byte-equal exe.
- **Why.** In `--make` mode the linker invocation has only
  `Main.hs` as a tracked input; the dep archives and home-package
  `.o` files are produced by the same GHC invocation that does the
  link, so they aren't on disk when the cache key needs to be
  computed.
- **Done.** Split exe building so the link pass uses explicit
  objects (no `--make`) and the dep list comes from
  `componentIncludes clbi` rather than the post-`--make`-flattened
  `ghcOptPackages`. The link pass now mirrors the library-link
  pattern cabal already uses: explicit object inputs, well-formed
  cache key.
- **Measured outcome.** Demo: 8/9 → 9/9 HITs and a ~37% → ~70%
  speedup on the two saturated scenarios (`body-stable`,
  `add-unexported`) — the demo is small enough that this is the
  whole gain. Hydra A/B (full table at the bottom of this doc)
  widened the `add-unexported/hydra-node` *edit* speedup from
  +14.9% (lib cache only, exe SKIPPED) to **+49.3%** — driven by
  the exe link's wall-time share now being recoverable.

## Motivating evidence

The link-cache A/B harness
([`scripts/link-cache-compare.sh`](../../scripts/link-cache-compare.sh))
was run against the
[`hydra`](https://github.com/cardano-scaling/hydra) repo with a
small set of patches simulating realistic edits. The fully
worked-up reports live in `~/dev/w/tmp/cacheable/reports/`. The
relevant headline numbers:

| scenario           | target         | speedup | HITs / misses |
|---|---|---:|---:|
| add-unexported     | hydra-node     |  +14.9% | 107 / 23      |
| body-stable        | hydra-node     |   +1.1% |  33 / 97      |
| add-exported       | hydra-node     |   +1.4% |  22 / 108     |
| (any)              | hydra-prelude  |  -2…-7% |  ≤11 / ≤6     |

Of those 130 misses/HITs per scenario, **the exe link itself is
counted as `skipped`** — it never appears in the HIT or MISS column
at all. The exe link is, on hydra-node specifically, plausibly the
single longest link step in the project (~100 packages → one
binary). Caching it would convert several seconds of every revert
build into a copy-from-blob.

The hydra-prelude rows are intentionally included to make a second
point: where there is no exe involved (it's a library), and the
build is dominated by cabal-install's planner overhead, the cache
already extracts the cheap wins. The remaining headroom is on the
exe side.

## Why it's hard to cache today

The exe link path is at
`Cabal/src/Distribution/Simple/GHC/Build/Link.hs:491` (function
`linkExecutable`). In cabal v3's default flow the link is invoked
as part of a single `ghc --make` call:

```
ghc --make -o bin/myexe app/Main.hs -package-id <home-pkg-uid>
```

That one invocation does three things:

1. compiles `Main.hs` and every home-package module it transitively
   imports into `.o` files under `<exe-tmp>/`,
2. resolves the transitive `-package-id` list by walking imports
   (the `-package-id` flags cabal passes are *not* the complete
   set — GHC adds more itself), and
3. links the result.

`linkExecutable` builds the cache key just before (3). At that
moment:

- `ghcOptInputFiles` is `[Main.hs]` (the source).
- `ghcOptPackages` is `[home-pkg-uid]` (or empty).
- The home-package `.o` files don't exist on disk yet — step (1)
  hasn't run.
- `linkDepArchives` searches the IPI + `-L` paths + the in-tree
  build dir for archives matching `ghcOptPackages`; with only one
  unit ID in there and the archives not yet on disk, it usually
  returns `Just []`.

So the natural cache key — `(tool, target-basename, toolchain-id,
sorted hashes of inputs)` — would degenerate to `(ghc-link-exe,
myexe, <toolchain>, hash-of(Main.hs))`. That HITs on the very
first re-build of the same project regardless of what the deps did,
which is exactly the unsoundness Finding 1 caught. The current
SKIP is the conservative response: refuse to HIT when the key is
under-keyed.

## The proper fix

Match what lib builds already do. `linkLibrary` (same module,
~line 246) operates on:

- an explicit list of `objectFiles` (already on disk),
- `clbi`'s component-local dep info,
- explicit toolchain options.

Its cache key is therefore well-formed, and there's no `--make`
skip. Exes should follow the same structure:

1. **Compile pass.** Run `ghc --make -fno-link` (or the equivalent
   pre-existing path used for `lib`'s module compilation). After
   this pass, all home-package `.o` files for the exe exist under
   `<exe-tmp>/`.
2. **Link pass.** Run `ghc -o <target> <enumerated .o files>
   -package-id <dep-uid> …` with the full dep list resolved from
   `componentPackageDeps clbi`. This pass has no source files in
   `ghcOptInputFiles`, no `--make`, and the cache wraps it
   normally.

The link pass's cache key becomes:

```
(ghc-link-exe, target-basename, toolchain-id,
 sorted xxh3 of: home-package .o files + dep .a/.so archives)
```

Which is structurally identical to a library link's key. Same
soundness invariants, same HIT/MISS semantics, same canary-verify
behaviour.

## Implementation steps

1. **Refactor the exe build path** in
   `Cabal/src/Distribution/Simple/GHC/Build.hs` (and the helpers it
   composes from `Build/Modules.hs`, `Build/ExtraSources.hs`,
   `Build/Link.hs`): split the existing single `--make` invocation
   into compile + link. The lib path already does this — most of
   the helpers exist; the change is mostly about *not* short-
   circuiting them on exe components.

2. **Enumerate the post-compile objects.** Look at
   `getHaskellObjects` / the `<exe-tmp>/*.o` glob that lib builds
   use. The exe-build path already creates `<exe-tmp>/`, just
   doesn't enumerate it for re-linking purposes.

3. **Thread `ClbiBuildInfo` (or the relevant `clbi`) into
   `linkExecutable`.** The call site at `Build/Link.hs:231`
   already has `clbi` in scope; the signature change is local.

4. **Replace the `ghcOptPackages`-based starting set in
   `linkDepArchives`** with the union of (a) `ghcOptPackages`
   and (b) `[uid | (uid, _) <- componentPackageDeps clbi]`. clbi
   has the planner-authoritative list; ghcOptPackages is the
   reduced post-flattening view that's incomplete in `--make`.

5. **Drop the `--make`-mode SKIP branch.** With explicit object
   inputs and a complete dep list, the key is always well-formed
   for an exe link. The `hasHsInputs` check becomes unreachable;
   delete it. The "dep-archive walk incomplete" SKIP for the
   `Nothing` case stays (it's a different, narrower escape hatch).

6. **Add a regression test.** Extend
   `cabal-testsuite/PackageTests/LinkCacheHit/` (or create
   `LinkCacheExeHit/`) with an exe-link relink-HIT assertion. The
   existing fixtures only exercise lib links — both the
   pre-Finding-1 spurious-HIT behaviour and the post-fix SKIP
   silently pass an HIT test that never checks the exe.

7. **Re-run benches.** `scripts/link-cache-demo-bench.sh` should
   show `demo-app` HIT on body-stable / add-unexported / etc.
   `scripts/link-cache-compare.sh` on hydra-node should show the
   +14.9% widen.

## Risks and mitigations

- **Doubled GHC invocations on cold builds.** A `-fno-link` pass
  followed by an explicit link pass = two GHC processes where today
  there's one. Mitigation: on cold builds the second pass is a
  small link; on steady-state builds the first pass is a fast
  recompilation-check no-op. Expected overhead is in the
  one-planner-pass range (~50–500ms per exe), well below the link
  step's cost. **Measure on the demo and a realistic project
  before/after**; if the regression on cold builds exceeds ~5%,
  revisit with a single-`--make` fallback gated on cache-disabled.

- **C sources in `c-sources`.** Exes with `.c` files compile them
  to `.o` and link them in. The link pass must enumerate those too.
  Pattern is the same as for lib `c-sources` builds. Worth covering
  with a fixture (extend `LinkCacheHit` with a `c-sources` package).

- **Custom `ld-options` / linker scripts.** Anything currently passed
  once to the combined `--make` invocation must be split into
  compile-time vs. link-time flag sets. The lib path does this
  already (see `compileWhole` / `compileMods` vs. `linkLibrary` in
  `Build.hs`); the exe split inherits the same convention.

- **Backwards compatibility.** Nothing about this change alters
  cabal's outward interface — `.cabal` file semantics,
  `dist-newstyle` layout, `cabal build` exit codes — all unchanged.
  The only observable difference is one more GHC process per exe
  build (and one fewer `[link-cache] SKIPPED` log line per exe).

## Expected gain

The theoretical ceiling is the wall-time the exe linker takes,
recovered fully on every cache HIT.

- **Demo project** (`examples/link-cache-demo/`): `demo-app` is
  tiny; its link is sub-second. The headline `REPORT.md` numbers
  won't move much. The qualitative change — `demo-app` reaching
  `hit` on `body-stable` and `add-unexported` — is what we'd
  verify here. Useful as the regression-test signal, not as the
  selling point.
- **hydra-node-class projects** (~100 deps, ~hundreds of MB
  linked exe): exe link is in the 2–10 s range per invocation.
  Caching it should add 1–8 s of speedup to revert-style rebuilds
  *on top of* the lib-link savings. Per the hydra A/B above:
  `add-unexported/hydra-node` is currently 21 s → 18 s (+14.9%);
  with the exe link cached, plausible target is 21 s → 13–15 s
  (~30%). `body-stable/hydra-node` is currently 202 s → 200 s
  (+1.1%); the exe link is a single-digit percent of 200 s, so
  this scenario only moves to ~+3–5%. The biggest relative gain
  is where the exe link is a larger share of the total
  rebuild — i.e. smaller projects whose lib graph already
  HITs broadly.
- **Heavily statically-linked CLIs / TUIs** (cabal itself, hls,
  `hydra-tui`, etc.): exe link can be 10–30 s. Caching doubles or
  triples the user-visible speedup on revert-style edits.

## Verification plan

1. **Demo**: rerun `bash scripts/link-cache-demo-bench.sh --runs=3
   --verify`; expect the `demo-app` row of the per-target table
   to flip from `skipped` to `3/3` HIT on scenarios where it was
   previously `skipped` (which after Finding 1's fix is every
   scenario).
2. **Demo soundness**: the same `--verify` run must continue to
   pass — no `HIT-DIVERGED` on `demo-app`.
3. **Cabal-testsuite**: the new `LinkCacheExeHit` fixture must
   pass; `LinkCacheHit`, `LinkCacheStat`, `LinkCacheStats`,
   `LinkCacheStaleStamp`, `LinkCacheGC`, `LinkCacheDivergence`
   must continue to pass unchanged.
4. **Hydra A/B**: rerun
   `~/dev/w/tmp/cacheable/run-bench.sh` (or equivalent) once with
   the unchanged fork and once with the prototype; expect
   `add-unexported/hydra-node` and `body-stable/hydra-node`
   speedups to widen by the exe link's wall-time share. The HITs
   column for cabal-b should grow by `(exe link steps × N
   iterations)`.
5. **Cold-build regression**: time `cabal build hydra-node` from
   `rm -rf dist-newstyle` before/after; the delta should be
   ≤5%. If higher, the split-into-two-GHC-invocations cost is
   not amortised well enough and the design needs revisiting.

## Out of scope (file separately if pursued)

- Caching the **lib link's** GHC-internal `-package-id` resolution
  step. Today lib builds work fine because the planner has the
  full dep list. No change needed.
- Cross-user / cross-machine cache sharing. See
  [`doc/internal/link-cache-future.md`](../../doc/internal/link-cache-future.md).
- Closing the `whitespace-only` / line-shift `.o` non-determinism
  gap (Finding 3 in `INVESTIGATION.md`). Different mechanism,
  different fix.

## Measured outcome (post-implementation)

### Demo (5-package diamond, `scripts/link-cache-demo-bench.sh --runs=3 --verify`)

`demo-app` flips from `skipped` (on every scenario, every iter)
to `3/3` HIT on the scenarios where its inputs are byte-stable
across the edit. Per-target table for the affected scenarios:

| scenario        | core.a | core.so | codec.a | codec.so | graph.a | graph.so | engine.a | engine.so | demo-app |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| body-stable     | 3/3    | 3/3     | 3/3     | 3/3      | 3/3     | 3/3      | 3/3      | 3/3       | **3/3**  |
| add-unexported  | 3/3    | 3/3     | 3/3     | 3/3      | 3/3     | 3/3      | 3/3      | 3/3       | **3/3**  |

Wall-clock speedup on these two scenarios went from ~37% (with
the exe `SKIPPED`) to ~69% (with the exe in the cache):

| scenario          | cache off (s) | cache on (s) | speedup (before exe-cache) | speedup (after exe-cache) |
|---|---:|---:|---:|---:|
| body-stable       | 2.458         | 0.769        | ~37% | **+68.7%** |
| add-unexported    | 2.423         | 0.754        | ~36% | **+68.9%** |
| refactor-internal | 2.573         | 0.768        | ~12% | **+70.2%** |
| whitespace-only   | 2.498         | 0.782        | ~10% | **+68.7%** |
| comment-only      | 2.420         | 0.768        | ~10% | **+68.3%** |
| reorder-exports   | 2.447         | 0.761        |  ~9% | **+68.9%** |
| edit-leaf-of-mid-lib | 2.290     | 1.901        |  ~0% | **+17.0%** |

Seven of the nine scenarios now HIT 9/9 at ~68% speedup, up
from `body-stable` + `add-unexported` only at ~37% before the
exe-link cache. The remaining two (`add-exported`, `modify-type`)
are interface-changing edits where the cache fundamentally can't
help — `.hi` cascades through the dep graph and downstream `.o`
files genuinely differ.

(An earlier draft of this doc reported the line-shift cluster as
~10% rather than ~68%; that turned out to be a bench
contamination from prior cascading scenarios, fixed in the same
commit that produced these numbers — see
[`INVESTIGATION.md`](INVESTIGATION.md) "Finding 3 (retracted)".)

All nine scenarios pass `CABAL_LINK_CACHE_VERIFY=1 +
CABAL_LINK_CACHE_VERIFY_FAIL=1`. No `HIT-DIVERGED`. The new exe
blobs are byte-sound.

### Hydra (`scripts/link-cache-compare.sh` on `hydra-node`)

The interesting measurement is the *novel-edit* time — how long
the rebuild takes after you've made a change. Two A/B runs
against the `02-add-unexported` patch:

**Run 1 — total cache effect** (new fork: cache disabled vs
enabled, isolating the cache as a whole, including the new
exe-link cache):

| stage | cache off (s) | cache on (s) | speedup |
|---|---:|---:|---:|
| cold  | 260.771       | 261.559      | -0.3% (noise) |
| edit  |  28.611       |  14.492      | **+49.3%** |

**Run 2 — marginal exe-link contribution** (old fork vs new fork,
*both with cache enabled*, isolating only the exe-link work; uses
`scripts/link-cache-compare.sh --a-cache`):

| stage | fork-without-exe (s) | fork-with-exe (s) | speedup |
|---|---:|---:|---:|
| cold  | 261.391              | 261.718           | -0.1% (noise) |
| edit  |  18.467              |  14.351           | **+22.3%** |

The user's *prior* report against the same patch (cabal 3.10 vs
the older fork with exe link SKIPPED) showed only **+14.9%** on
edit. Run 1 confirms the total cache effect more than tripled.
Run 2 confirms ~half of that tripling is the **exe-link
contribution alone** — caching that single linker invocation
buys another 22% on edit *on top of* what the existing lib cache
already delivers.

The cold-build delta of ±0.3% is within run-to-run noise. The
extra GHC invocation per exe link (the link-only pass that used
to be a re-`--make`) is a small, deterministic addition; the
plan's risk of >5% cold-build regression did not materialise.

(The link-cache-compare bench also reports a "revert" timing —
build after `git apply -R` — which shows even larger speedups
because the post-revert byte state happens to exactly match the
baseline blob. That number isn't the headline measurement: real
developers rarely sit in apply/revert/apply/revert loops. The
*edit* row is the workflow that matters.)

### Compared to the demo, why hydra wins more

Two compounding reasons:

1. Hydra's exe (`hydra-node`) links against ~100 packages — much
   more bytes flow through the linker per build than in the demo
   (5 packages). The cache replaces a much larger linker
   invocation with a single copy.
2. Hydra's lib graph is broader, so even when the lib cache
   already hit on individual `.a`/`.so` targets, the exe link was
   the long pole. With the exe also cached, that pole disappears.
