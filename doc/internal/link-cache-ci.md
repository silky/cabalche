# Using the link-output cache from CI

The link-output cache (see `Note [Link manifest cache]` in
`Distribution.Simple.GHC.Build.Link`) is per-user by default and
sits under `$XDG_CACHE_HOME/cabal/link-cache/`. CI runners start
fresh each job, so out-of-the-box the cache is always cold there.
To get any benefit, persist the cache directory between runs.

This document also covers when the cache helps (and when it
doesn't) so you can decide whether wiring it up is worth the
config overhead for your project.

## Does the cache help on dep builds?

**Yes.** Verified end-to-end: when `cabal-install` builds a package
into the per-user store (`~/.cabal/store/<ghc>/<pkgid>/`), its
internal Setup shim is linked against the patched `lib:Cabal` we
ship, so the dep's `ar-static`, `ghc-shared`, and `ghc-staticlib`
steps are all wrapped in `withSkippableLink`.

Smoke test:

```
$ rm -rf .cabal/store cache/
$ CABAL_LINK_CACHE_DIR=$PWD/cache cabal build
... fetches and builds lens-aeson into .cabal/store ...
$ ls cache/
21544b12...blob
21544b12...manifest    # ar-static of libHSlens-aeson-...a
cdb67bdf...blob
cdb67bdf...manifest    # ghc-shared of libHSlens-aeson-...so
ebc94426...blob
ebc94426...manifest    # ghc-link-exe of the consuming test exe
```

On a subsequent `cabal install` of the same `lens-aeson` version
into a fresh store, the cache HITs and the dep's link step is
byte-copied from blob instead of re-linked. That is the primary win
on CI: dep installation, not the consumer's own build.

## GitHub Actions

Cache key derived from `cabal.project.freeze` (or `cabal.project` if
you don't ship a freeze file) and the GHC version. Restore-keys
let CI fall back to a partial match -- e.g. a previous build with
slightly different freeze contents -- so you still avoid the
worst-case full rebuild.

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: haskell-actions/setup@v2
        with:
          ghc-version: '9.10.3'
          cabal-version: '3.17'  # ship our cabal-install or build it from this flake

      - name: Restore link-output cache
        id: link-cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/cabal/link-cache
          key: link-cache-${{ runner.os }}-${{ matrix.ghc }}-${{ hashFiles('cabal.project.freeze', '**/*.cabal') }}
          restore-keys: |
            link-cache-${{ runner.os }}-${{ matrix.ghc }}-

      - name: Build
        run: cabal build all

      - name: Cap cache size before save
        run: |
          # GitHub Actions caches > 10 GB get evicted; keep ours under
          # 2 GB by truncating the cache before save.
          env CABAL_LINK_CACHE_MAX_BYTES=$((2 * 1024 * 1024 * 1024)) \
              cabal build all --dry-run >/dev/null || true
```

The `--dry-run` trick at the end re-runs the cache's GC pass under
the smaller cap. Alternatively, do it explicitly:

```bash
find ~/.cache/cabal/link-cache -maxdepth 1 -name '*.blob' -printf '%T@ %p\n' \
  | sort -n | head -n -500 | cut -d' ' -f2- | xargs -r rm -f
# Drop everything except the 500 most recently used blobs.
```

## GitLab CI

```yaml
build:
  image: nixos/nix:latest
  cache:
    key:
      files:
        - cabal.project.freeze
    paths:
      - .cache/cabal/link-cache/
  variables:
    XDG_CACHE_HOME: $CI_PROJECT_DIR/.cache
  script:
    - cabal update
    - cabal build all
```

Note the `XDG_CACHE_HOME` redirection -- GitLab's cache:paths is
project-relative, but the link cache defaults to `~/.cache/...`.
Pointing `XDG_CACHE_HOME` at a project-relative dir folds the
cache into the standard cache:paths machinery.

## When the cache does NOT help on CI

- **Nix-built / fully-sandboxed jobs.** Each derivation gets a
  scrubbed `HOME` (`/homeless-shelter` under nix); the cache's
  soft-fail wrapper silently disables it. Move the cache outside
  the sandbox if you need it. For `nix build`, use
  `--keep-failed --print-build-logs` to debug; for `nix develop`
  you have the cache.
- **The consumer's own application code.** Editing `Main.hs` or
  changing a library source busts the link key. The cache wins on
  *unchanged* dep cones, not on the package you are actively
  hacking on.
- **Cross-GHC builds.** Each GHC version is a distinct key (we
  include `-ghc<X.Y>` in the cache lookups). Don't share a cache
  across GHC versions.
- **`cabal install` with `--installdir`.** The store build is
  cached; the install itself is just a copy and was already fast.

## Verifying the cache actually fired

After a build, run

```
scripts/link-cache-summary.sh
```

(default path is `$XDG_CACHE_HOME/cabal/link-cache/.stats.jsonl`).
A healthy CI run should show hit rate well over 50% on the dep
cone; rebuilds of the consumer's own code will pull it down.

If `[link-cache] DISABLED` lines appear in `-v2` output, the
sandbox is rejecting writes to the cache root and the soft-fail
wrapper is downgrading. Check `HOME` and `XDG_CACHE_HOME`.
