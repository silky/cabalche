-- | Content-addressed cache for link outputs (@.a@, @.so@,
-- executables, etc.). See @Note [Link manifest cache]@ in
-- "Distribution.Simple.GHC.Build.Link" for design rationale.
module Distribution.Simple.GHC.LinkManifest
  ( withSkippableLink
  ) where

import Distribution.Compat.Prelude
import Prelude ()

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory
  ( XdgDirectory (..)
  , copyFile
  , createDirectoryIfMissing
  , doesFileExist
  , getFileSize
  , getModificationTime
  , getXdgDirectory
  , listDirectory
  , removeFile
  , renameFile
  , setModificationTime
  )
import System.Environment (lookupEnv)
import System.FilePath (replaceExtension, takeDirectory, takeFileName, (</>))
import System.IO (hClose, openBinaryTempFile)

import Distribution.Simple.Utils (info, noticeNoWrap)
import Distribution.Utils.MD5 (md5, showMD5)
import Distribution.Verbosity (Verbosity)

-- | Default cap when @CABAL_LINK_CACHE_MAX_BYTES@ is unset or unparseable.
defaultMaxBytes :: Integer
defaultMaxBytes = 5 * 1024 * 1024 * 1024

-- | In-memory stat-index: maps each input file's absolute path to
-- @(size, mtime, md5)@. If the @(size, mtime)@ of the file on disk
-- matches the stored tuple, we trust the stored md5 and skip the
-- file read.
type StatIndex = Map.Map FilePath (Integer, String, String)

-- | Sidecar filename relative to the cache root. The @.v1@ suffix
-- leaves room for incompatible format changes later (we'd bump to
-- @.v2@ and ignore stale @.v1@).
statIndexName :: FilePath
statIndexName = ".stat-index.v1"

-- | If the inputs hash to an entry already in the link cache, byte-copy
-- the saved output to @target@ and skip @action@. Otherwise run @action@
-- and stash its output in the cache for next time.
--
-- Env vars:
--
-- * @CABAL_LINK_CACHE_DISABLE=1@ bypasses the cache entirely.
-- * @CABAL_LINK_CACHE_DIR=\/path@ overrides the cache root
--   (default @$XDG_CACHE_HOME\/cabal\/link-cache@).
-- * @CABAL_LINK_CACHE_MAX_BYTES=N@ caps cache size in bytes; on a write
--   we evict oldest entries until under the cap (default 5 GiB).
-- * @CABAL_LINK_CACHE_NO_STAT=1@ disables the stat-based short-circuit
--   on input hashing (forces a full read+MD5 of every input file).
withSkippableLink
  :: Verbosity
  -> FilePath
  -- ^ The target file the inner action will produce.
  -> String
  -- ^ Tool identifier, e.g. @"ghc-link-exe"@, @"ar-static"@. Included
  -- in the cache key so two tools writing to the same target never
  -- collide.
  -> [FilePath]
  -- ^ Input files whose bytes determine the output bytes.
  -> IO ()
  -- ^ The original link action.
  -> IO ()
withSkippableLink verbosity target tool inputs action = do
  disabled <- lookupEnv "CABAL_LINK_CACHE_DISABLE"
  case disabled of
    Just s | not (null s) -> action
    _ -> cachedLink verbosity target tool inputs action

-- | Wrap the cache logic so any IOError (no writable @$XDG_CACHE_HOME@
-- — e.g. nix sandbox sets @HOME=/homeless-shelter@; read-only home;
-- disk full) downgrades to a plain @action@ run. The cache is a
-- correctness-preserving optimisation; failing soft is the right
-- default for a build-tool patch.
cachedLink :: Verbosity -> FilePath -> String -> [FilePath] -> IO () -> IO ()
cachedLink verbosity target tool inputs action =
  cachedLinkUnsafe verbosity target tool inputs action `catch` \e -> do
    info verbosity $
      "[link-cache] DISABLED (" <> tool <> "): " <> show (e :: IOException)
    action

cachedLinkUnsafe :: Verbosity -> FilePath -> String -> [FilePath] -> IO () -> IO ()
cachedLinkUnsafe verbosity target tool inputs action = do
  cacheDir <- linkCacheDir
  createDirectoryIfMissing True cacheDir
  let indexPath = cacheDir </> statIndexName
  noStat <- lookupEnv "CABAL_LINK_CACHE_NO_STAT"
  let useStat = case noStat of
        Just s | not (null s) -> False
        _ -> True
  indexRef <- newIORef (Nothing :: Maybe StatIndex)
  dirtyRef <- newIORef False
  let hashOne p
        | useStat = hashInputCached indexRef dirtyRef indexPath p
        | otherwise = hashInput p
  inputDigests <- traverse hashOne inputs
  when useStat $ flushStatIndex indexRef dirtyRef indexPath
  let key = computeKey (takeFileName target) tool inputDigests
  let blobPath = cacheDir </> key <> ".blob"
      manifestPath = cacheDir </> key <> ".manifest"
  hit <- doesFileExist blobPath
  if hit
    then do
      noticeNoWrap verbosity $
        "[link-cache] HIT (" <> tool <> ") " <> target <> "\n"
      atomicCopy blobPath target
      -- Bump mtime so the GC's LRU eviction order reflects use, not just
      -- write time. Best-effort: ignore failure.
      touchSilently blobPath
    else do
      info verbosity $ "[link-cache] MISS (" <> tool <> ") " <> target
      action
      produced <- doesFileExist target
      when produced $ do
        atomicCopy target blobPath
        writeManifest manifestPath tool target inputDigests
        enforceSizeCap verbosity cacheDir

linkCacheDir :: IO FilePath
linkCacheDir = do
  override <- lookupEnv "CABAL_LINK_CACHE_DIR"
  case override of
    Just dir | not (null dir) -> return dir
    _ -> do
      base <- getXdgDirectory XdgCache "cabal"
      return (base </> "link-cache")

hashInput :: FilePath -> IO (FilePath, String)
hashInput path = do
  bytes <- BS.readFile path
  return (takeFileName path, showMD5 (md5 bytes))

-- | Like 'hashInput', but consults a @(size, mtime)@-keyed sidecar
-- index first. On a stat match the recorded MD5 is reused and the
-- file's bytes are not read. On a miss we read+MD5 the bytes and
-- update the index in memory (with @dirtyRef@ flipped to 'True' so
-- the on-disk index gets rewritten at the end of the link).
--
-- The index is loaded lazily: 'Nothing' in @indexRef@ means "not
-- loaded yet". A read failure (missing file, corrupt line) falls
-- back to an empty index, so a corrupted sidecar self-heals on the
-- next link.
hashInputCached
  :: IORef (Maybe StatIndex)
  -> IORef Bool
  -> FilePath
  -- ^ Path to the sidecar index file.
  -> FilePath
  -- ^ Input file to hash.
  -> IO (FilePath, String)
hashInputCached indexRef dirtyRef indexPath path = do
  size <- getFileSize path
  mtime <- getModificationTime path
  let mtimeStr = show (utcTimeToPOSIXSeconds mtime)
  ix <- getIndex
  case Map.lookup path ix of
    Just (s, m, h) | s == size && m == mtimeStr ->
      return (takeFileName path, h)
    _ -> do
      bytes <- BS.readFile path
      let h = showMD5 (md5 bytes)
      modifyIORef' indexRef (fmap (Map.insert path (size, mtimeStr, h)))
      writeIORef dirtyRef True
      return (takeFileName path, h)
  where
    getIndex =
      readIORef indexRef >>= \case
        Just ix -> return ix
        Nothing -> do
          loaded <- readStatIndex indexPath
          writeIORef indexRef (Just loaded)
          return loaded

readStatIndex :: FilePath -> IO StatIndex
readStatIndex p = do
  exists <- doesFileExist p
  if not exists
    then return Map.empty
    else do
      raw <- BS.readFile p
      let ls = BS8.lines raw
      return $ Map.fromList [(p', (sz, mt, h)) | line <- ls, Just (p', sz, mt, h) <- [parseStatLine line]]

parseStatLine :: BS.ByteString -> Maybe (FilePath, Integer, String, String)
parseStatLine line =
  case BS8.split '\t' line of
    [pBs, szBs, mtBs, hBs] -> do
      sz <- readMaybe (BS8.unpack szBs)
      return (BS8.unpack pBs, sz, BS8.unpack mtBs, BS8.unpack hBs)
    _ -> Nothing

flushStatIndex :: IORef (Maybe StatIndex) -> IORef Bool -> FilePath -> IO ()
flushStatIndex indexRef dirtyRef path = do
  dirty <- readIORef dirtyRef
  when dirty $ do
    mix <- readIORef indexRef
    case mix of
      Just ix -> writeStatIndex path ix
      Nothing -> return ()

writeStatIndex :: FilePath -> StatIndex -> IO ()
writeStatIndex path ix = atomicWriteBytes path (BS8.pack body)
  where
    body =
      unlines
        [ pth <> "\t" <> show sz <> "\t" <> mt <> "\t" <> h
        | (pth, (sz, mt, h)) <- Map.toAscList ix
        ]

-- | Key is @(tool, target basename, sorted input digests)@. The target's
-- *directory* is intentionally absent: two checkouts of the same project
-- produce the same key and share cached link outputs.
computeKey :: String -> String -> [(FilePath, String)] -> String
computeKey targetName tool digests = showMD5 (md5 keyBytes)
  where
    keyBytes =
      BS8.pack $
        "tool:" <> tool <> "\n"
          <> "name:" <> targetName <> "\n"
          <> concatMap (\(b, h) -> h <> "  " <> b <> "\n") (sort digests)

writeManifest :: FilePath -> String -> FilePath -> [(FilePath, String)] -> IO ()
writeManifest path tool target digests = do
  ts <- getCurrentTime
  let body =
        unlines $
          [ "tool: " <> tool
          , "target: " <> target
          , "created: " <> show ts
          , "inputs:"
          ]
            <> ["  " <> h <> "  " <> b | (b, h) <- sort digests]
  atomicWriteBytes path (BS8.pack body)

atomicCopy :: FilePath -> FilePath -> IO ()
atomicCopy src dst = do
  let dir = takeDirectory dst
  createDirectoryIfMissing True dir
  (tmpPath, h) <- openBinaryTempFile dir (takeFileName dst <> ".tmp")
  hClose h
  copyFile src tmpPath
  renameFile tmpPath dst

atomicWriteBytes :: FilePath -> BS.ByteString -> IO ()
atomicWriteBytes path bytes = do
  let dir = takeDirectory path
  createDirectoryIfMissing True dir
  (tmpPath, h) <- openBinaryTempFile dir (takeFileName path <> ".tmp")
  BS.hPut h bytes
  hClose h
  renameFile tmpPath path

touchSilently :: FilePath -> IO ()
touchSilently p = do
  now <- getCurrentTime
  setModificationTime p now `catch` ignoreIO
  where
    ignoreIO :: IOException -> IO ()
    ignoreIO _ = return ()

-- | If the cache is over its byte cap, delete oldest blobs (and their
-- manifest siblings) until under cap. Called on every miss-with-write.
enforceSizeCap :: Verbosity -> FilePath -> IO ()
enforceSizeCap verbosity cacheDir = do
  capStr <- lookupEnv "CABAL_LINK_CACHE_MAX_BYTES"
  let cap = case capStr >>= readMaybe of
        Just n | n > 0 -> n
        _ -> defaultMaxBytes
  names <- listDirectory cacheDir
  let blobNames = [n | n <- names, ".blob" `isSuffixOf` n]
  entries <- for blobNames $ \n -> do
    let p = cacheDir </> n
    sz <- getFileSize p
    mt <- getModificationTime p
    return (p, sz, mt)
  let total = sum [sz | (_, sz, _) <- entries]
  when (total > cap) $ do
    info verbosity $
      "[link-cache] GC: total=" <> show total <> " cap=" <> show cap
    evict cap total (sortBy (comparing (\(_, _, mt) -> mt)) entries)
  where
    evict _ _ [] = return ()
    evict cap total ((p, sz, _) : rest)
      | total <= cap = return ()
      | otherwise = do
          removeIfExists p
          removeIfExists (replaceExtension p ".manifest")
          evict cap (total - sz) rest

removeIfExists :: FilePath -> IO ()
removeIfExists p = do
  exists <- doesFileExist p
  when exists (removeFile p)
