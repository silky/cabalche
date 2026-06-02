# Plan: cache the exe link properly (currently SKIPPED in `--make` mode)

This is a focused follow-up to Finding 1 in
[`INVESTIGATION.md`](./INVESTIGATION.md). That finding closed the
*soundness* gap (a spurious HIT) by SKIPPING the exe cache whenever
cabal sees `--make` mode. Safe, but it leaves **the biggest single
link step in most projects uncached** — and a real-world A/B
measurement (see "Motivating evidence" below) suggests this is the
largest unrealized win on the table.

## TL;DR

- **Today.** Every exe link in cabal v3's default flow logs
  `[link-cache] SKIPPED (ghc-link-exe) … cache key not trusted` and
  runs the full linker, regardless of whether the cache already
  holds a byte-equal exe.
- **Why.** In `--make` mode the linker invocation has only
  `Main.hs` as a tracked input; the dep archives and home-package
  `.o` files are produced by the same GHC invocation that does the
  link, so they aren't on disk when the cache key needs to be
  computed.
- **Proposed.** Split exe building into a compile pass
  (`ghc --make -fno-link …`) and a link pass (`ghc -o … <objects>
  -package-id …`). The link pass mirrors the library-link pattern
  cabal already uses: explicit object inputs, explicit `-package-id`
  list, well-formed cache key.
- **Expected gain.** Demo: small but observable (`demo-app`
  graduates from `skipped` to `hit`). Realistic projects
  (hydra-node class, ~100 deps): the +14.9% link-cache speedup
  we measured on `add-unexported/hydra-node` is expected to widen
  to ~+20–30% on revert-style edits.

## Motivating evidence

The link-cache A/B harness
([`scripts/link-cache-compare.sh`](../../scripts/link-cache-compare.sh))
was run against the
[`hydra`](https://github.com/cardano-scaling/hydra) repo with a
small set of patches simulating realistic edits. The fully
worked-up reports live in `~/dev/w/tmp/cacheable/reports/`. The
relevant headline numbers:

| scenario           | target         | speedup | HITs / MISSes |
|---|---|---:|---:|
| add-unexported     | hydra-node     |  +14.9% | 107 / 23      |
| body-stable        | hydra-node     |   +1.1% |  33 / 97      |
| add-exported       | hydra-node     |   +1.4% |  22 / 108     |
| (any)              | hydra-prelude  |  -2…-7% |  ≤11 / ≤6     |

Of those 130 MISSes/HITs per scenario, **the exe link itself is
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
