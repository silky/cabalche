{ mkDerivation, array, base, bytestring, Cabal-syntax, containers
, deepseq, directory, filepath, hashable, lib, mtl, parsec, pretty
, process, time, transformers, unix, xxhash-ffi
}:
mkDerivation {
  pname = "Cabal";
  version = "3.17.0.0";
  src = ./../Cabal;
  setupHaskellDepends = [ mtl parsec ];
  libraryHaskellDepends = [
    array base bytestring Cabal-syntax containers deepseq directory
    filepath hashable mtl parsec pretty process time transformers unix
    xxhash-ffi
  ];
  doCheck = false;
  homepage = "http://www.haskell.org/cabal/";
  description = "A framework for packaging Haskell software";
  license = lib.licensesSpdx."BSD-3-Clause";
}
