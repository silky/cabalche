{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Content-addressed cache for link outputs (@.a@, @.so@,
-- executables, etc.). See @Note [Link manifest cache]@ in
-- "Distribution.Simple.GHC.Build.Link" for design rationale.
module Distribution.Simple.GHC.LinkManifest
  ( withSkippableLink
  ) where

import Distribution.Compat.Prelude
import Prelude ()

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, throwIO, try)
import Control.Monad (forM, forM_)
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
import Data.Time.Clock (UTCTime, diffUTCTime)
import System.Environment (lookupEnv)
import System.FilePath (replaceExtension, takeDirectory, takeFileName, (</>))
import System.IO (BufferMode (..), IOMode (..), hClose, hPutStr, hSetBuffering, openBinaryTempFile, withFile)

import Distribution.Simple.Utils (die', info, noticeNoWrap)
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
-- * @CABAL_LINK_CACHE_NO_STATS=1@ disables the per-link telemetry append
--   to @.stats.jsonl@ under the cache root.
-- * @CABAL_LINK_CACHE_VERIFY=1@ enables canary mode: on a hit the
--   linker still runs and its output is bytewise-compared against the
--   cached blob. Mismatches are reported and dumped under
--   @divergences\/\<key\>\/@.
-- * @CABAL_LINK_CACHE_VERIFY_FAIL=1@ (only meaningful together with
--   @CABAL_LINK_CACHE_VERIFY@) escalates a verification mismatch to a
--   hard build error rather than a log message.
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

-- | Outcome of a single 'cachedLink' invocation, used for telemetry.
data StatsOutcome
  = StatsHit
  | StatsMiss
  | StatsDisabled
  | StatsHitVerified
  | StatsHitDiverged

outcomeWord :: StatsOutcome -> String
outcomeWord StatsHit = "hit"
outcomeWord StatsMiss = "miss"
outcomeWord StatsDisabled = "disabled"
outcomeWord StatsHitVerified = "hit-verified"
outcomeWord StatsHitDiverged = "hit-diverged"

-- | Wrap the cache logic so any IOError (no writable @$XDG_CACHE_HOME@
-- — e.g. nix sandbox sets @HOME=/homeless-shelter@; read-only home;
-- disk full) downgrades to a plain @action@ run. The cache is a
-- correctness-preserving optimisation; failing soft is the right
-- default for a build-tool patch.
cachedLink :: Verbosity -> FilePath -> String -> [FilePath] -> IO () -> IO ()
cachedLink verbosity target tool inputs action = do
  t0 <- getCurrentTime
  outcome <-
    cachedLinkUnsafe verbosity target tool inputs action `catch` \e -> do
      info verbosity $
        "[link-cache] DISABLED (" <> tool <> "): " <> show (e :: IOException)
      action
      return StatsDisabled
  t1 <- getCurrentTime
  appendStatsSilently target tool outcome inputs t0 t1

cachedLinkUnsafe :: Verbosity -> FilePath -> String -> [FilePath] -> IO () -> IO StatsOutcome
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
  -- The first link of a session (or after `cabal clean`) hashes every
  -- input from scratch. For projects with hundreds of MB of object
  -- files this is the dominant cost on a cold cache. Hash inputs in
  -- parallel; the stat short-circuit path is essentially free even
  -- serial, but the cold-read path overlaps disk I/O usefully.
  inputDigests <- traverseConcurrentlyBounded hashOne inputs
  when useStat $ flushStatIndex indexRef dirtyRef indexPath
  let key = computeKey (takeFileName target) tool inputDigests
  let blobPath = cacheDir </> key <> ".blob"
      manifestPath = cacheDir </> key <> ".manifest"
  hit <- doesFileExist blobPath
  if hit
    then do
      verifyMode <- lookupEnv "CABAL_LINK_CACHE_VERIFY"
      case verifyMode of
        Just s | not (null s) ->
          verifyHit verbosity tool target action blobPath cacheDir key
        _ -> do
          -- Common case on repeated builds: target on disk is already
          -- byte-equal to the blob (the stamp sidecar records which
          -- cache key the target was last populated from). Skip the
          -- atomicCopy entirely -- for a 20MB executable that is the
          -- difference between a 50ms cache hit and a sub-millisecond
          -- one.
          alreadyCorrect <- targetMatchesStamp target key
          if alreadyCorrect
            then info verbosity $
              "[link-cache] HIT-NOCOPY (" <> tool <> ") " <> target
            else do
              noticeNoWrap verbosity $
                "[link-cache] HIT (" <> tool <> ") " <> target <> "\n"
              atomicCopy blobPath target
              writeStampSilently target key
          -- Bump mtime so the GC's LRU eviction order reflects use,
          -- not just write time. Best-effort: ignore failure.
          touchSilently blobPath
          return StatsHit
    else do
      info verbosity $ "[link-cache] MISS (" <> tool <> ") " <> target
      action
      produced <- doesFileExist target
      when produced $ do
        atomicCopy target blobPath
        writeManifest manifestPath tool target inputDigests
        writeStampSilently target key
        enforceSizeCap verbosity cacheDir
      return StatsMiss

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

-- | Run @action@ over each input concurrently, with at most
-- @max 4 numCapabilities@ workers in flight. Order of results matches
-- the input list. Exceptions in workers are rethrown in the caller.
--
-- Lib:Cabal builds may not have the threaded RTS, but 'forkIO' still
-- yields concurrent interleaving for I/O-bound work — and hashing
-- 100 object files is overwhelmingly I/O-bound.
traverseConcurrentlyBounded :: (a -> IO b) -> [a] -> IO [b]
traverseConcurrentlyBounded f xs = do
  caps <- getNumCapabilities
  let cap = max 4 caps
  sem <- newQSem cap
  slots <- traverse (\_ -> newEmptyMVar) xs
  forM_ (zip slots xs) $ \(slot, x) ->
    forkIO $ do
      r <- trySome (bracket_ (waitQSem sem) (signalQSem sem) (f x))
      putMVar slot r
  forM slots $ \slot ->
    takeMVar slot >>= either throwIO pure

trySome :: IO a -> IO (Either SomeException a)
trySome = try

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

-- | Write the in-memory index back to disk. Concurrent cabal-install
-- processes pointed at the same cache may have updated the file
-- between our load and our flush; we re-read here and 'Map.union'
-- with our updates so we don't silently clobber peer writes. Our
-- entries win on conflict because we just verified them, so the
-- recorded hash is up to date for any path we touched.
writeStatIndex :: FilePath -> StatIndex -> IO ()
writeStatIndex path ours = do
  onDisk <- readStatIndex path
  let merged = Map.union ours onDisk
      body =
        unlines
          [ pth <> "\t" <> show sz <> "\t" <> mt <> "\t" <> h
          | (pth, (sz, mt, h)) <- Map.toAscList merged
          ]
  atomicWriteBytes path (BS8.pack body)

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

-- | Sidecar file recording which cache key @target@ was last populated
-- from. The presence of @<target>.link-cache-stamp@ containing the
-- current key means @target@ is already byte-equal to the blob, so
-- the atomicCopy on HIT can be skipped.
stampPath :: FilePath -> FilePath
stampPath target = target <> ".link-cache-stamp"

writeStampSilently :: FilePath -> String -> IO ()
writeStampSilently target key =
  atomicWriteBytes (stampPath target) (BS8.pack key) `catch` ignoreIO
  where
    ignoreIO :: IOException -> IO ()
    ignoreIO _ = return ()

targetMatchesStamp :: FilePath -> String -> IO Bool
targetMatchesStamp target key = do
  targetExists <- doesFileExist target
  if not targetExists
    then return False
    else do
      let p = stampPath target
      stampExists <- doesFileExist p
      if not stampExists
        then return False
        else do
          recorded <- (Just . BS8.unpack <$> BS.readFile p) `catch` orNothing
          return (recorded == Just key)
  where
    orNothing :: IOException -> IO (Maybe String)
    orNothing _ = return Nothing

-- | Append a JSONL line summarising one cache invocation. Best-effort:
-- any IOException is swallowed so telemetry never breaks a build.
-- Disabled by @CABAL_LINK_CACHE_NO_STATS=1@. Each record looks like:
--
-- > {"ts":1700000000.0,"tool":"ar-static","target":"...","outcome":"hit","input_bytes":12345,"ms":42}
appendStatsSilently
  :: FilePath
  -> String
  -> StatsOutcome
  -> [FilePath]
  -> UTCTime
  -> UTCTime
  -> IO ()
appendStatsSilently target tool outcome inputs t0 t1 =
  appendStats target tool outcome inputs t0 t1 `catch` ignoreIO
  where
    ignoreIO :: IOException -> IO ()
    ignoreIO _ = return ()

appendStats
  :: FilePath
  -> String
  -> StatsOutcome
  -> [FilePath]
  -> UTCTime
  -> UTCTime
  -> IO ()
appendStats target tool outcome inputs t0 t1 = do
  disabled <- lookupEnv "CABAL_LINK_CACHE_NO_STATS"
  case disabled of
    Just s | not (null s) -> return ()
    _ -> do
      cacheDir <- linkCacheDir
      createDirectoryIfMissing True cacheDir
      let statsPath = cacheDir </> ".stats.jsonl"
      rotateIfLarge statsPath
      totalBytes <- sumInputBytesSilently inputs
      let ts = realToFrac (utcTimeToPOSIXSeconds t0) :: Double
          ms = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
          line =
            "{"
              <> "\"ts\":" <> show ts
              <> ",\"tool\":" <> jsonStr tool
              <> ",\"target\":" <> jsonStr target
              <> ",\"outcome\":" <> jsonStr (outcomeWord outcome)
              <> ",\"input_bytes\":" <> show totalBytes
              <> ",\"ms\":" <> show (round ms :: Integer)
              <> "}\n"
      -- O_APPEND is atomic for writes under PIPE_BUF on POSIX; each
      -- record is well under that, so concurrent builds writing to
      -- the same stats file will not interleave individual records.
      withFile statsPath AppendMode $ \h -> do
        hSetBuffering h NoBuffering
        hPutStr h line

-- | If @path@ is larger than the rotation threshold (10 MiB), move it
-- to @path.1@ (overwriting any prior rotation) and start fresh. Keeps
-- long-lived developer machines from accumulating an unbounded
-- @.stats.jsonl@.
rotateIfLarge :: FilePath -> IO ()
rotateIfLarge path = do
  exists <- doesFileExist path
  when exists $ do
    sz <- getFileSize path
    when (sz > rotateThreshold) $ do
      removeIfExists (path <> ".1")
      renameFile path (path <> ".1")
  where
    rotateThreshold = 10 * 1024 * 1024

sumInputBytesSilently :: [FilePath] -> IO Integer
sumInputBytesSilently = fmap sum . traverse oneSize
  where
    oneSize :: FilePath -> IO Integer
    oneSize p = getFileSize p `catch` \(_ :: IOException) -> return 0

-- | Minimal JSON string escaping: enough for the tool identifiers and
-- file paths we emit. ASCII control chars beyond \\t\\r\\n are not
-- expected on these paths.
jsonStr :: String -> String
jsonStr s = '"' : concatMap esc s ++ "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c = [c]

-- | Re-run the linker and bytewise-compare its fresh output against
-- the cached blob. On match emits @[link-cache] HIT-VERIFIED@. On
-- mismatch emits @[link-cache] HIT-DIVERGED@, dumps both files to
-- @\<cacheDir\>/divergences/\<key\>/@, and (with
-- @CABAL_LINK_CACHE_VERIFY_FAIL=1@) escalates to a hard error. Even
-- on a mismatch the freshly-linked target is left in place, so the
-- build proceeds with the linker's authoritative output rather than
-- the suspect blob.
verifyHit
  :: Verbosity
  -> String
  -> FilePath
  -> IO ()
  -> FilePath
  -> FilePath
  -> String
  -> IO StatsOutcome
verifyHit verbosity tool target action blobPath cacheDir key = do
  action
  produced <- doesFileExist target
  if not produced
    then do
      noticeNoWrap verbosity $
        "[link-cache] HIT-DIVERGED (" <> tool <> ") " <> target
          <> ": linker produced no output\n"
      return StatsHitDiverged
    else do
      blobBytes <- BS.readFile blobPath
      freshBytes <- BS.readFile target
      if blobBytes == freshBytes
        then do
          -- Verify mode is typically left on for a whole CI run, so
          -- every link emits HIT-VERIFIED. That makes notice-level
          -- output spammy with no signal. The interesting event is
          -- HIT-DIVERGED, which stays at notice.
          info verbosity $
            "[link-cache] HIT-VERIFIED (" <> tool <> ") " <> target
          touchSilently blobPath
          return StatsHitVerified
        else do
          let dumpDir = cacheDir </> "divergences" </> key
          createDirectoryIfMissing True dumpDir
          atomicCopy blobPath (dumpDir </> "blob")
          atomicCopy target (dumpDir </> "linker")
          noticeNoWrap verbosity $
            "[link-cache] HIT-DIVERGED (" <> tool <> ") " <> target
              <> " (see " <> dumpDir <> ")\n"
          failHard <- lookupEnv "CABAL_LINK_CACHE_VERIFY_FAIL"
          case failHard of
            Just s | not (null s) ->
              die' verbosity $
                "[link-cache] verification mismatch for "
                  <> target <> " (tool=" <> tool <> ")"
            _ -> return ()
          return StatsHitDiverged
