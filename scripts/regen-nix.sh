#!/usr/bin/env bash
# Regenerate nix/<pkg>.nix from each sub-package's .cabal file.
# Run after any .cabal edit that adds or removes a build-depend.
# The committed nix/ files are what the flake's overlay uses;
# regenerating keeps `nix flake check --no-allow-import-from-derivation`
# passing.
set -euo pipefail

cd "$(dirname "$0")/.."

PKGS=(Cabal-syntax Cabal cabal-install-solver cabal-install hooks-exe)

mkdir -p nix
for pkg in "${PKGS[@]}"; do
  echo "regenerating nix/${pkg}.nix" >&2
  nix run nixpkgs#cabal2nix -- "./${pkg}" > "nix/${pkg}.nix"
done

# cabal2nix writes src paths relative to its cwd (the repo root) as
# `./<pkg>`. The flake `callPackage`s these files from nix/, so the
# paths need to be relative to nix/ -- prefix with `../`.
sed -i 's|src = \./|src = ./../|' nix/*.nix

echo "done. review with: git diff -- nix/" >&2
