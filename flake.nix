{
  description = "cabal-install (master) with the in-tree link-output cache";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # The link-output cache lives in lib:Cabal and is GHC-agnostic, but
      # the cabal-install binary we ship has to be built against *some*
      # GHC. ghc984 is what nixpkgs unstable's stock haskellPackages set
      # is built against, so picking it means we don't trigger a haskell-
      # world rebuild. Consumers wanting a different GHC can either:
      #
      #   * use packages.cabal directly (statically linked, GHC choice
      #     is invisible to them), or
      #   * apply overlays.default to their own nixpkgs and reach for
      #     pkgs.haskell.packages.${ghcAttr}.cabal-install, knowing the
      #     overlay only touches that attr.
      ghcAttr = "ghc984";

      overlay = final: prev:
        let
          hslib = final.haskell.lib.compose;

          # Each sub-package gets its own cleaned source path so that
          # unrelated tree changes (a flake.nix edit, a stray
          # dist-newstyle) don't bust the haskell-package store hashes.
          cleanPkgSrc = name: src: final.lib.cleanSourceWith {
            inherit src;
            name = "${name}-source";
            filter = path: _type:
              let base = baseNameOf (toString path); in
              !(builtins.elem base [
                ".git"
                ".direnv"
                "dist"
                "dist-newstyle"
                "result"
              ]) && !(final.lib.hasPrefix "result-" base);
          };

          # Load a callPackage-style derivation from nix/<name>.nix and
          # swap its src for the cleaned per-package source. The .nix
          # files under nix/ are cabal2nix-generated and committed --
          # see scripts/regen-nix.sh -- which keeps flake evaluation
          # IFD-free so this flake can be consumed under
          # `nix flake check --no-allow-import-from-derivation`.
          mkPatched = hself: name: srcDir: deps:
            hslib.doJailbreak
              (hslib.overrideSrc { src = cleanPkgSrc name srcDir; }
                (hself.callPackage (./nix + "/${name}.nix") deps));
        in
        {
          haskell = prev.haskell // {
            packages = prev.haskell.packages // {
              ${ghcAttr} = prev.haskell.packages.${ghcAttr}.extend
                (hself: hprev:
                  let
                    # We deliberately do NOT override Cabal/Cabal-syntax
                    # in the global haskell package set. lib:Cabal is in
                    # essentially every haskell package's setup-depends,
                    # so a global override would force nixpkgs to
                    # rebuild the entire haskell world. Instead, the
                    # patched libraries are local to this set's
                    # cabal-install / cabal-install-solver / hooks-exe.
                    patchedCabalSyntax = mkPatched hself
                      "Cabal-syntax" ./Cabal-syntax { };
                    patchedCabal = mkPatched hself
                      "Cabal" ./Cabal {
                        Cabal-syntax = patchedCabalSyntax;
                      };
                    patchedHooksExe = mkPatched hself
                      "hooks-exe" ./hooks-exe {
                        Cabal        = patchedCabal;
                        Cabal-syntax = patchedCabalSyntax;
                      };

                    # cabal-install master needs semaphore-compat >=
                    # 2.0.0 for the new ClientSemaphore /
                    # SemaphoreIdentifier types in jobsem-driven
                    # parallel builds. GHC 9.8.x bundles 1.0.0 and
                    # nixpkgs's `semaphore-compat = null` policy
                    # passes the bundled version through, so without
                    # this override the build fails with
                    # "Not in scope: type constructor ClientSemaphore"
                    # in Distribution.Client.JobControl.
                    semaphoreCompat2 = hself.callHackageDirect
                      {
                        pkg = "semaphore-compat";
                        ver = "2.0.0";
                        sha256 = "06j0xf055izg98i1pm0l1hzbkapy4kyrz5lpyl4y8iq5l6sq1d5k";
                      } { };
                  in
                  {
                    # Make the upgraded semaphore-compat the default
                    # in this set so anything that callPackage-resolves
                    # `semaphore-compat` picks up 2.0.0.
                    semaphore-compat = semaphoreCompat2;
                    # Any transitive dep of cabal-install that uses
                    # Cabal-syntax in its public API must rebuild
                    # against the patched Cabal-syntax -- otherwise
                    # cabal-install sees two `Cabal-syntax-*` with
                    # different package-ids and aborts at link time.
                    # hackage-security is the only one in the
                    # cabal-install dep cone.
                    hackage-security = hprev.hackage-security.override {
                      Cabal        = patchedCabal;
                      Cabal-syntax = patchedCabalSyntax;
                    };

                    cabal-install-solver = mkPatched hself
                      "cabal-install-solver" ./cabal-install-solver {
                        Cabal-syntax = patchedCabalSyntax;
                        Cabal        = patchedCabal;
                      };

                    # `Cabal-described = null` etc.: cabal2nix surfaces
                    # test-only deps in the function signature even
                    # when doCheck = false. Passing null satisfies the
                    # binding without pulling them into the build.
                    cabal-install = mkPatched hself
                      "cabal-install" ./cabal-install {
                        Cabal-syntax     = patchedCabalSyntax;
                        Cabal            = patchedCabal;
                        hooks-exe        = patchedHooksExe;
                        Cabal-described  = null;
                        Cabal-QuickCheck = null;
                        Cabal-tree-diff  = null;
                        Cabal-tests      = null;
                        tree-diff        = null;
                      };
                  });
            };
          };
        };
    in
    {
      overlays.default = overlay;

      lib = {
        # The haskell-packages attr the overlay extends. Consumers who
        # compose the overlay into their pkgs reach for
        # `pkgs.haskell.packages.${cabalCache.lib.ghcAttr}.cabal-install`.
        inherit ghcAttr;
      };
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
        hsLib = pkgs.haskell.lib.compose;
        hp = pkgs.haskell.packages.${ghcAttr};

        # Annotate so `nix run .#cabal` and `nix shell .#cabal` reach
        # for `bin/cabal` rather than the package name's `bin/<pname>`.
        withMeta = drv: drv.overrideAttrs (old: {
          meta = (old.meta or { }) // {
            mainProgram = "cabal";
            description = "cabal-install with link-output cache";
          };
        });

        # `packages.cabal` is the default flavour: nixpkgs-haskell stock
        # build (cabal default -O1, asserts on by default-via-cabal,
        # tests disabled, executables stripped).
        cabal-install = withMeta (hsLib.justStaticExecutables hp.cabal-install);

        # `packages.cabal-optimized`: cabal-install + cabal-install-
        # solver bumped to `-O2 -fexpose-all-unfoldings
        # -fspecialise-aggressively`. The patched Cabal/Cabal-syntax
        # stay at stock -O1 so we don't cascade a rebuild of
        # hackage-security etc. -- the patched libs still flow in
        # unchanged via callPackage's argument set, so the binary is
        # the same patch-wise; only the two crates ghc spends most of
        # its codegen budget on get the bump.
        #
        # Tradeoff: roughly 2-3x longer build, and the resulting cabal
        # binary is ~10% larger. Worth it if you care about cabal
        # planner / build orchestrator latency on hot paths.
        bumpO2 = drv: hsLib.appendConfigureFlags [
          "--ghc-options=-O2"
          "--ghc-options=-fexpose-all-unfoldings"
          "--ghc-options=-fspecialise-aggressively"
        ] drv;
        cabal-install-optimized = withMeta
          (hsLib.justStaticExecutables
            ((bumpO2 hp.cabal-install).override {
              cabal-install-solver = bumpO2 hp.cabal-install-solver;
            }));
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

        # `nix flake check` builds these. Exposing the default package
        # as a check means CI in a downstream consumer that does
        # `nix flake check` on the input will catch evaluation drift.
        checks = {
          inherit cabal-install cabal-install-optimized;
        };

        devShells.default = hp.shellFor {
          packages = ps: [ ps.cabal-install-solver ps.cabal-install ];
          withHoogle = false;
          nativeBuildInputs = [ pkgs.haskellPackages.cabal-install ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
