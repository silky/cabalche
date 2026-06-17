-- Asserts that the link-cache telemetry sidecar gets at least one
-- miss line on a cold build and at least one hit line on a warm
-- build. Format-stability of the JSONL is checked very loosely
-- (substring grep) so that follow-up field additions don't break
-- this test.
import Test.Cabal.Prelude

import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  )

main = setupTest $ recordMode DoNotRecord $ do
  env <- getTestEnv
  let cacheDir = testWorkDir env </> "link-cache"
      statsPath = cacheDir </> ".stats.jsonl"

  withEnv [("CABAL_LINK_CACHE_DIR", Just cacheDir)] $ do
    setup "configure" []

    -- Cold build: at least one MISS record must end up in the stats
    -- file.
    _ <- setup' "build" []
    coldStats <- liftIO (readFileSafe statsPath)
    assertBool "stats file has a miss record" $
      "\"outcome\":\"miss\"" `isInfixOf` coldStats

    -- Delete link outputs and re-build: cache hot, expect at least
    -- one HIT record.
    liftIO $ removeLinkOutputs (testDistDir env </> "build")
    _ <- setup' "build" []
    warmStats <- liftIO (readFileSafe statsPath)
    assertBool "stats file has a hit record" $
      "\"outcome\":\"hit\"" `isInfixOf` warmStats

readFileSafe :: FilePath -> IO String
readFileSafe p = do
  exists <- doesFileExist p
  if exists then readFile p else return ""

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
      n == "link-cache-stats-exe"
        || ( "libHSlink-cache-stats" `isPrefixOf` n
               && any (`isSuffixOf` n) [".a", ".so", ".dylib"]
           )
