{ mkDerivation, array, base, bytestring, Cabal, Cabal-syntax
, containers, directory, edit-distance, filepath, lib, mtl
, network-uri, pretty, tasty, tasty-hunit, tasty-quickcheck, text
, transformers
}:
mkDerivation {
  pname = "cabal-install-solver";
  version = "3.17.0.0";
  src = ./../cabal-install-solver;
  libraryHaskellDepends = [
    array base bytestring Cabal Cabal-syntax containers directory
    edit-distance filepath mtl network-uri pretty text transformers
  ];
  testHaskellDepends = [
    base Cabal-syntax tasty tasty-hunit tasty-quickcheck
  ];
  homepage = "http://www.haskell.org/cabal/";
  description = "The solver component of cabal-install";
  license = lib.licensesSpdx."BSD-3-Clause";
}
