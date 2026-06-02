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

    -- Bust the library's link key by editing Lib.M0 (forces GHC
    -- to recompile M0 and the lib's ar/ghc-shared link inputs to
    -- change). The exe link is in `--make` mode, so the cache
    -- skips it; we deliberately touch the library, whose links the
    -- cache does manage.
    liftIO $ writeFile (testCurrentDir env </> "src" </> "Lib" </> "M0.hs") $
      unlines
        [ "module Lib.M0 where"
        , ""
        , "x0 :: Int"
        , "x0 = 42"
        ]

    -- Second build with the tight cap. The new library blob
    -- triggers enforceSizeCap, which has to evict older entries.
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
