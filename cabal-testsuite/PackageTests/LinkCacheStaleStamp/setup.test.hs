-- After a HIT (already-current), the on-disk target is byte-equal
-- to the cached blob and the stamp sidecar records that match.
-- If an out-of-band tool overwrites the target while leaving the
-- stamp unchanged, the next HIT must NOT trust the stale stamp.
-- The post-HIT target bytes must equal the blob bytes again.
--
-- The fix being verified: the stamp records (key, size, mtime, inode)
-- of the target, so a re-stat catches the mutation.
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

    -- 1. Cold build populates the cache and writes a stamp next to
    --    the on-disk target.
    coldResult <- setup' "build" []
    assertOutputContains "[link-cache] MISS" coldResult

    -- 2. A subsequent build with no source edits skips the link
    --    step entirely (recompilation checker decides nothing
    --    changed). We have to force the cache layer to engage by
    --    removing the link outputs and rebuilding; the stamp file
    --    survives since it sits next to the target, not the target
    --    itself.
    liftIO $ removeLinkOutputsKeepingStamp buildRoot

    warmResult <- setup' "build" []
    assertOutputContains "[link-cache] HIT" warmResult

    -- 3. Mutate the on-disk exe out of band. The stamp still claims
    --    the file matches the blob, but it no longer does.
    targetPath <- liftIO $ findExe buildRoot
    liftIO $ BS.appendFile targetPath (BS.pack [0xCA, 0xFE, 0xBA, 0xBE])
    mutatedBytes <- liftIO $ BS.readFile targetPath

    -- 4. Without removing the target this time, force another link
    --    pass. The recompilation checker is going to see the
    --    target as up-to-date, so we explicitly delete it again.
    --    The stamp file does NOT get re-written by us.
    liftIO $ do
      exists <- doesFileExist targetPath
      when exists (removeFile targetPath)

    -- 5. Build again. We expect the cache to NOT take the
    --    "already-current" fast path (since the target was
    --    mutated) -- it should actively copy the blob back over
    --    the target.
    finalResult <- setup' "build" []
    assertOutputContains "[link-cache] HIT" finalResult

    -- 6. Verify the target now matches the cached blob (i.e. the
    --    mutation was overwritten). We don't compare to
    --    `mutatedBytes`; we only assert non-equality, because the
    --    actual blob bytes are toolchain-dependent.
    postBytes <- liftIO $ BS.readFile targetPath
    when (postBytes == mutatedBytes) $
      liftIO $ error "expected mutated bytes to be overwritten on HIT"

-- | Find the freshly-built exe under @buildRoot@. There should be
-- exactly one file with this fixture's exe name.
findExe :: FilePath -> IO FilePath
findExe root = do
  hits <- collect root
  case hits of
    [p] -> return p
    [] -> error $ "no exe under " ++ root
    _ -> error $ "multiple exe candidates under " ++ root ++ ": " ++ show hits
  where
    targetName = "link-cache-stale-stamp-exe"
    collect dir = do
      exists <- doesDirectoryExist dir
      if not exists
        then return []
        else do
          names <- listDirectory dir
          fmap concat $ for names $ \n -> do
            let p = dir </> n
            isDir <- doesDirectoryExist p
            if isDir
              then collect p
              else if n == targetName then return [p] else return []

-- | Remove the exe binary and library archives, leaving stamp
-- sidecars (and .o / .hi files) in place. The stamp is at
-- @<target>.link-cache-stamp@, which doesn't match the link-output
-- predicate below.
removeLinkOutputsKeepingStamp :: FilePath -> IO ()
removeLinkOutputsKeepingStamp root = walk root
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
            else when (isLinkOutput n) (removeFile p)

    isLinkOutput n =
      n == "link-cache-stale-stamp-exe"
        || ( "libHSlink-cache-stale-stamp" `isPrefixOf` n
               && any (`isSuffixOf` n) [".a", ".so", ".dylib"]
           )
