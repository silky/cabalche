# Cabal

[![Hackage version](https://img.shields.io/hackage/v/Cabal.svg?label=Hackage)](https://hackage.haskell.org/package/Cabal)
[![Stackage version](https://www.stackage.org/package/Cabal/badge/lts?label=Stackage)](https://www.stackage.org/package/Cabal)
[![Documentation Status](http://readthedocs.org/projects/cabal/badge/?version=latest)](http://cabal.readthedocs.io/en/latest/?badge=latest)
[![IRC chat](https://img.shields.io/badge/chat-via%20libera-brightgreen.svg)](https://web.libera.chat/#hackage)
[![Matrix chat](https://img.shields.io/badge/chat-via%20matrix-brightgreen.svg)](https://matrix.to/#/#hackage:matrix.org)
[![GitLab pipeline status](https://gitlab.haskell.org/haskell/cabal/badges/cabal-head/pipeline.svg?key_text=Release%20CI%20Early%20Warning&key_width=150)](https://gitlab.haskell.org/haskell/cabal/-/commits/cabal-head)

<img src="Cabal-light.png" align="right">

This Cabal Git repository contains the following main packages:

 * [Cabal](Cabal/README.md): the Cabal library package ([license](Cabal/LICENSE))
 * [Cabal-hooks](Cabal-hooks/README.md): the library providing an API for the Cabal `Hooks` build type ([license](Cabal-hooks/LICENSE))
 * [Cabal-syntax](Cabal-syntax/README.md): the `.cabal` file format library ([license](Cabal-syntax/LICENSE))
 * [cabal-install](cabal-install/README.md): the package containing the `cabal` tool ([license](cabal-install/LICENSE))
 * [cabal-install-solver](cabal-install-solver): the package containing the solver component of the `cabal` tool ([license](cabal-install-solver/LICENSE))

The canonical upstream repository is located at
https://github.com/haskell/cabal.

---

## Fork: content-addressed link-output cache

This fork adds a content-addressed cache for the linker steps cabal
drives (`ar`, `ld -r`, `ghc -shared`, `ghc -staticlib`, `ghc -o`). On a
relink with byte-equal `.o` inputs the cache byte-copies the prior
output to the target and skips the linker call. See
[`changelog.d/link-output-cache.md`](changelog.d/link-output-cache.md)
and [`examples/link-cache-demo/INVESTIGATION.md`](examples/link-cache-demo/INVESTIGATION.md)
for the measured benefit on a five-package demo project.

### Quick usage (Nix flake)

Add the fork as a flake input and apply its overlay to your nixpkgs.
The overlay overrides `cabal-install` inside the chosen Haskell
package set — `lib:Cabal` and `lib:Cabal-syntax` are *not* overridden
in the global haskell set, so the rest of the haskell world isn't
rebuilt.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cabal-cache.url = "github:silky/cabalche/cache-cabal-master";
  };

  outputs = { self, nixpkgs, cabal-cache, ... }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [ cabal-cache.overlays.default ];
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.haskell.packages.ghc984.cabal-install  # patched cabal
        pkgs.haskell.compiler.ghc984
      ];
    };
  };
}
```

If you don't want to touch your nixpkgs overlay chain, drop the
binary in directly:

```nix
# … in a devShell or mkDerivation:
packages = [ cabal-cache.packages.${system}.cabal-optimized ];
```

`packages.cabal-optimized` is the same binary with `-O2
-fexpose-all-unfoldings -fspecialise-aggressively` on `cabal-install`
itself (2–3× longer to build, ~10% larger; only worth it if you care
about the planner's hot-path latency).

### What it looks like in use

The first time the cache sees a link target it misses and stores the
linker's output:

```
$ cabal build
…
[link-cache] MISS (ar-static) /…/libHSdemo-core-0.1.0.0-inplace.a
[link-cache] MISS (ghc-shared) /…/libHSdemo-core-0.1.0.0-inplace-ghc9.10.3.so
[link-cache] MISS (ar-static) /…/libHSdemo-codec-0.1.0.0-inplace.a
…
```

A subsequent build that produces byte-equal link inputs HITs instead:

```
$ cabal build
…
[link-cache] HIT (ar-static) /…/libHSdemo-core-0.1.0.0-inplace.a
[link-cache] HIT (ghc-shared) /…/libHSdemo-core-0.1.0.0-inplace-ghc9.10.3.so
…
```

Per-link telemetry (`tool`, `target`, `outcome`, `input_bytes`, `ms`)
is appended to `$CABAL_LINK_CACHE_DIR/.stats.jsonl` for offline
analysis; `scripts/link-cache-summary.sh` aggregates it. The cache
root defaults to `$XDG_CACHE_HOME/cabal/link-cache/` and survives
across builds in the same user account.

For an end-to-end measurement on a small five-package demo (cache
off vs on, per-target HIT/MISS, soundness verification), see
[`examples/link-cache-demo/`](examples/link-cache-demo/) — the
`REPORT.md` there is regenerated from
`scripts/link-cache-demo-bench.sh`.

### How to disable

Either at the call site:

```sh
CABAL_LINK_CACHE_DISABLE=1 cabal build all
```

or globally for your shell:

```sh
export CABAL_LINK_CACHE_DISABLE=1
```

`CABAL_LINK_CACHE_DISABLE=1` skips both the read and the write
paths — every link runs the underlying tool. The full env-var
contract is documented at the top of
[`Cabal/src/Distribution/Simple/GHC/LinkManifest.hs`](Cabal/src/Distribution/Simple/GHC/LinkManifest.hs)
(also: `CABAL_LINK_CACHE_DIR`, `CABAL_LINK_CACHE_MAX_BYTES`,
`CABAL_LINK_CACHE_NO_STAT`, `CABAL_LINK_CACHE_NO_STATS`,
`CABAL_LINK_CACHE_VERIFY`, `CABAL_LINK_CACHE_VERIFY_FAIL`).

---

Proposals for the Cabal project
-------------------------------

The [proposals process](proposals.md) is the mechanism which developers can gain
the necessary consensus to make larger changes to the Cabal ecosystem.

* It is light-weight, a PR is opened and discussed on [cabal-proposals](https://github.com/haskell/cabal-proposals/) repo with a fixed discussion period.
* It is developer-led, final decisions are made by developers at the Cabal developers meeting.
* It is flexible, there is no formal voting procedure, decisions are made by [rough consensus](https://datatracker.ietf.org/doc/html/rfc7282).

Ways to get the `cabal-install` binary
--------------------------------

1. _GHCup_ (**preferred**): get GHCup using [the directions on its website](https://www.haskell.org/ghcup/) and run:

    ```
    ghcup install --set cabal latest
    ```

2. _[Download from official website](https://www.haskell.org/cabal/download.html)_:
    the `cabal-install` binary download for your platform should contain the `cabal` executable.

#### Preview Releases

_Getting unreleased versions of `cabal-install`_: gives you a chance to try out yet-unreleased features.
Currently, we only provide binaries for `x86_64` platforms.

1. _GitHub preview release built from the tip of the `master` branch_: [download from GitHub](https://github.com/haskell/cabal/releases/tag/cabal-head) or use this GHCup command to install:

    ```
    ghcup install cabal -u https://github.com/haskell/cabal/releases/download/cabal-head/cabal-head-Linux-x86_64.tar.gz head
    ```

    Replace "Linux" with "Windows" or "macOS" as appropriate.

    The default Linux build is dynamically linked against `zlib`, `gmp` and `glibc`.
    You will need to have appropriate versions of these libraries installed to use it.
    Alternatively a statically linked "Linux-static" binary is also provided.

    You might need to add the following to your `cabal.project` file
    if your build fails because of an out-of-date `Cabal` library:
    ```
    allow-newer:
      *:Cabal,
      *:Cabal-syntax

    source-repository-package
        type: git
        location: https://github.com/haskell/cabal.git
        subdir: Cabal Cabal-syntax
    ```


2. Even more cutting-edge binaries built from pull requests are always available
   from the `Validate` workflow page on GitHub, at the very bottom of the page,
   or from the `build-alpine` workflow for statically linked Linux builds.

Ways to build `cabal-install` for everyday use
--------------------------------------------

1. _With cabal-install_:
    if you have a pre-existing version of `cabal-install`, run:

    ```
    cabal install cabal-install
    ```

    to get the latest version of `cabal-install`. (You may want to `cabal update` first.)

2. _From Git_:
    again with a pre-existing version of `cabal-install`,
    you can install the latest version from the Git repository. Clone the
    Git repository, move to its root, and run:

    ```
    cabal install --project-file=cabal.release.project cabal-install
    ```

3. _Bootstrapping_:
    if you don't have a pre-existing version of `cabal-install`,
    look into the [`bootstrap`](bootstrap) directory.

Learn how to use `cabal` and get support
----------------------------------------

`cabal` comes with a thorough [User Manual](https://cabal.readthedocs.io).
If you are new to `cabal` and want to quickly learn the basics, check
[Getting Started With Haskell and Cabal](https://cabal.readthedocs.io/en/latest/getting-started.html).

Got questions? Ask in [Haskell Matrix](https://matrix.to/#/#haskell:matrix.org)
(online chat) or [Haskell Discourse](https://discourse.haskell.org).

Support window
--------------

Our GHC support window is five years ([reference](https://gitlab.haskell.org/ghc/ghc/-/wikis/GHC%20Status#all-released-ghc-versions))
for both the Cabal library and `cabal-install`.  That is:

* Cabal library must be buildable out-of-the-box against the
  boot libraries shipped with GHC, for any GHC released in the past five
  years from Cabal library release date.
* `cabal-install` should be buildable with `bootstrap/bootstrap.py`
  script, for any GHC released in the past five years from `cabal-install`
  release date.
* `cabal-install` should be able to drive the most recent minor version of
  any GHCs major version released in the past five years from `cabal-install`
  release date.
  In this context, "drive" means `cabal-install` will work with the Cabal
  library (usually but not always the one that came with the ghc version)
  used to build the package.

Self-upgrade to the latest version (i.e. `cabal install cabal-install`)
must work with all versions of `cabal-install` released during the last
three years.

Cabal maintainers try to support GHC versions older than five years
on a minimal-effort basis.

Build for hacking and contributing to cabal
-------------------------------------------

Refer to [CONTRIBUTING.md](CONTRIBUTING.md).

Maintainers
-------------------------------------------

Refer to [MAINTAINERS.md](MAINTAINERS.md).
