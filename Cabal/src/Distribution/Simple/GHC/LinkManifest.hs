{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Content-addressed cache for link outputs (@.a@, @.so@,
-- executables, etc.). See @Note [Link manifest cache]@ in
-- "Distribution.Simple.GHC.Build.Link" for design rationale.
module Distribution.Simple.GHC.LinkManifest
  ( withSkippableLink
  , LinkContext (..)
  , noCacheContext
  , skipReason
  ) where

import Distribution.Compat.Prelude
import Prelude ()

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, try)
import Control.Monad (forM, forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.IO.Unsafe (unsafePerformIO)
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

import qualified Data.Digest.XXHash.FFI as XXH
import Distribution.Simple.Utils (die', info, noticeNoWrap)
import Distribution.Utils.MD5 (md5, showMD5)
import Distribution.Verbosity (Verbosity)
import Numeric (showHex)

#if !defined(mingw32_HOST_OS)
import qualified System.Posix.Files as Posix
#endif

-- | Default cap when @CABAL_LINK_CACHE_MAX_BYTES@ is unset or unparseable.
defaultMaxBytes :: Integer
defaultMaxBytes = 5 * 1024 * 1024 * 1024

-- | Per-process set of keys for which we've already emitted a notice.
-- The cache layer fails soft (any IOException downgrades to a plain
-- linker run), and a chronic failure can spam the build log. We log
-- the first occurrence of each unique key at notice level so the user
-- knows the cache is degraded, and subsequent occurrences only at
-- info so the rest of the build stays readable.
--
-- Module-level state via 'unsafePerformIO' is the standard pattern
-- here: there's no other shared place to hang per-process state
-- across calls to 'withSkippableLink' from different setup
-- invocations.
{-# NOINLINE noticeOnceState #-}
noticeOnceState :: IORef (Set.Set String)
noticeOnceState = unsafePerformIO (newIORef Set.empty)

-- | Log @msg@ at notice level the first time @key@ is seen this
-- process; thereafter log the same message at info level only.
noticeOnce :: Verbosity -> String -> String -> IO ()
noticeOnce verbosity key msg = do
  isFirst <- atomicModifyIORef' noticeOnceState $ \s ->
    if Set.member key s
      then (s, False)
      else (Set.insert key s, True)
  if isFirst
    then noticeNoWrap verbosity (msg <> "\n")
    else info verbosity msg

-- | In-memory stat-index: maps each input file's absolute path to
-- @(size, mtime, inode, hash)@. If the on-disk file's @(size, mtime,
-- inode)@ all match the stored tuple we trust the stored hash and
-- skip the file read.
--
-- Inode is included as defence in depth against
-- @tar --preserve-timestamps@-style replacement: another process can
-- write byte-different content with identical size and mtime, but
-- it cannot keep the inode (the rename swap allocates a fresh one).
-- On Windows inode is always 0, so the check is effectively a
-- @(size, mtime)@ check there, matching the prior behaviour.
type StatIndex = Map.Map FilePath StatEntry

type StatEntry = (Integer, String, Integer, String)
  -- ^ @(size, mtime_picos, inode, hash_hex)@

-- | Sidecar filename relative to the cache root. The version suffix
-- gets bumped whenever the encoded row format or hash algorithm
-- changes. Stale older-version files are simply ignored (and
-- eventually GC'd along with their accompanying blobs).
statIndexName :: FilePath
statIndexName = ".stat-index.v2"

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
--   on input hashing (forces a full read+xxh64 of every input file).
-- * @CABAL_LINK_CACHE_NO_STATS=1@ disables the per-link telemetry append
--   to @.stats.jsonl@ under the cache root.
-- * @CABAL_LINK_CACHE_VERIFY=1@ enables canary mode: on a hit the
--   linker still runs and its output is bytewise-compared against the
--   cached blob. Mismatches are reported and dumped under
--   @divergences\/\<key\>\/@.
-- * @CABAL_LINK_CACHE_VERIFY_FAIL=1@ (only meaningful together with
--   @CABAL_LINK_CACHE_VERIFY@) escalates a verification mismatch to a
--   hard build error rather than a log message.

-- | Per-link context: the tool, the toolchain identity that has to be
-- in the cache key, and an optional reason to skip the cache entirely
-- for this call.
--
-- The toolchain identity carries the compiler id and the resolved
-- paths of the relevant link tools (ghc, ld). Without this a system
-- linker upgrade can produce different output bytes from byte-equal
-- inputs and the cache would silently return stale blobs.
--
-- The skip reason lets callers opt out of the cache when their
-- enumeration of link inputs is incomplete or untrusted (e.g. when
-- 'linkDepArchives' could not confirm every dep-package archive).
-- A skipped link still records a stats record so the
-- ratio of skipped-to-cached calls is observable.
data LinkContext = LinkContext
  { lcTool :: !String
  -- ^ Tool identifier, e.g. @"ghc-link-exe"@, @"ar-static"@. Included
  -- in the cache key so two tools writing to the same target never
  -- collide.
  , lcToolchainId :: !String
  -- ^ Stable identity of the toolchain (compiler id + resolved tool
  -- paths). Included in the cache key.
  , lcSkipReason :: !(Maybe String)
  -- ^ @Just r@ skips the cache entirely with reason @r@ logged at
  -- notice; the inner action runs unconditionally.
  }

-- | A 'LinkContext' that opts the link out of the cache, for callers
-- that hit a situation where reading the cache would be unsafe.
noCacheContext :: String -> String -> String -> LinkContext
noCacheContext tool tcid reason =
  LinkContext
    { lcTool = tool
    , lcToolchainId = tcid
    , lcSkipReason = Just reason
    }

-- | Convenience: set a 'lcSkipReason' on an existing context.
skipReason :: String -> LinkContext -> LinkContext
skipReason r ctx = ctx{lcSkipReason = Just r}

withSkippableLink
  :: Verbosity
  -> LinkContext
  -- ^ Per-call context (tool, toolchain identity, optional skip).
  -> FilePath
  -- ^ The target file the inner action will produce.
  -> [FilePath]
  -- ^ Input files whose bytes determine the output bytes.
  -> IO ()
  -- ^ The original link action.
  -> IO ()
withSkippableLink verbosity ctx target inputs action = do
  disabled <- lookupEnv "CABAL_LINK_CACHE_DISABLE"
  case (disabled, lcSkipReason ctx) of
    (Just s, _) | not (null s) -> action
    (_, Just r) -> do
      noticeNoWrap verbosity $
        "[link-cache] SKIPPED (" <> lcTool ctx <> ") " <> target
          <> ": " <> r <> "\n"
      t0 <- getCurrentTime
      action
      t1 <- getCurrentTime
      appendStatsSilently target (lcTool ctx) StatsSkipped inputs t0 t1
    _ -> cachedLink verbosity ctx target inputs action

-- | Outcome of a single 'cachedLink' invocation, used for telemetry.
data StatsOutcome
  = StatsHit
  | StatsMiss
  | StatsDisabled
  | StatsSkipped
  | StatsHitVerified
  | StatsHitDiverged

outcomeWord :: StatsOutcome -> String
outcomeWord StatsHit = "hit"
outcomeWord StatsMiss = "miss"
outcomeWord StatsDisabled = "disabled"
outcomeWord StatsSkipped = "skipped"
outcomeWord StatsHitVerified = "hit-verified"
outcomeWord StatsHitDiverged = "hit-diverged"

-- | Wrap the cache logic so any IOError (no writable @$XDG_CACHE_HOME@
-- — e.g. nix sandbox sets @HOME=/homeless-shelter@; read-only home;
-- disk full) downgrades to a plain @action@ run. The cache is a
-- correctness-preserving optimisation; failing soft is the right
-- default for a build-tool patch.
cachedLink :: Verbosity -> LinkContext -> FilePath -> [FilePath] -> IO () -> IO ()
cachedLink verbosity ctx target inputs action = do
  t0 <- getCurrentTime
  outcome <-
    cachedLinkUnsafe verbosity ctx target inputs action `catch` \e -> do
      -- A chronic cause (e.g. unwritable $HOME under nix sandbox)
      -- will fire here on every link. Notice the first instance per
      -- process so the user sees the cache is off; info the rest.
      noticeOnce verbosity "DISABLED" $
        "[link-cache] DISABLED (" <> lcTool ctx <> "): " <> show (e :: IOException)
      action
      return StatsDisabled
  t1 <- getCurrentTime
  appendStatsSilently target (lcTool ctx) outcome inputs t0 t1

cachedLinkUnsafe :: Verbosity -> LinkContext -> FilePath -> [FilePath] -> IO () -> IO StatsOutcome
cachedLinkUnsafe verbosity ctx target inputs action = do
  let tool = lcTool ctx
  cacheDir <- linkCacheDir
  createDirectoryIfMissing True cacheDir
  let indexPath = cacheDir </> statIndexName
  noStat <- lookupEnv "CABAL_LINK_CACHE_NO_STAT"
  let useStat = case noStat of
        Just s | not (null s) -> False
        _ -> True
#if defined(mingw32_HOST_OS)
  -- 'fileInode' returns 0 on Windows (no inode equivalent without
  -- 'GetFileInformationByHandle'), so the @(size, mtime, inode)@
  -- stat-key degrades to @(size, mtime)@. That is strictly weaker
  -- than the POSIX version against tar-style restore patterns that
  -- preserve mtime. Notice this once per process so the user can
  -- choose to disable the short-circuit (CABAL_LINK_CACHE_NO_STAT=1)
  -- if it is a concern.
  when useStat $
    noticeOnce verbosity "WINDOWS_STAT_DEGRADED" $
      "[link-cache] note: stat short-circuit on Windows is (size, mtime)-only "
        <> "(no inode); set CABAL_LINK_CACHE_NO_STAT=1 to disable it."
#endif
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
  let key = computeKey (takeFileName target) tool (lcToolchainId ctx) inputDigests
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
          --
          -- Both branches log at notice level so the user sees the
          -- cache acting on every build, not just with -v.
          alreadyCorrect <- targetMatchesStamp target key
          if alreadyCorrect
            then noticeNoWrap verbosity $
              "[link-cache] HIT (already-current) (" <> tool <> ") " <> target <> "\n"
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
      -- Notice level: a MISS is "cache is populating" -- the user
      -- wants to see that the cache is engaged even when this build
      -- doesn't benefit (the next one will).
      noticeNoWrap verbosity $
        "[link-cache] MISS (" <> tool <> ") " <> target <> "\n"
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
  return (takeFileName path, xxh64Hex bytes)

-- | XXH64 of the input bytes, rendered as a zero-padded 16-char hex
-- string. Roughly 5-10x faster than MD5 on modern CPUs, which is what
-- the cold-cache cost on a large dep cone is bottlenecked on. Not
-- cryptographically collision-resistant -- the cache is a trust-the-
-- user-not-an-attacker artefact anyway, and MD5 wouldn't be any
-- better in an adversarial scenario.
xxh64Hex :: BS.ByteString -> String
xxh64Hex bs =
  let h = XXH.xxh64 bs 0
      raw = showHex h ""
  in replicate (16 - length raw) '0' ++ raw

-- | On POSIX, the inode number from @stat()@. The stat short-circuit
-- includes this in its key so that a peer process replacing the
-- file via rename (a fresh inode) is detected even when size and
-- mtime are kept identical.
--
-- On Windows the equivalent (the file index from
-- @GetFileInformationByHandle@) is not available without opening a
-- file handle. We return 0 here, which makes the stat check
-- size-and-mtime-only on Windows -- the original behaviour.
fileInode :: FilePath -> IO Integer
#if defined(mingw32_HOST_OS)
fileInode _ = return 0
#else
fileInode path =
  fmap (fromIntegral . Posix.fileID) (Posix.getFileStatus path)
#endif

-- | Run @action@ over each input concurrently, with at most
-- @max 4 numCapabilities@ workers in flight. Order of results matches
-- the input list. Exceptions in workers are rethrown in the caller.
--
-- For short input lists the forkIO/QSem dispatch overhead exceeds
-- any I/O-overlap benefit, so we fall back to serial 'traverse'
-- below 'parallelHashThreshold' inputs. The empirical break-even
-- point is around half a dozen files on warm caches; we set it at
-- 8 to stay clearly above the noise floor.
--
-- Lib:Cabal builds may not have the threaded RTS, but 'forkIO' still
-- yields concurrent interleaving for I/O-bound work — and hashing
-- 100 object files is overwhelmingly I/O-bound.
traverseConcurrentlyBounded :: (a -> IO b) -> [a] -> IO [b]
traverseConcurrentlyBounded f xs
  | length xs < parallelHashThreshold = traverse f xs
  | otherwise = do
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

-- | Below this many inputs, fall back to serial hashing. Picked to
-- stay above the cost of one forkIO + one QSem signal pair.
parallelHashThreshold :: Int
parallelHashThreshold = 8

trySome :: IO a -> IO (Either SomeException a)
trySome = try

-- | Like 'hashInput', but consults a @(size, mtime, inode)@-keyed
-- sidecar index first. On a stat match the recorded xxh64 is reused
-- and the file's bytes are not read. On a miss we read+xxh64 the
-- bytes and update the index in memory (with @dirtyRef@ flipped to
-- 'True' so the on-disk index gets rewritten at the end of the link).
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
  ino <- fileInode path
  let mtimeStr = show (utcTimeToPOSIXSeconds mtime)
  ix <- getIndex
  case Map.lookup path ix of
    Just (s, m, i, h)
      | s == size && m == mtimeStr && i == ino ->
        return (takeFileName path, h)
    _ -> do
      bytes <- BS.readFile path
      let h = xxh64Hex bytes
      modifyIORef' indexRef (fmap (Map.insert path (size, mtimeStr, ino, h)))
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
      return $ Map.fromList
        [ (p', (sz, mt, ino, h))
        | line <- ls
        , Just (p', sz, mt, ino, h) <- [parseStatLine line]
        ]

-- | Accept the current five-field layout. Earlier four-field rows
-- (no inode) are silently dropped and self-heal on the next link.
parseStatLine :: BS.ByteString -> Maybe (FilePath, Integer, String, Integer, String)
parseStatLine line =
  case BS8.split '\t' line of
    [pBs, szBs, mtBs, inoBs, hBs] -> do
      sz <- readMaybe (BS8.unpack szBs)
      ino <- readMaybe (BS8.unpack inoBs)
      return (BS8.unpack pBs, sz, BS8.unpack mtBs, ino, BS8.unpack hBs)
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
          [ pth <> "\t" <> show sz <> "\t" <> mt <> "\t" <> show ino <> "\t" <> h
          | (pth, (sz, mt, ino, h)) <- Map.toAscList merged
          ]
  atomicWriteBytes path (BS8.pack body)

-- | Key is @(tool, target basename, toolchain id, sorted input digests)@.
-- The target's *directory* is intentionally absent: two checkouts of
-- the same project produce the same key and share cached link
-- outputs.
--
-- The toolchain id strings together the compiler id and the resolved
-- ghc/ld paths; an ld upgrade or a ghc-version flip therefore busts
-- the cache rather than yielding silent stale hits.
computeKey :: String -> String -> String -> [(FilePath, String)] -> String
computeKey targetName tool toolchainId digests = showMD5 (md5 keyBytes)
  where
    keyBytes =
      BS8.pack $
        "tool:" <> tool <> "\n"
          <> "name:" <> targetName <> "\n"
          <> "toolchain:" <> toolchainId <> "\n"
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
-- from /and/ the stat-trio of the target at that moment. The stamp
-- alone isn't enough: a stamp recording "key X" plus a target that
-- claims to be at key X could still have been overwritten by an
-- out-of-band tool between our write and the next build. The stat
-- trio catches that.
--
-- The file lives at @<target>.link-cache-stamp@ in a versioned
-- line-based format:
--
-- > v: 2
-- > key: <cache key>
-- > size: <integer>
-- > mtime: <utc-picos>
-- > inode: <integer or 0 on Windows>
--
-- Anything that doesn't parse as v2 is treated as missing. The
-- @v: N@ first-line discriminator lets future format bumps invalidate
-- old stamps without touching this code.
stampPath :: FilePath -> FilePath
stampPath target = target <> ".link-cache-stamp"

-- | Record the cache key and the target's current stat-trio so a
-- later @targetMatchesStamp@ can detect out-of-band mutation.
writeStampSilently :: FilePath -> String -> IO ()
writeStampSilently target key = go `catch` ignoreIO
  where
    ignoreIO :: IOException -> IO ()
    ignoreIO _ = return ()
    go = do
      sz <- getFileSize target
      mt <- getModificationTime target
      ino <- fileInode target
      let body =
            unlines
              [ "v: 2"
              , "key: " <> key
              , "size: " <> show sz
              , "mtime: " <> show (utcTimeToPOSIXSeconds mt)
              , "inode: " <> show ino
              ]
      atomicWriteBytes (stampPath target) (BS8.pack body)

-- | The stamp claims the target is currently at key @k@ /with this
-- specific stat trio/. We trust the stamp iff:
--
--   1. the target exists and the stamp exists;
--   2. the stamp parses as v2;
--   3. the recorded key matches the cache key we just computed; and
--   4. the recorded @(size, mtime, inode)@ matches the on-disk
--      target's current stat-trio.
--
-- If any of those fails we fall through to a fresh blob copy.
targetMatchesStamp :: FilePath -> String -> IO Bool
targetMatchesStamp target key = do
  targetExists <- doesFileExist target
  if not targetExists
    then return False
    else do
      mStamp <- readStamp (stampPath target)
      case mStamp of
        Nothing -> return False
        Just (recKey, recSize, recMtime, recIno)
          | recKey /= key -> return False
          | otherwise -> do
              sz <- getFileSize target
              mt <- getModificationTime target
              ino <- fileInode target
              let mtStr = show (utcTimeToPOSIXSeconds mt)
              return $
                recSize == sz
                  && recMtime == mtStr
                  && recIno == ino

-- | Parse a v2 stamp file. Returns @Nothing@ on any read or parse
-- failure, equivalent to "no stamp". Earlier (key-only) stamps fail
-- to parse and are silently invalidated.
readStamp :: FilePath -> IO (Maybe (String, Integer, String, Integer))
readStamp p = do
  exists <- doesFileExist p
  if not exists
    then return Nothing
    else (parseStamp <$> BS.readFile p) `catch` orNothing
  where
    orNothing :: IOException -> IO (Maybe (String, Integer, String, Integer))
    orNothing _ = return Nothing

parseStamp :: BS.ByteString -> Maybe (String, Integer, String, Integer)
parseStamp raw = do
  let ls = map BS8.unpack (BS8.lines raw)
      pick k =
        case [drop (length prefix) l | l <- ls, let prefix = k <> ": ", prefix `isPrefixOf` l] of
          (v : _) -> Just v
          _ -> Nothing
  v <- pick "v"
  if v /= "2" then Nothing else do
    key <- pick "key"
    szStr <- pick "size"
    mt <- pick "mtime"
    inoStr <- pick "inode"
    sz <- readMaybe szStr
    ino <- readMaybe inoStr
    return (key, sz, mt, ino)

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
