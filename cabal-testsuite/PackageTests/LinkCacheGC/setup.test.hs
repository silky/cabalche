-- Asserts that CABAL_LINK_CACHE_MAX_BYTES forces eviction of older
-- blobs. Builds the project once into a normal cache to record
-- the blobs that get written. Then sets MAX_BYTES to a value below
-- the cache's current size, edits a source file (busting the link
-- key for the exe), and rebuilds. The post-rebuild cache must be
-- under the cap, with the oldest blobs (those not written by the
-- second build) gone.
import Test.Cabal.Prelude

import Control.Monad (when)
import Data.List (isSuffixOf, sortOn)
import qualified Data.ByteString as BS
import System.Directory
  ( doesDirectoryExist
  , getFileSize
  , getModificationTime
  , listDirectory
  )

main = setupTest $ recordMode DoNotRecord $ do
  env <- getTestEnv
  let cacheDir = testWorkDir env </> "link-cache"

  withEnv [("CABAL_LINK_CACHE_DIR", Just cacheDir)] $ do
    -- Cold build: writes one blob per link step. Without the cap
    -- env var, eviction is keyed on the 5 GiB default, well above
    -- anything this fixture will produce.
    setup "configure" []
    coldResult <- setup' "build" []
    assertOutputContains "[link-cache] MISS" coldResult

    (preCount, preTotal) <- liftIO $ summariseBlobs cacheDir
    when (preCount == 0) $
      liftIO $ error "expected at least one blob after cold build"

    -- Pick a cap small enough that we must evict on the next
    -- miss-with-write. We aim for slightly under one blob's worth.
    let cap = max 1 (preTotal `div` max 1 (fromIntegral preCount + 1))

    -- Bust the exe's link key by editing Main.hs (the source-level
    -- edit forces GHC to recompile and the link inputs change).
    -- The library archives stay byte-identical so only the exe
    -- link writes a fresh blob.
    liftIO $ writeFile (testCurrentDir env </> "app" </> "Main.hs") $
      unlines
        [ "module Main where"
        , ""
        , "import Lib.M0 (x0)"
        , "import Lib.M1 (x1)"
        , "import Lib.M2 (x2)"
        , "import Lib.M3 (x3)"
        , ""
        , "main :: IO ()"
        , "main = do"
        , "  putStrLn \"second build\""
        , "  print (x0 + x1 + x2 + x3)"
        ]

    -- Second build with the tight cap. The new exe blob triggers
    -- enforceSizeCap, which has to evict older entries.
    withEnv
      [ ("CABAL_LINK_CACHE_DIR", Just cacheDir)
      , ("CABAL_LINK_CACHE_MAX_BYTES", Just (show cap))
      ]
      $ setup "build" []

    (postCount, postTotal) <- liftIO $ summariseBlobs cacheDir
    when (postTotal > cap) $
      liftIO $ error $
        "post-build cache "
          <> show postTotal
          <> " bytes exceeds cap "
          <> show cap
    when (postCount >= preCount) $
      liftIO $ error $
        "expected eviction: pre-count="
          <> show preCount
          <> " post-count="
          <> show postCount

-- | Total size and count of @.blob@ entries directly under
-- @cacheDir@.
summariseBlobs :: FilePath -> IO (Int, Integer)
summariseBlobs cacheDir = do
  exists <- doesDirectoryExist cacheDir
  if not exists
    then return (0, 0)
    else do
      names <- listDirectory cacheDir
      let blobs = [n | n <- names, ".blob" `isSuffixOf` n]
      sizes <- mapM (\n -> getFileSize (cacheDir </> n)) blobs
      return (length blobs, sum sizes)
