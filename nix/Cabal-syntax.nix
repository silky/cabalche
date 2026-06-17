{ mkDerivation, alex, array, base, binary, bytestring, containers
, deepseq, directory, filepath, lib, mtl, parsec, pretty, text
, time, transformers
}:
mkDerivation {
  pname = "Cabal-syntax";
  version = "3.17.0.0";
  src = ./../Cabal-syntax;
  libraryHaskellDepends = [
    array base binary bytestring containers deepseq directory filepath
    mtl parsec pretty text time transformers
  ];
  libraryToolDepends = [ alex ];
  homepage = "http://www.haskell.org/cabal/";
  description = "A library for working with .cabal files";
  license = lib.licensesSpdx."BSD-3-Clause";
}
