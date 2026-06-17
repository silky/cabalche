-- Demonstrates the link cache: a relink with byte-equal inputs (the
-- exe and library archives have just been deleted, so cabal will
-- re-run the link step) hits the cache instead of re-running the
-- linker. Asserts MISS on the cold run, HIT on the warm run.
--
-- CABAL_LINK_CACHE_DIR points the cache at a per-test temp dir so we
-- never touch the user's $XDG_CACHE_HOME and can re-run cleanly.
import Test.Cabal.Prelude

import Data.List (isPrefixOf, isSuffixOf)
import System.Directory
  (doesDirectoryExist, doesFileExist, listDirectory, removeFile)

-- setupTest (not setupAndCabalTest): a cabal-mode run would use the
-- user's system 'cabal' binary, which links against an unpatched
-- lib:Cabal and so wouldn't emit the HIT/MISS log lines we assert on.
-- Setup mode uses the in-tree (patched) Cabal.
--
-- recordMode DoNotRecord: absolute paths in HIT lines vary per
-- sandbox, so we don't ship a fixed expected-output file. The test
-- asserts on substrings inside the captured Result.
main = setupTest $ recordMode DoNotRecord $ do
  env <- getTestEnv
  let cacheDir = testWorkDir env </> "link-cache"

  withEnv [("CABAL_LINK_CACHE_DIR", Just cacheDir)] $ do
    -- Cold build: cache empty, every link should MISS.
    setup "configure" []
    coldResult <- setup' "build" []
    assertOutputContains "[link-cache] MISS" coldResult

    -- Force a relink with byte-equal inputs: delete the exe and
    -- library archives, but leave the .o files alone. The link
    -- callers in Distribution.Simple.GHC.Build.Link are unconditional
    -- inside withSkippableLink, so deletion of the output is
    -- sufficient -- no source touch needed.
    liftIO $
      removeLinkOutputs
        (testDistDir env </> "build")
        "link-cache-hit-exe"
        "libHSlink-cache-hit"

    -- Warm build: cache pre-populated, every link should HIT.
    warmResult <- setup' "build" []
    assertOutputContains "[link-cache] HIT" warmResult
    assertOutputDoesNotContain "[link-cache] MISS" warmResult

    -- Pin the exe-link specifically. Without explicit-object exe
    -- links (driven from componentIncludes clbi rather than --make
    -- mode), the exe's cache key was under-keyed and forced to
    -- 'SKIPPED (ghc-link-exe) … cache key not trusted'. Asserting
    -- that the warm pass references the exe link (it has to: the
    -- output exists) AND that no SKIPPED-with-the-exe-tool line is
    -- present guards against regressing to that path.
    assertOutputContains "ghc-link-exe" warmResult
    assertOutputDoesNotContain "SKIPPED (ghc-link-exe)" warmResult

-- | Walk @root@ and delete files that are exe binaries or library
-- archives matching @libPrefix@ (e.g. @libHSlink-cache-hit@). Object
-- files and other artefacts are left in place so the next build only
-- has to re-run the link step.
removeLinkOutputs :: FilePath -> String -> String -> IO ()
removeLinkOutputs root exeName libPrefix = walk root
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
      n == exeName
        || ( libPrefix `isPrefixOf` n
               && any (`isSuffixOf` n) [".a", ".so", ".dylib"]
           )
