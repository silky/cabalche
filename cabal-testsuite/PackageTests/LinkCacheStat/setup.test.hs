-- Asserts the stat short-circuit is a pure optimisation: bumping an
-- input file's mtime forward while keeping its bytes identical must
-- still result in a HIT. Then re-runs the same scenario with
-- CABAL_LINK_CACHE_NO_STAT=1 to confirm the cache works identically
-- without the short-circuit.
import Test.Cabal.Prelude

import Data.List (isPrefixOf, isSuffixOf)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import System.Directory
  ( doesDirectoryExist
  , listDirectory
  , removeFile
  , setModificationTime
  )

main = setupTest $ recordMode DoNotRecord $ do
  env <- getTestEnv

  let runScenario cacheDir extraEnv = do
        withEnv (("CABAL_LINK_CACHE_DIR", Just cacheDir) : extraEnv) $ do
          setup "configure" []
          -- Cold build: cache empty, link should MISS and populate
          -- both the cache and the stat-index sidecar.
          coldResult <- setup' "build" []
          assertOutputContains "[link-cache] MISS" coldResult

          -- Bump mtime of every .o forward while keeping bytes
          -- identical. With the stat short-circuit on, the index
          -- will detect the mtime mismatch and recompute MD5 (it
          -- has to read bytes again). The MD5 is unchanged, so the
          -- cache key is unchanged.
          liftIO $ bumpObjectMtimes (testDistDir env </> "build")

          -- Force a relink by deleting the previous link outputs.
          liftIO $ removeLinkOutputs (testDistDir env </> "build")

          warmResult <- setup' "build" []
          assertOutputContains "[link-cache] HIT" warmResult
          assertOutputDoesNotContain "[link-cache] MISS" warmResult

  -- Run 1: stat short-circuit enabled (default).
  runScenario (testWorkDir env </> "cache-stat") []

  -- Run 2: stat short-circuit disabled.
  runScenario
    (testWorkDir env </> "cache-no-stat")
    [("CABAL_LINK_CACHE_NO_STAT", Just "1")]

-- | Walk @root@ and bump the mtime of every @.o@ file forward by 1
-- minute. We use +60s rather than +1s so the change is well above
-- any filesystem mtime resolution we might run into.
bumpObjectMtimes :: FilePath -> IO ()
bumpObjectMtimes root = walkAll root $ \p n ->
  when (".o" `isSuffixOf` n) $ do
    now <- getCurrentTime
    setModificationTime p (addUTCTime 60 now)

-- | Walk @root@ and delete files that are exe binaries or library
-- archives for the link-cache-stat fixture.
removeLinkOutputs :: FilePath -> IO ()
removeLinkOutputs root = walkAll root $ \p n ->
  when (isLinkOutput n) (removeFile p)
  where
    isLinkOutput n =
      n == "link-cache-stat-exe"
        || ( "libHSlink-cache-stat" `isPrefixOf` n
               && any (`isSuffixOf` n) [".a", ".so", ".dylib"]
           )

walkAll :: FilePath -> (FilePath -> FilePath -> IO ()) -> IO ()
walkAll root act = go root
  where
    go dir = do
      exists <- doesDirectoryExist dir
      when exists $ do
        names <- listDirectory dir
        forM_ names $ \n -> do
          let p = dir </> n
          isDir <- doesDirectoryExist p
          if isDir then go p else act p n
