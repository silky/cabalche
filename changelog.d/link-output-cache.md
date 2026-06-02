---
synopsis: "Content-addressed cache for link outputs (experimental)"
packages: [Cabal]
prs: 1
---

`lib:Cabal` now caches `ar`, `ld -r`, `ghc -shared`, `ghc -staticlib`,
and `ghc -o` outputs by content hash. A relink with byte-equal inputs
byte-copies the cached blob to the target and skips the linker call,
which can turn a multi-second clean relink into a fraction of a second
on large projects.

The cache key is `(tool identifier, target basename, sorted xxh64
digests of all link inputs)`. The target's directory is not part of
the key, so two checkouts of the same package share cached outputs
when they emit identically-named libraries and executables.

Configuration (all optional, set via the environment):

  * `CABAL_LINK_CACHE_DISABLE=1` — bypass entirely; the linker runs
    every time, as if this feature were absent.
  * `CABAL_LINK_CACHE_DIR=/path` — override the cache root. Default is
    `$XDG_CACHE_HOME/cabal/link-cache`.
  * `CABAL_LINK_CACHE_MAX_BYTES=N` — cap the cache at N bytes. On a
    miss-with-write, oldest entries are evicted until under the cap.
    Default: 5 GiB.

Status: experimental. Correctness rests on `ar`/`ld`/`ghc` determinism
on a given toolchain. `ar` is already forced byte-stable by Cabal's
`Distribution.Simple.Program.Ar.wipeMetadata`. See
`Note [Link manifest cache]` in `Distribution.Simple.GHC.Build.Link`
for the per-tool argument and the design rationale.

Any IOException inside the cache layer (e.g. read-only `$HOME`, full
disk, sandbox restrictions) downgrades to a plain linker run, so the
cache cannot break a build that would otherwise succeed.
