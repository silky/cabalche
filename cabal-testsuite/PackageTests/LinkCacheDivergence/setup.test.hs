-- Exercises the CABAL_LINK_CACHE_VERIFY canary. Plants a divergent
-- blob in the cache, deletes the link outputs to force a relink,
-- then re-builds in VERIFY mode. The cache layer should:
--
--   * detect that the freshly-linked output does not match the
--     cached blob and emit [link-cache] HIT-DIVERGED;
--   * dump both files under <cacheDir>/divergences/<key>/;
--   * leave the linker's fresh output in place (not the blob).
--
-- Then re-runs with CABAL_LINK_CACHE_VERIFY_FAIL=1 and asserts that
-- the next divergent hit fails the build hard.
import Test.Cabal.Prelude

import qualified Data.ByteString as BS
import Data.List (isPrefixOf, isSuffixOf)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  )

main = setupTest $ recordMode DoNotRecord $ do
  env <- getTestEnv
  let cacheDir = testWorkDir env </> "link-cache"
      buildRoot = testDistDir env </> "build"

  withEnv [("CABAL_LINK_CACHE_DIR", Just cacheDir)] $ do
    setup "configure" []

    -- Cold build: populates the cache.
    coldResult <- setup' "build" []
    assertOutputContains "[link-cache] MISS" coldResult

    -- Plant a divergent blob: overwrite every .blob with bytes that
    -- cannot possibly match the linker's output. We don't have to
    -- match the right blob to the right tool -- on any HIT in
    -- VERIFY mode the bytewise comparison will fail.
    liftIO $ planetDivergentBlobs cacheDir

    -- Remove the link outputs so the build is forced to relink.
    liftIO $ removeLinkOutputs buildRoot

    -- Hot build with VERIFY=1: every relink hits the cache, the
    -- bytes don't match, so we get HIT-DIVERGED on each one. The
    -- linker's fresh output remains the on-disk target.
    verifyResult <-
      withEnv [("CABAL_LINK_CACHE_VERIFY", Just "1")] $
        setup' "build" []
    assertOutputContains "[link-cache] HIT-DIVERGED" verifyResult
    assertOutputDoesNotContain "[link-cache] HIT-VERIFIED" verifyResult

    -- The dump directory should now contain at least one
    -- (blob, linker) pair under divergences/.
    liftIO $ do
      let divDir = cacheDir </> "divergences"
      exists <- doesDirectoryExist divDir
      unless exists $
        error $ "expected divergences/ directory under " ++ cacheDir
      entries <- listDirectory divDir
      when (null entries) $
        error "expected at least one divergence dump under divergences/"
      -- Inspect the first entry; it should contain both files.
      let entryDir = divDir </> head entries
      blobExists <- doesFileExist (entryDir </> "blob")
      linkerExists <- doesFileExist (entryDir </> "linker")
      unless (blobExists && linkerExists) $
        error $
          "expected blob and linker files under " ++ entryDir

    -- Replant divergence so the next build also hits the canary,
    -- this time with VERIFY_FAIL=1 set.
    liftIO $ planetDivergentBlobs cacheDir
    liftIO $ removeLinkOutputs buildRoot

    -- VERIFY_FAIL=1 escalates the divergence to a build error.
    -- `fails` flips the test's "expected exit" so a non-zero exit
    -- becomes the success case.
    failResult <-
      fails $
        withEnv
          [ ("CABAL_LINK_CACHE_VERIFY", Just "1")
          , ("CABAL_LINK_CACHE_VERIFY_FAIL", Just "1")
          ]
          $ setup' "build" []
    assertOutputContains "[link-cache] verification mismatch" failResult

-- | Overwrite every @.blob@ under @cacheDir@ with fixed garbage so a
-- VERIFY pass will bytewise-mismatch the linker's fresh output.
planetDivergentBlobs :: FilePath -> IO ()
planetDivergentBlobs cacheDir = do
  exists <- doesDirectoryExist cacheDir
  when exists $ do
    names <- listDirectory cacheDir
    forM_ names $ \n ->
      when (".blob" `isSuffixOf` n) $
        BS.writeFile (cacheDir </> n) (BS.pack [0xDE, 0xAD, 0xBE, 0xEF])

-- | Remove exe and library archives, leaving .o files intact so the
-- subsequent build only has to relink.
removeLinkOutputs :: FilePath -> IO ()
removeLinkOutputs root = walk root
  where
    walk dir = do
      exists <- doesDirectoryExist dir
      when exists $ do
        names <- listDirectory dir
        forM_ names $ \n -> do
          let p = dir </> n
          isDir <- doesDirectoryExist p
          if isDir
            then walk p
            else when (isLinkOutput n) $ do
              isFile <- doesFileExist p
              when isFile (removeFile p)

    isLinkOutput n =
      n == "link-cache-divergence-exe"
        || ( "libHSlink-cache-divergence" `isPrefixOf` n
               && any (`isSuffixOf` n) [".a", ".so", ".dylib"]
           )
