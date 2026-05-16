{ mkDerivation, base, bytestring, Cabal, Cabal-syntax, filepath
, lib, process
}:
mkDerivation {
  pname = "hooks-exe";
  version = "0.1";
  src = ./../hooks-exe;
  libraryHaskellDepends = [
    base bytestring Cabal Cabal-syntax filepath process
  ];
  homepage = "http://www.haskell.org/cabal/";
  description = "cabal-install integration for Hooks build-type";
  license = lib.licensesSpdx."BSD-3-Clause";
}
