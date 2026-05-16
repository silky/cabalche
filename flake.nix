{
  description = "cabal-install (master) with the in-tree link-output cache";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Stock nixpkgs ghc984 is sufficient: the link-output cache lives
      # in lib:Cabal and works with any GHC. The user's in-tree GHC fork
      # is only relevant when *running* cabal against that compiler, not
      # when building cabal-install itself.
      ghcAttr = "ghc984";

      # Per-package sources: each sub-package gets its own cleaned
      # source path. Using sub-paths directly (rather than
      # `${src}/Cabal-syntax`) means flake.nix edits don't invalidate
      # the haskell-package store hashes -- only edits inside the
      # respective sub-package do. Each filter strips dist/ and the
      # like in case the user has run plain `cabal build` in a sub-dir.
      cleanPkgSrc = name: dir: nixpkgs.lib.cleanSourceWith {
        src = dir;
        name = "${name}-source";
        filter = path: _type:
          let base = baseNameOf (toString path); in
          !(builtins.elem base [
            ".git"
            ".direnv"
            "dist"
            "dist-newstyle"
            "result"
          ]) && !(nixpkgs.lib.hasPrefix "result-" base);
      };
      cabalSyntaxSrc        = cleanPkgSrc "Cabal-syntax"         ./Cabal-syntax;
      cabalSrc              = cleanPkgSrc "Cabal"                ./Cabal;
      cabalInstallSolverSrc = cleanPkgSrc "cabal-install-solver" ./cabal-install-solver;
      cabalInstallSrc       = cleanPkgSrc "cabal-install"        ./cabal-install;
      hooksExeSrc           = cleanPkgSrc "hooks-exe"            ./hooks-exe;

      # We deliberately do NOT override `Cabal` and `Cabal-syntax` in
      # the haskellPackages set. lib:Cabal is in essentially every
      # haskell package's setup-depends, so a global override forces
      # nixpkgs to rebuild the entire haskell world. Instead, the
      # patched libraries are private to cabal-install-solver /
      # cabal-install, passed via callCabal2nix's per-package argument
      # set. The consumer-visible `cabal` binary still links against the
      # patched Cabal -- which is the only thing that matters here.
      #
      # doJailbreak: nixpkgs unstable sometimes runs ahead of cabal's
      # bounds. Jailbreaking is the nixpkgs-haskell convention; safer
      # than chasing upper-bound bumps in this flake.
      #
      # `Cabal-described = null` etc.: cabal2nix surfaces test-only deps
      # in the function signature even when `doCheck = false`. Passing
      # null satisfies the binding without pulling them into the build.
      overlay = final: prev:
        let
          hslib = prev.haskell.lib.compose;
        in
        {
          haskell = prev.haskell // {
            packages = prev.haskell.packages // {
              ${ghcAttr} = prev.haskell.packages.${ghcAttr}.extend
                (hself: hprev:
                  let
                    # Jailbreak patched Cabal/Cabal-syntax so their own
                    # process/binary/etc. upper bounds don't fight
                    # nixpkgs-unstable's newer versions.
                    patchedCabalSyntax = hslib.doJailbreak
                      (hself.callCabal2nix "Cabal-syntax" cabalSyntaxSrc { });
                    patchedCabal = hslib.doJailbreak
                      (hself.callCabal2nix "Cabal"
                        cabalSrc { Cabal-syntax = patchedCabalSyntax; });
                    # hooks-exe is an in-tree sibling on master; rebuild
                    # against the patched Cabal/Cabal-syntax so package
                    # IDs match what cabal-install links against.
                    patchedHooksExe = hslib.doJailbreak
                      (hself.callCabal2nix "hooks-exe"
                        hooksExeSrc {
                          Cabal        = patchedCabal;
                          Cabal-syntax = patchedCabalSyntax;
                        });
                    # Any transitive dep of cabal-install that uses
                    # Cabal-syntax in its public API must rebuild
                    # against the patched Cabal-syntax -- otherwise
                    # cabal-install sees two `Cabal-syntax-*` with
                    # different package-ids and aborts at link time.
                    # hackage-security is the only one in the
                    # cabal-install dep cone.
                    rebuildAgainstPatched = drv: drv.override {
                      Cabal        = patchedCabal;
                      Cabal-syntax = patchedCabalSyntax;
                    };
                  in
                  {
                    hackage-security = rebuildAgainstPatched hprev.hackage-security;
                    cabal-install-solver = hslib.doJailbreak
                      (hself.callCabal2nix "cabal-install-solver"
                        cabalInstallSolverSrc {
                          Cabal-syntax = patchedCabalSyntax;
                          Cabal        = patchedCabal;
                        });
                    cabal-install = hslib.doJailbreak
                      (hself.callCabal2nix "cabal-install"
                        cabalInstallSrc {
                          Cabal-syntax     = patchedCabalSyntax;
                          Cabal            = patchedCabal;
                          hooks-exe        = patchedHooksExe;
                          Cabal-described  = null;
                          Cabal-QuickCheck = null;
                          Cabal-tree-diff  = null;
                          Cabal-tests      = null;
                          tree-diff        = null;
                        });
                  });
            };
          };
        };
    in
    {
      overlays.default = overlay;
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
        hsLib = pkgs.haskell.lib.compose;
        hp = pkgs.haskell.packages.${ghcAttr};

        # `packages.cabal` is the default flavour: nixpkgs-haskell stock
        # build (cabal default `-O1`, asserts on by default-via-cabal,
        # tests disabled, executables stripped). Fast-ish but not as
        # fast as -O2.
        cabal-install = hsLib.justStaticExecutables hp.cabal-install;

        # `packages.cabal-optimized`: cabal-install + cabal-install-
        # solver bumped to `-O2 -fexpose-all-unfoldings
        # -fspecialise-aggressively`. The patched Cabal/Cabal-syntax
        # stay at stock `-O1` so we don't cascade a rebuild of
        # `hackage-security` etc. -- the patched libs still flow in
        # unchanged via `callCabal2nix`'s argument set, so the binary
        # is the same patch-wise; only the two crates ghc spends most
        # of its codegen budget on get the bump.
        #
        # Tradeoff: roughly 2-3x longer build, and the resulting cabal
        # binary is ~10-30% larger. Worth it if you care about cabal
        # planner / build orchestrator latency on hot paths.
        bumpO2 = drv: hsLib.appendConfigureFlags [
          "--ghc-options=-O2"
          "--ghc-options=-fexpose-all-unfoldings"
          "--ghc-options=-fspecialise-aggressively"
        ] drv;
        cabal-install-optimized =
          hsLib.justStaticExecutables
            ((bumpO2 hp.cabal-install).override {
              cabal-install-solver = bumpO2 hp.cabal-install-solver;
            });
      in
      {
        packages = {
          default = cabal-install;
          cabal = cabal-install;
          cabal-optimized = cabal-install-optimized;
        };

        apps = {
          default = self.apps.${system}.cabal;
          cabal = {
            type = "app";
            program = "${cabal-install}/bin/cabal";
            meta.description = "cabal-install (master) with link-output cache";
          };
          cabal-optimized = {
            type = "app";
            program = "${cabal-install-optimized}/bin/cabal";
            meta.description = "cabal-install (master) with link-output cache, -O2";
          };
        };

        devShells.default = hp.shellFor {
          packages = ps: [ ps.cabal-install-solver ps.cabal-install ];
          withHoogle = false;
          nativeBuildInputs = [ pkgs.haskellPackages.cabal-install ];
        };
      });
}
