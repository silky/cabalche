{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

module Distribution.Simple.GHC.Build.Link where

import Distribution.Compat.Prelude
import Prelude ()

import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.Set as Set
import Distribution.Backpack
import Distribution.Compat.Binary (encode)
import Distribution.Compat.ResponseFile
import Distribution.InstalledPackageInfo (InstalledPackageInfo)
import qualified Distribution.InstalledPackageInfo as IPI
import qualified Distribution.InstalledPackageInfo as InstalledPackageInfo
import Distribution.Package
import Distribution.PackageDescription as PD
import Distribution.PackageDescription.Utils (cabalBug)
import Distribution.Pretty
import Distribution.Simple.Build.Inputs
import Distribution.Simple.BuildPaths
import Distribution.Simple.Compiler
import Distribution.Simple.Errors
import Distribution.Simple.GHC.Build.Modules
import Distribution.Simple.GHC.Build.Utils (exeTargetName, flibBuildName, flibTargetName, withDynFLib)
import Distribution.Simple.GHC.ImplInfo
import qualified Distribution.Simple.GHC.Internal as Internal
import Distribution.Simple.GHC.LinkManifest
  ( LinkContext (..)
  , skipReason
  , withSkippableLink
  )
import Distribution.Simple.LocalBuildInfo
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.Program
import qualified Distribution.Simple.Program.Ar as Ar
import Distribution.Simple.Program.GHC
import qualified Distribution.Simple.Program.Ld as Ld
import Distribution.Simple.Setup.Common
import Distribution.Simple.Setup.Config
import Distribution.Simple.Setup.Repl
import Distribution.Simple.Utils
import Distribution.System
import Distribution.Types.ComponentLocalBuildInfo
import Distribution.Utils.NubList
import Distribution.Utils.Path
import Distribution.Verbosity
import Distribution.Version

import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , renameFile
  )
import System.FilePath
  ( isRelative
  , replaceExtension
  )
import qualified System.FilePath as FP

-- | Links together the object files of the Haskell modules and extra sources
-- using the context in which the component is being built.
--
-- If the build kind is 'BuildRepl', we load the component into GHCi instead of linking.
linkOrLoadComponent
  :: ConfiguredProgram
  -- ^ The configured GHC program that will be used for linking
  -> VerbosityHandles
  -- ^ Handles used for logging
  -> PackageDescription
  -- ^ The package description containing the component being built
  -> [SymbolicPath Pkg File]
  -- ^ The full list of extra build sources (all C, C++, Js,
  -- Asm, and Cmm sources), which were compiled to object
  -- files.
  -> (SymbolicPath Pkg (Dir Artifacts), SymbolicPath Pkg (Dir Build))
  -- ^ The build target dir, and the target dir.
  -- See Note [Build Target Dir vs Target Dir] in Distribution.Simple.GHC.Build
  -> ((Bool -> [BuildWay], Bool -> BuildWay, BuildWay), BuildWay -> GhcOptions)
  -- ^ The set of build ways wanted based on the user opts, and a function to
  -- convert a build way into the set of ghc options that were used to build
  -- that way.
  -> PreBuildComponentInputs
  -- ^ The context and component being built in it.
  -> IO ()
linkOrLoadComponent
  ghcProg
  verbHandles
  pkg_descr
  extraSources
  (buildTargetDir, targetDir)
  ((wantedLibWays, wantedFLibWay, wantedExeWay), buildOpts)
  pbci = do
    let
      verbosity = mkVerbosity verbHandles $ buildVerbosity pbci
      target = targetInfo pbci
      component = buildComponent pbci
      what = buildingWhat pbci
      lbi = localBuildInfo pbci
      bi = buildBI pbci
      clbi = buildCLBI pbci
      isIndef = componentIsIndefinite clbi
      mbWorkDir = mbWorkDirLBI lbi
      tempFileOptions = commonSetupTempFileOptions $ buildingWhatCommonFlags what

      -- See Note [Symbolic paths] in Distribution.Utils.Path
      i = interpretSymbolicPathLBI lbi

    -- ensure extra lib dirs exist before passing to ghc
    cleanedExtraLibDirs <- liftIO $ filterM (doesDirectoryExist . i) (extraLibDirs bi)
    cleanedExtraLibDirsStatic <- liftIO $ filterM (doesDirectoryExist . i) (extraLibDirsStatic bi)

    let
      extraSourcesObjs :: [RelativePath Artifacts File]
      extraSourcesObjs =
        [ makeRelativePathEx $ getSymbolicPath src `replaceExtension` objExtension
        | src <- extraSources
        ]

      -- TODO: Shouldn't we use withStaticLib for libraries and something else
      -- for foreign libs in the three cases where we use `withFullyStaticExe` below?
      linkerOpts rpaths =
        mempty
          { ghcOptLinkOptions =
              [ "-static"
              | withFullyStaticExe lbi
              ]
                -- Pass extra `ld-options` given
                -- through to GHC's linker.
                ++ maybe
                  []
                  programOverrideArgs
                  (lookupProgram ldProgram (withPrograms lbi))
          , ghcOptLinkLibs =
              if withFullyStaticExe lbi
                then extraLibsStatic bi
                else extraLibs bi
          , ghcOptLinkLibPath =
              toNubListR $
                if withFullyStaticExe lbi
                  then cleanedExtraLibDirsStatic
                  else cleanedExtraLibDirs
          , ghcOptLinkFrameworks = toNubListR $ map getSymbolicPath $ PD.frameworks bi
          , ghcOptLinkFrameworkDirs = toNubListR $ PD.extraFrameworkDirs bi
          , ghcOptInputFiles =
              toNubListR
                [ coerceSymbolicPath $ buildTargetDir </> obj
                | obj <- extraSourcesObjs
                ]
          , ghcOptNoLink = Flag False
          , ghcOptRPaths = rpaths
          }

    case what of
      BuildRepl replFlags -> liftIO $ do
        let
          -- For repl we use the vanilla (static) ghc options
          staticOpts = buildOpts StaticWay
          replOpts =
            staticOpts
              { -- Repl options use Static as the base, but doesn't need to pass -static.
                -- However, it maybe should, for uniformity.
                ghcOptDynLinkMode = NoFlag
              , ghcOptExtra =
                  Internal.filterGhciFlags
                    (ghcOptExtra staticOpts)
                    <> replOptionsFlags (replReplOptions replFlags)
              }
              -- For a normal compile we do separate invocations of ghc for
              -- compiling as for linking. But for repl we have to do just
              -- the one invocation, so that one has to include all the
              -- linker stuff too, like -l flags and any .o files from C
              -- files etc.
              --
              -- TODO: The repl doesn't use the runtime paths from linkerOpts
              -- (ghcOptRPaths), which looks like a bug. After the refactor we
              -- can fix this.
              `mappend` linkerOpts mempty
              `mappend` mempty
                { ghcOptMode = toFlag GhcModeInteractive
                , ghcOptOptimisation = toFlag GhcNoOptimisation
                }
          replOpts_final =
            replOpts
              { ghcOptInputModules = replNoLoad (replReplOptions replFlags) (ghcOptInputModules replOpts)
              , ghcOptInputFiles = replNoLoad (replReplOptions replFlags) (ghcOptInputFiles replOpts)
              }

        -- TODO: problem here is we need the .c files built first, so we can load them
        -- with ghci, but .c files can depend on .h files generated by ghc by ffi
        -- exports.
        when (case component of CLib lib -> null (allLibModules lib clbi); _ -> False) $
          warn verbosity "No exposed modules"
        runReplOrWriteFlags
          ghcProg
          verbHandles
          lbi
          replFlags
          replOpts_final
          (pkgName (PD.package pkg_descr))
          target
      _otherwise ->
        let
          runGhcProg =
            runGHCWithResponseFile
              "ghc.rsp"
              Nothing
              tempFileOptions
              verbosity
              ghcProg
              comp
              platform
              mbWorkDir
          platform = hostPlatform lbi
          comp = compiler lbi
          get_rpaths ways =
            if DynWay `Set.member` ways then getRPaths pbci else return (toNubListR [])
         in
          unless (componentIsIndefinite clbi) $ do
            -- If not building dynamically, we don't pass any runtime paths.
            liftIO $ do
              info verbosity "Linking..."
              let linkExeLike name = do
                    rpaths <- get_rpaths (Set.singleton wantedExeWay)
                    linkExecutable verbosity (linkerOpts rpaths) (wantedExeWay, buildOpts) targetDir name runGhcProg lbi clbi
              case component of
                CLib lib -> do
                  let libWays = wantedLibWays isIndef
                  rpaths <- get_rpaths (Set.fromList libWays)
                  linkLibrary buildTargetDir cleanedExtraLibDirs verbosity runGhcProg lib lbi clbi extraSources rpaths libWays
                CFLib flib -> do
                  let flib_way = wantedFLibWay (withDynFLib flib)
                  rpaths <- get_rpaths (Set.singleton flib_way)
                  linkFLib verbosity flib bi lbi (linkerOpts rpaths) (flib_way, buildOpts) targetDir runGhcProg
                CExe exe -> linkExeLike (exeName exe)
                CTest test -> linkExeLike (testName test)
                CBench bench -> linkExeLike (benchmarkName bench)

-- | Link a library component
linkLibrary
  :: SymbolicPath Pkg (Dir Artifacts)
  -- ^ The library target build directory
  -> [SymbolicPath Pkg (Dir Lib)]
  -- ^ The list of extra lib dirs that exist (aka "cleaned")
  -> Verbosity
  -> (GhcOptions -> IO ())
  -- ^ Run the configured Ghc program
  -> Library
  -> LocalBuildInfo
  -> ComponentLocalBuildInfo
  -> [SymbolicPath Pkg File]
  -- ^ Extra build sources (that were compiled to objects)
  -> NubListR FilePath
  -- ^ A list with the runtime-paths (rpaths), or empty if not linking dynamically
  -> [BuildWay]
  -- ^ Wanted build ways and corresponding build options
  -> IO ()
linkLibrary buildTargetDir cleanedExtraLibDirs verbosity runGhcProg lib lbi clbi extraSources rpaths wantedWays = do
  let
    i = interpretSymbolicPathLBI lbi
    compiler_id = compilerId comp
    comp = compiler lbi
    implInfo = getImplInfo comp
    uid = componentUnitId clbi
    libBi = libBuildInfo lib
    vanillaLibFilePath = buildTargetDir </> makeRelativePathEx (mkLibName uid)
    profileLibFilePath = buildTargetDir </> makeRelativePathEx (mkProfLibName uid)
    sharedLibFilePath =
      buildTargetDir
        </> makeRelativePathEx (mkSharedLibName (hostPlatform lbi) compiler_id uid)
    profSharedLibFilePath =
      buildTargetDir
        </> makeRelativePathEx (mkProfSharedLibName (hostPlatform lbi) compiler_id uid)
    staticLibFilePath =
      buildTargetDir
        </> makeRelativePathEx (mkStaticLibName (hostPlatform lbi) compiler_id uid)
    bytecodeLibFilePath =
      buildTargetDir
        </> makeRelativePathEx (mkBytecodeLibName compiler_id uid)
    ghciLibFilePath = buildTargetDir </> makeRelativePathEx (Internal.mkGHCiLibName uid)
    ghciProfLibFilePath = buildTargetDir </> makeRelativePathEx (Internal.mkGHCiProfLibName uid)

    getObjWayFiles :: BuildWay -> IO [SymbolicPath Pkg File]
    getObjWayFiles w = getObjFiles (buildWayObjectExtension objExtension w) (buildWayObjectExtension objExtension w)

    getObjBytecodeWayFiles :: BuildWay -> IO [SymbolicPath Pkg File]
    getObjBytecodeWayFiles companion_way = getObjFiles "gbc" (buildWayObjectExtension objExtension companion_way)

    getObjFiles :: String -> String -> IO [SymbolicPath Pkg File]
    getObjFiles hs_ext obj_ext =
      mconcat
        [ Internal.getHaskellObjects
            implInfo
            lib
            lbi
            clbi
            buildTargetDir
            hs_ext
            True
        , pure $ map (srcObjPath obj_ext) extraSources
        ]

    -- Get the @.o@ path from a source path (e.g. @.hs@),
    -- in the library target build directory.
    srcObjPath :: String -> SymbolicPath Pkg File -> SymbolicPath Pkg File
    srcObjPath obj_ext srcPath =
      case symbolicPathRelative_maybe objPath of
        -- Absolute path: should already be in the target build directory
        -- (e.g. a preprocessed file)
        -- TODO: assert this?
        Nothing -> objPath
        Just objRelPath -> coerceSymbolicPath buildTargetDir </> objRelPath
      where
        objPath = srcPath `replaceExtensionSymbolicPath` obj_ext

    -- I'm fairly certain that, just like the executable, we can keep just the
    -- module input list, and point to the right sources dir (as is already
    -- done), and GHC will pick up the right suffix (p_ for profile, dyn_ when
    -- -shared...). The downside to doing this is that GHC would have to
    -- reconstruct the module graph again.
    -- That would mean linking the lib would be just like the executable, and
    -- we could more easily merge the two.
    --
    -- Right now, instead, we pass the path to each object file.
    ghcBaseLinkArgs :: GhcOptions
    ghcBaseLinkArgs =
      Internal.linkGhcOptions (verbosityLevel verbosity) lbi libBi clbi
        <> mempty
          { ghcOptExtra = hcStaticOptions GHC libBi
          , ghcOptNoAutoLinkPackages = toFlag True
          }

    -- After the relocation lib is created we invoke ghc -shared
    -- with the dependencies spelled out as -package arguments
    -- and ghc invokes the linker with the proper library paths
    ghcSharedLinkArgs :: [SymbolicPath Pkg File] -> GhcOptions
    ghcSharedLinkArgs dynObjectFiles =
      ghcBaseLinkArgs
        { ghcOptShared = toFlag True
        , ghcOptDynLinkMode = toFlag GhcDynamicOnly
        , ghcOptInputFiles = toNubListR $ map coerceSymbolicPath dynObjectFiles
        , ghcOptOutputFile = toFlag sharedLibFilePath
        , ghcOptDylibName = mempty
        , ghcOptLinkLibs = extraLibs libBi
        , ghcOptLinkLibPath = toNubListR cleanedExtraLibDirs
        , ghcOptLinkFrameworks = toNubListR $ map getSymbolicPath $ PD.frameworks libBi
        , ghcOptLinkFrameworkDirs =
            toNubListR $ PD.extraFrameworkDirs libBi
        , ghcOptRPaths = rpaths
        }
    ghcProfSharedLinkArgs pdynObjectFiles =
      ghcBaseLinkArgs
        { ghcOptShared = toFlag True
        , ghcOptProfilingMode = toFlag True
        , ghcOptProfilingAuto =
            Internal.profDetailLevelFlag
              True
              (withProfLibDetail lbi)
        , ghcOptDynLinkMode = toFlag GhcDynamicOnly
        , ghcOptInputFiles = toNubListR pdynObjectFiles
        , ghcOptOutputFile = toFlag profSharedLibFilePath
        , ghcOptDylibName = mempty
        , ghcOptLinkLibs = extraLibs libBi
        , ghcOptLinkLibPath = toNubListR cleanedExtraLibDirs
        , ghcOptLinkFrameworks = toNubListR $ map getSymbolicPath $ PD.frameworks libBi
        , ghcOptLinkFrameworkDirs =
            toNubListR $ PD.extraFrameworkDirs libBi
        , ghcOptRPaths = rpaths
        }
    ghcStaticLinkArgs staticObjectFiles =
      ghcBaseLinkArgs
        { ghcOptStaticLib = toFlag True
        , ghcOptInputFiles = toNubListR $ map coerceSymbolicPath staticObjectFiles
        , ghcOptOutputFile = toFlag staticLibFilePath
        , ghcOptLinkLibs = extraLibs libBi
        , -- TODO: Shouldn't this use cleanedExtraLibDirsStatic instead?
          ghcOptLinkLibPath = toNubListR cleanedExtraLibDirs
        }
    ghcBytecodeLinkArgs objectFiles =
      (ghcSharedLinkArgs objectFiles)
        { ghcOptBytecodeLib = toFlag True
        , ghcOptInputFiles = toNubListR $ map coerceSymbolicPath objectFiles
        , ghcOptOutputFile = toFlag bytecodeLibFilePath
        }

  staticObjectFiles <- getObjWayFiles StaticWay
  profObjectFiles <- getObjWayFiles ProfWay
  dynamicObjectFiles <- getObjWayFiles DynWay
  profDynamicObjectFiles <- getObjWayFiles ProfDynWay

  -- See doc/internal/bytecode-libraries.md for how the chosen companion
  -- way determines which .gbc files get packed into the .bytecodelib.
  -- See Note [Link manifest cache] at the bottom of this module.
  let
    tcid = mkLinkToolchainId lbi
    linkCtx tool =
      LinkContext{lcTool = tool, lcToolchainId = tcid, lcSkipReason = Nothing}
    linkWay = \case
      ProfWay -> do
        withSkippableLink verbosity (linkCtx "ar-prof") (i profileLibFilePath) (map i profObjectFiles) $
          Ar.createArLibArchive verbosity lbi profileLibFilePath profObjectFiles
        when (withGHCiLib lbi) $ do
          (ldProg, _) <- requireProgram verbosity ldProgram (withPrograms lbi)
          withSkippableLink verbosity (linkCtx "ld-ghci-prof") (i ghciProfLibFilePath) (map i profObjectFiles) $
            Ld.combineObjectFiles
              verbosity
              lbi
              ldProg
              ghciProfLibFilePath
              profObjectFiles
      ProfDynWay -> do
        withSkippableLink verbosity (linkCtx "ghc-shared-prof") (i profSharedLibFilePath) (map i profDynamicObjectFiles) $
          runGhcProg $
            ghcProfSharedLinkArgs profDynamicObjectFiles
      DynWay -> do
        withSkippableLink verbosity (linkCtx "ghc-shared") (i sharedLibFilePath) (map i dynamicObjectFiles) $
          runGhcProg $
            ghcSharedLinkArgs dynamicObjectFiles
        -- The .gbc files were built with DynWay if both are enabled.
        when (withBytecodeLib lbi) $ do
          bytecodeObjectFiles <- getObjBytecodeWayFiles DynWay
          withSkippableLink verbosity (linkCtx "ghc-bytecode-dyn") (i bytecodeLibFilePath) (map i bytecodeObjectFiles) $
            runGhcProg $
              ghcBytecodeLinkArgs bytecodeObjectFiles
      StaticWay -> do
        when (withVanillaLib lbi) $ do
          withSkippableLink verbosity (linkCtx "ar-static") (i vanillaLibFilePath) (map i staticObjectFiles) $
            Ar.createArLibArchive verbosity lbi vanillaLibFilePath staticObjectFiles
          when (withGHCiLib lbi) $ do
            (ldProg, _) <- requireProgram verbosity ldProgram (withPrograms lbi)
            withSkippableLink verbosity (linkCtx "ld-ghci") (i ghciLibFilePath) (map i staticObjectFiles) $
              Ld.combineObjectFiles
                verbosity
                lbi
                ldProg
                ghciLibFilePath
                staticObjectFiles
        when (withStaticLib lbi) $ do
          withSkippableLink verbosity (linkCtx "ghc-staticlib") (i staticLibFilePath) (map i staticObjectFiles) $
            runGhcProg $
              ghcStaticLinkArgs staticObjectFiles
        -- The .gbc files were built with `DynWay` if `DynWay` is enabled. Otherwise (this case),
        -- the files are produced alongside `StaticWay`.
        when (withBytecodeLib lbi && (DynWay `notElem` wantedWays)) $ do
          bytecodeObjectFiles <- getObjBytecodeWayFiles StaticWay
          withSkippableLink verbosity (linkCtx "ghc-bytecode-static") (i bytecodeLibFilePath) (map i bytecodeObjectFiles) $
            runGhcProg $
              ghcBytecodeLinkArgs bytecodeObjectFiles

  -- ROMES: Why exactly branch on staticObjectFiles, rather than any other build
  -- kind that we might have wanted instead?
  -- This would be simpler by not adding every object to the invocation, and
  -- rather using module names.
  unless (null staticObjectFiles) $ do
    info verbosity $
      show $
        ghcOptPackages $
          Internal.componentGhcOptions
            (verbosityLevel verbosity)
            lbi
            libBi
            clbi
            buildTargetDir
    traverse_ linkWay wantedWays

-- | Link the executable resulting from building this component, be it an
-- executable, test, or benchmark component.
linkExecutable
  :: Verbosity
  -- ^ Verbosity used by the link-output cache for HIT/MISS log lines.
  -> (GhcOptions)
  -- ^ The linker-specific GHC options
  -> (BuildWay, BuildWay -> GhcOptions)
  -- ^ The wanted build ways and corresponding GhcOptions that were
  -- used to compile the modules in that way.
  -> SymbolicPath Pkg (Dir Build)
  -- ^ The target dir (2024-01:note: not the same as build target
  -- dir, see Note [Build Target Dir vs Target Dir] in Distribution.Simple.GHC.Build)
  -> UnqualComponentName
  -- ^ Name of executable-like target
  -> (GhcOptions -> IO ())
  -- ^ Run the configured GHC program
  -> LocalBuildInfo
  -> ComponentLocalBuildInfo
  -- ^ The component being linked, so the dep-archive walk can pull
  -- the planner-authoritative dep list from 'componentIncludes'
  -- rather than the post-'--make'-flattening view exposed via
  -- 'ghcOptPackages'.
  -> IO ()
linkExecutable verbosity linkerOpts (way, buildOpts) targetDir targetName runGhcProg lbi clbi = do
  let baseOpts = buildOpts way
      i = interpretSymbolicPathLBI lbi
      -- Decide -no-hs-main from the *compile-pass* inputs, before we
      -- replace ghcOptInputFiles with the explicit object list below.
      noHsMainFlag = toFlag (ghcOptInputFiles baseOpts == mempty && ghcOptInputScripts baseOpts == mempty)
      target = targetDir </> makeRelativePathEx (exeTargetName (hostPlatform lbi) targetName)

  -- The compile pass (buildHaskellModules) wrote the .o files into the
  -- exe's per-component build dir, which is recorded in baseOpts as
  -- ghcOptObjDir. Enumerate them here as a directory walk: that picks
  -- up FFI stub objects (e.g. *_stub.o) without us having to mirror
  -- GHC's path-resolution rules, and the cache key gains nothing from
  -- distinguishing "objects we predicted" from "objects we found".
  -- The sort is for cache-key determinism and to give the linker a
  -- stable command line.
  enumeratedObjs <- case ghcOptObjDir baseOpts of
    Flag objDir -> do
      let objExt = buildWayObjectExtension objExtension way
      enumerateObjectFiles (i objDir) objExt
    NoFlag -> return []

  -- Build the link command: explicit objects only, no --make, full
  -- ghcOptPackages already populated by componentGhcOptions (which
  -- threads componentIncludes clbi through). The record update over
  -- the mappended options is the simplest way to force ghcOptMode
  -- and the module/file input lists to empty (the Flag/NubListR
  -- Semigroup instances are biased towards keeping non-empty
  -- earlier-arg values, so we can't just merge in an mempty).
  let linkOpts =
        ( baseOpts
            `mappend` linkerOpts
            `mappend` mempty{ghcOptLinkNoHsMain = noHsMainFlag}
        )
          { ghcOptMode = NoFlag
          , ghcOptInputFiles = toNubListR (map makeSymbolicPath enumeratedObjs)
          , ghcOptInputModules = mempty
          , ghcOptInputScripts = mempty
          }
      linkSrcs = enumeratedObjs

  -- See Note [Link manifest cache] for why exe link needs the dep
  -- archives included in the cache key alongside the object inputs.
  -- With explicit objects + componentIncludes-derived dep list, the
  -- key is well-formed for every exe link; the only remaining SKIP
  -- branch is the conservative "we expected to find an archive on
  -- disk and couldn't" case in linkDepArchives.
  mDepArchives <- linkDepArchives lbi clbi linkOpts
  let baseCtx =
        LinkContext
          { lcTool = "ghc-link-exe"
          , lcToolchainId = mkLinkToolchainId lbi
          , lcSkipReason = Nothing
          }
      (depArchives, ctx) = case mDepArchives of
        Nothing ->
          ( []
          , skipReason "dep-archive walk incomplete; cache key not trusted" baseCtx
          )
        Just paths -> (paths, baseCtx)
  withSkippableLink verbosity ctx (i target) (linkSrcs ++ depArchives) $
    runGhcProg linkOpts{ghcOptOutputFile = toFlag target}

-- | Recursively enumerate files with the given extension under a
-- directory; returns the absolute paths sorted lexicographically. Used
-- to discover the object files the compile pass produced for an exe
-- so the link pass can pass them explicitly to GHC. Returns @[]@ if
-- the directory doesn't exist (cold first build, or an exe with no
-- Haskell modules at all).
enumerateObjectFiles :: FilePath -> String -> IO [FilePath]
enumerateObjectFiles root ext = do
  exists <- doesDirectoryExist root
  if not exists
    then return []
    else fmap sort (walk root)
  where
    dotExt = '.' : ext
    walk dir = do
      names <- listDirectory dir
      fmap concat $ for names $ \n -> do
        let p = dir FP.</> n
        isDir <- doesDirectoryExist p
        if isDir
          then walk p
          else
            if dotExt `isSuffixOf` n
              then return [p]
              else return []

-- | Walk up parent directories until we find one whose basename
-- starts with @ghc-@ or @ghcjs-@; that's the per-toolchain root in
-- a cabal-install @dist-newstyle@ layout. Falls back to the
-- two-hops-up answer if we hit the filesystem root without
-- matching — preserves prior behaviour for layouts that don't
-- follow the convention (e.g. @Setup build@ in a flat
-- @dist/build/@).
findToolchainRoot :: FilePath -> FilePath
findToolchainRoot start = go start
  where
    fallback = FP.takeDirectory (FP.takeDirectory start)
    go p =
      let parent = FP.takeDirectory p
          name = FP.takeFileName parent
       in if parent == p
            then fallback
            else
              if "ghc-" `isPrefixOf` name || "ghcjs-" `isPrefixOf` name
                then parent
                else go parent

-- | Link a foreign library component
linkFLib
  :: Verbosity
  -- ^ Verbosity used by the link-output cache for HIT/MISS log lines.
  -> ForeignLib
  -> BuildInfo
  -> LocalBuildInfo
  -> (GhcOptions)
  -- ^ The linker-specific GHC options
  -> (BuildWay, BuildWay -> GhcOptions)
  -- ^ The wanted build ways and corresponding GhcOptions that were
  -- used to compile the modules in that way.
  -> SymbolicPath Pkg (Dir Build)
  -- ^ The target dir (2024-01:note: not the same as build target
  -- dir, see Note [Build Target Dir vs Target Dir] in Distribution.Simple.GHC.Build)
  -> (GhcOptions -> IO ())
  -- ^ Run the configured GHC program
  -> IO ()
linkFLib verbosity flib bi lbi linkerOpts (way, buildOpts) targetDir runGhcProg = do
  let
    comp = compiler lbi

    -- Instruct GHC to link against libHSrts.
    rtsLinkOpts :: GhcOptions
    rtsLinkOpts
      | supportsFLinkRts =
          mempty
            { ghcOptLinkRts = toFlag True
            }
      | otherwise =
          mempty
            { ghcOptLinkLibs = rtsOptLinkLibs
            , ghcOptLinkLibPath = toNubListR $ map makeSymbolicPath $ rtsLibPaths rtsInfo
            }
      where
        threaded = hasThreaded bi
        supportsFLinkRts = compilerVersion comp >= mkVersion [9, 0]
        rtsInfo = extractRtsInfo lbi
        rtsOptLinkLibs =
          [ if withDynFLib flib
              then
                if threaded
                  then dynRtsThreadedLib (rtsDynamicInfo rtsInfo)
                  else dynRtsVanillaLib (rtsDynamicInfo rtsInfo)
              else
                if threaded
                  then statRtsThreadedLib (rtsStaticInfo rtsInfo)
                  else statRtsVanillaLib (rtsStaticInfo rtsInfo)
          ]

    linkOpts :: GhcOptions
    linkOpts = case foreignLibType flib of
      ForeignLibNativeShared ->
        (buildOpts way)
          `mappend` linkerOpts
          `mappend` rtsLinkOpts
          `mappend` mempty
            { ghcOptLinkNoHsMain = toFlag True
            , ghcOptShared = toFlag True
            , ghcOptFPic = toFlag True
            , ghcOptLinkModDefFiles = toNubListR $ fmap getSymbolicPath $ foreignLibModDefFile flib
            }
      ForeignLibNativeStatic ->
        -- this should be caught by buildFLib
        -- (and if we do implement this, we probably don't even want to call
        -- ghc here, but rather Ar.createArLibArchive or something)
        cabalBug "static libraries not yet implemented"
      ForeignLibTypeUnknown ->
        cabalBug "unknown foreign lib type"
  -- We build under a (potentially) different filename to set a
  -- soname on supported platforms.  See also the note for
  -- @flibBuildName@.
  let buildName = flibBuildName lbi flib
  let outFile = targetDir </> makeRelativePathEx buildName
  let i = interpretSymbolicPathLBI lbi
      flibInputs = map i (fromNubListR (ghcOptInputFiles linkOpts))
      ctx =
        LinkContext
          { lcTool = "ghc-link-flib"
          , lcToolchainId = mkLinkToolchainId lbi
          , lcSkipReason = Nothing
          }
  withSkippableLink verbosity ctx (i outFile) flibInputs $
    runGhcProg linkOpts{ghcOptOutputFile = toFlag outFile}
  renameFile (i outFile) (i targetDir </> flibTargetName lbi flib)

-- | Calculate the RPATHs for the component we are building.
--
-- Calculates relative RPATHs when 'relocatable' is set.
getRPaths
  :: PreBuildComponentInputs
  -- ^ The context and component being built in it.
  -> IO (NubListR FilePath)
getRPaths pbci = do
  let
    lbi = localBuildInfo pbci
    bi = buildBI pbci
    clbi = buildCLBI pbci

    (Platform _ hostOS) = hostPlatform lbi
    compid = compilerId . compiler $ lbi

    -- The list of RPath-supported operating systems below reflects the
    -- platforms on which Cabal's RPATH handling is tested. It does _NOT_
    -- reflect whether the OS supports RPATH.

    -- E.g. when this comment was written, the *BSD operating systems were
    -- untested with regards to Cabal RPATH handling, and were hence set to
    -- 'False', while those operating systems themselves do support RPATH.
    supportRPaths Linux = True
    supportRPaths Windows = False
    supportRPaths OSX = True
    supportRPaths FreeBSD =
      case compid of
        CompilerId GHC _ -> True
        _ -> False
    supportRPaths OpenBSD = False
    supportRPaths NetBSD = False
    supportRPaths DragonFly = False
    supportRPaths Solaris = False
    supportRPaths AIX = False
    supportRPaths HPUX = False
    supportRPaths IRIX = False
    supportRPaths HaLVM = False
    supportRPaths IOS = False
    supportRPaths Android = False
    supportRPaths Ghcjs = False
    supportRPaths Wasi = False
    supportRPaths Hurd = True
    supportRPaths Haiku = False
    supportRPaths (OtherOS _) = False
  -- Do _not_ add a default case so that we get a warning here when a new OS
  -- is added.

  if supportRPaths hostOS
    then do
      libraryPaths <- liftIO $ depLibraryPaths False (relocatable lbi) lbi clbi
      let hostPref = case hostOS of
            OSX -> "@loader_path"
            _ -> "$ORIGIN"
          relPath p = if isRelative p then hostPref </> p else p
          rpaths =
            toNubListR (map relPath libraryPaths)
              <> toNubListR (map getSymbolicPath $ extraLibDirs bi)
      return rpaths
    else return mempty

data DynamicRtsInfo = DynamicRtsInfo
  { dynRtsVanillaLib :: FilePath
  , dynRtsThreadedLib :: FilePath
  , dynRtsDebugLib :: FilePath
  , dynRtsEventlogLib :: FilePath
  , dynRtsThreadedDebugLib :: FilePath
  , dynRtsThreadedEventlogLib :: FilePath
  }

data StaticRtsInfo = StaticRtsInfo
  { statRtsVanillaLib :: FilePath
  , statRtsThreadedLib :: FilePath
  , statRtsDebugLib :: FilePath
  , statRtsEventlogLib :: FilePath
  , statRtsThreadedDebugLib :: FilePath
  , statRtsThreadedEventlogLib :: FilePath
  , statRtsProfilingLib :: FilePath
  , statRtsThreadedProfilingLib :: FilePath
  }

data RtsInfo = RtsInfo
  { rtsDynamicInfo :: DynamicRtsInfo
  , rtsStaticInfo :: StaticRtsInfo
  , rtsLibPaths :: [FilePath]
  }

-- | Extract (and compute) information about the RTS library
--
-- TODO: This hardcodes the name as @HSrts-ghc<version>@. I don't know if we can
-- find this information somewhere. We can lookup the 'hsLibraries' field of
-- 'InstalledPackageInfo' but it will tell us @["HSrts", "Cffi"]@, which
-- doesn't really help.
extractRtsInfo :: LocalBuildInfo -> RtsInfo
extractRtsInfo lbi =
  case PackageIndex.lookupPackageName
    (installedPkgs lbi)
    (mkPackageName "rts") of
    [(_, [rts])] -> aux rts
    _otherwise -> error "No (or multiple) ghc rts package is registered"
  where
    aux :: InstalledPackageInfo -> RtsInfo
    aux rts =
      RtsInfo
        { rtsDynamicInfo =
            DynamicRtsInfo
              { dynRtsVanillaLib = withGhcVersion "HSrts"
              , dynRtsThreadedLib = withGhcVersion "HSrts_thr"
              , dynRtsDebugLib = withGhcVersion "HSrts_debug"
              , dynRtsEventlogLib = withGhcVersion "HSrts_l"
              , dynRtsThreadedDebugLib = withGhcVersion "HSrts_thr_debug"
              , dynRtsThreadedEventlogLib = withGhcVersion "HSrts_thr_l"
              }
        , rtsStaticInfo =
            StaticRtsInfo
              { statRtsVanillaLib = "HSrts"
              , statRtsThreadedLib = "HSrts_thr"
              , statRtsDebugLib = "HSrts_debug"
              , statRtsEventlogLib = "HSrts_l"
              , statRtsThreadedDebugLib = "HSrts_thr_debug"
              , statRtsThreadedEventlogLib = "HSrts_thr_l"
              , statRtsProfilingLib = "HSrts_p"
              , statRtsThreadedProfilingLib = "HSrts_thr_p"
              }
        , rtsLibPaths = InstalledPackageInfo.libraryDirs rts
        }
    withGhcVersion = (++ ("-ghc" ++ prettyShow (compilerVersion (compiler lbi))))

-- | Determine whether the given 'BuildInfo' is intended to link against the
-- threaded RTS. This is used to determine which RTS to link against when
-- building a foreign library with a GHC without support for @-flink-rts@.
hasThreaded :: BuildInfo -> Bool
hasThreaded bi = "-threaded" `elem` ghc
  where
    PerCompilerFlavor ghc _ = options bi

-- | Load a target component into a repl, or write to disk a script which runs
-- GHCi with the GHC options Cabal elaborated to load the component interactively.
runReplOrWriteFlags
  :: ConfiguredProgram
  -> VerbosityHandles
  -> LocalBuildInfo
  -> ReplFlags
  -> GhcOptions
  -> PackageName
  -> TargetInfo
  -> IO ()
runReplOrWriteFlags ghcProg verbHandles lbi rflags ghcOpts pkg_name target =
  let bi = componentBuildInfo $ targetComponent target
      clbi = targetCLBI target
      cname = componentName (targetComponent target)
      comp = compiler lbi
      platform = hostPlatform lbi
      common = configCommonFlags $ configFlags lbi
      mbWorkDir = mbWorkDirLBI lbi
      verbosity = mkVerbosity verbHandles (fromFlag $ setupVerbosity common)
      tempFileOptions = commonSetupTempFileOptions common
   in case replOptionsFlagOutput (replReplOptions rflags) of
        NoFlag -> do
          -- If a specific GHC implementation is specified, use it
          runReplProgram
            (flagToMaybe $ replWithRepl (replReplOptions rflags))
            tempFileOptions
            verbosity
            ghcProg
            comp
            platform
            mbWorkDir
            ghcOpts
        Flag out_dir -> do
          let uid = componentUnitId clbi
              this_unit = prettyShow uid
              getOpenModName (OpenModule _ mn) = Just mn
              getOpenModName (OpenModuleVar{}) = Nothing
              reexported_modules =
                [ (from_mn, to_mn) | LibComponentLocalBuildInfo{componentExposedModules = exposed_mods} <- [clbi], IPI.ExposedModule to_mn (Just m) <- exposed_mods, Just from_mn <- [getOpenModName m]
                ]
              renderReexportedModule (from_mn, to_mn)
                | reexportedAsSupported comp =
                    pure $ prettyShow from_mn ++ " as " ++ prettyShow to_mn
                | otherwise =
                    if from_mn == to_mn
                      then pure $ prettyShow to_mn
                      else dieWithException verbosity (MultiReplDoesNotSupportComplexReexportedModules pkg_name cname)
              hidden_modules = otherModules bi
              render_extra_opts = do
                rexp_mods <- mapM renderReexportedModule reexported_modules
                pure $
                  concat $
                    [ ["-this-package-name", prettyShow pkg_name]
                    , case mbWorkDir of
                        Nothing -> []
                        Just wd -> ["-working-dir", getSymbolicPath wd]
                    ]
                      ++ [ ["-reexported-module", m] | m <- rexp_mods
                         ]
                      ++ [ ["-hidden-module", prettyShow m] | m <- hidden_modules
                         ]
          -- Create "paths" subdirectory if it doesn't exist. This is where we write
          -- information about how the PATH was augmented.
          createDirectoryIfMissing False (out_dir </> "paths")
          -- Write out the PATH information into `paths` subdirectory.
          writeFileAtomic (out_dir </> "paths" </> this_unit) (encode ghcProg)
          -- Write out options for this component into a file ready for loading into
          -- the multi-repl
          extra_opts <- render_extra_opts
          writeFileAtomic (out_dir </> this_unit) $
            BS.pack $
              escapeArgs $
                extra_opts
                  ++ renderGhcOptions comp platform (ghcOpts{ghcOptMode = NoFlag})
                  ++ programOverrideArgs ghcProg

replNoLoad :: Ord a => ReplOptions -> NubListR a -> NubListR a
replNoLoad replFlags l
  | replOptionsNoLoad replFlags == Flag True = mempty
  | otherwise = l

{- Note [Link manifest cache]

The link calls in this module ('Ar.createArLibArchive',
'Ld.combineObjectFiles', and the various 'runGhcProg' invocations
producing '.so'/'.a' archives, bytecode libs, foreign libs, and
executables) are wrapped in 'withSkippableLink' from
"Distribution.Simple.GHC.LinkManifest". The wrapper hashes the byte
content of the link inputs together with a tool identifier and the
target's basename; on a hit, the prior output is byte-copied from
@$XDG_CACHE_HOME/cabal/link-cache/@ and the linker is skipped
entirely.

Why each tool is safe:

\* 'ar' is forced byte-stable by 'Distribution.Simple.Program.Ar.wipeMetadata',
  which scrubs timestamps and uids from archive members.
\* 'ghc -shared' / 'ghc -staticlib' / 'ghc -bytecodelib' are deterministic
  on a given toolchain when the input object files are byte-equal.
\* 'ghc -o' for executables emits an RPATH derived from the output path
  and a '--build-id' hash of inputs. Both are stable when the inputs
  are stable. For executables we additionally include the dep package
  '.a'/'.so' files (resolved by 'linkDepArchives') so that a
  same-package lib edit busts the exe's cache key even though
  'Main.hs' itself is unchanged.

The cache key is @(tool identifier, target basename, toolchain id,
sorted input digests)@. The target's directory is intentionally
absent: two checkouts of the same project share cached outputs.
RPATHs in cabal are written as @\$ORIGIN@/@\@loader_path@-relative
paths (see 'getRPaths'), so the link output is byte-identical
between such checkouts.

The /toolchain id/ is a short string built from the compiler id and
the resolved absolute paths of @ghc@, @ld@, and @ar@. Including it
in the key means an @ld@ upgrade, a switch to a different ghc, or a
swap of @ar@ binary busts every cached entry rather than yielding a
silent stale hit.

For the executable link the cache key also includes the dep-package
archives ghc will pull in via @-package-id@. 'linkDepArchives' is
fail-closed: if any 'DefiniteUnitId' that should have a library
archive on disk can't be matched in our search, the function
returns @Nothing@ and the caller passes a 'skipReason' to
'withSkippableLink' so the cache is bypassed for that link. Better
to miss a cache opportunity than to issue a stale hit driven by a
quietly-incomplete input set.

Env vars (see 'Distribution.Simple.GHC.LinkManifest' for the
authoritative list):

\* @CABAL_LINK_CACHE_DISABLE=1@ — bypass entirely (no read, no write).
\* @CABAL_LINK_CACHE_DIR=\/path@ — override the cache root.
\* @CABAL_LINK_CACHE_MAX_BYTES=N@ — size cap (default 5 GiB). On a
  miss-with-write the oldest blobs are evicted until under cap.
\* @CABAL_LINK_CACHE_NO_STAT=1@ — disable the @(size, mtime, inode)@-based
  short-circuit; force a full xxh3 read of every input on every link.
\* @CABAL_LINK_CACHE_NO_STATS=1@ — don't append hit\/miss telemetry to
  @.stats.jsonl@ under the cache root.
\* @CABAL_LINK_CACHE_VERIFY=1@ — canary mode: on a hit, re-run the
  linker and bytewise-compare its output against the cached blob.
  Mismatches are reported and dumped under @divergences\/\<key\>\/@
  for offline inspection. Trades the cache speedup for a determinism
  check; never the default.
\* @CABAL_LINK_CACHE_VERIFY_FAIL=1@ — combined with the above,
  escalates a verification mismatch to a hard build error rather
  than a log message.
-}

-- | A short string capturing the link-toolchain identity. Included
-- verbatim in the link cache key so that an ld upgrade, a ghc switch,
-- or a different ar binary busts every cached link without us having
-- to enumerate the consequences. Cheap to compute (one lookup per
-- tool); intentionally embeds absolute paths because under nix/ghcup
-- the path encodes content.
mkLinkToolchainId :: LocalBuildInfo -> String
mkLinkToolchainId lbi =
  let comp = compiler lbi
      progDb = withPrograms lbi
      pathOf p = maybe "?" programPath (lookupProgram p progDb)
   in prettyShow (compilerId comp)
        <> "|ghc="
        <> pathOf ghcProgram
        <> "|ld="
        <> pathOf ldProgram
        <> "|ar="
        <> pathOf arProgram

-- | Resolve the on-disk paths of dep-package archives ghc will pull in
-- via @-package-id@, for use as link-cache key inputs for the
-- executable link step. Three search strategies, results deduped:
--
--   1. Look up registered installed-package index ('installedPkgs'
--      lbi) — catches globally registered deps.
--   2. Glob the @-L@ search paths in 'ghcOptLinkLibPath' for files
--      named @libHS*<unit-id>*.{a,so,dylib}@.
--   3. Recursively walk the per-toolchain build dir derived from
--      @buildDir lbi@ looking for the same filename pattern. Catches
--      in-tree library components that have just been built but
--      won't appear in the installed-package index until after the
--      exe is linked.
--
-- The starting set of unit IDs is the union of 'ghcOptPackages' (the
-- post-@--make@-flattening view) and 'componentIncludes' of the
-- caller's 'ComponentLocalBuildInfo' (the planner-authoritative view).
-- The latter is essential for executable links: cabal's exe build
-- path historically passed source files to GHC in @--make@ mode and
-- relied on GHC to walk imports for the dep list, so only the
-- immediate @build-depends:@ of the exe stanza appeared in
-- 'ghcOptPackages'. With the link step now driven by an explicit
-- object list (and no @--make@), the dep list must come from
-- somewhere; 'componentIncludes' has it.
--
-- Returns @Nothing@ if any 'DefiniteUnitId' that we expect to have a
-- library archive (non-empty 'hsLibraries' in the installed-package
-- index, or unknown to the index) didn't match anything we found.
-- Callers should treat that as "we cannot trust the cache key" and
-- skip the cache for this link — better than a possibly-stale HIT
-- driven by a quietly-incomplete input set.
--
-- See @Note [Link manifest cache]@.
linkDepArchives :: LocalBuildInfo -> ComponentLocalBuildInfo -> GhcOptions -> IO (Maybe [FilePath])
linkDepArchives lbi clbi linkOpts = do
  let i = interpretSymbolicPathLBI lbi
      pkgIdx = installedPkgs lbi
      uids =
        ordNub $
          [uid | (uid, _) <- fromNubListR (ghcOptPackages linkOpts)]
            ++ [uid | (uid, _) <- componentIncludes clbi]
      libSearchDirs = map i (fromNubListR (ghcOptLinkLibPath linkOpts))
      ghcVerSuffix = "-ghc" ++ prettyShow (compilerVersion (compiler lbi))
      libExts = [".a", ghcVerSuffix ++ ".so", ghcVerSuffix ++ ".dylib", ".so", ".dylib"]
      uidStrings = [prettyShow (unDefUnitId d) | DefiniteUnitId d <- uids]
      -- GHC's @hs-libraries@ field already carries the @HS@ prefix
      -- (e.g. @HSbase-4.19.2.0-dcbb@) — concatenate with @lib@ only,
      -- not @libHS@. Search @libraryDirs@ + @libraryDirsStatic@ for
      -- @.a@/profiling archives and @libraryDynDirs@ (typically the
      -- per-toolchain lib root) for @.so@/@.dylib@; the same package
      -- may have its static and dynamic libs in different directories
      -- (this is the standard nixpkgs/distro GHC layout).
      ipiPaths =
        [ d FP.</> ("lib" ++ hsLib ++ ext)
        | DefiniteUnitId duid <- uids
        , Just ipi <- [PackageIndex.lookupUnitId pkgIdx (unDefUnitId duid)]
        , d <-
            ordNub
              ( IPI.libraryDirs ipi
                  ++ IPI.libraryDirsStatic ipi
                  ++ IPI.libraryDynDirs ipi
              )
        , hsLib <- IPI.hsLibraries ipi
        , ext <- libExts
        ]
      -- Anchor the in-tree walk to the per-toolchain root, which
      -- contains every sibling package's archive directory. For a lib
      -- component the per-toolchain root is two takeDirectory hops up
      -- from @buildDir lbi@; for an exe / test / bench / flib it can
      -- be three or more (those layers are inserted as @x/<name>@,
      -- @t/<name>@, etc.). Walk up parents until we hit a directory
      -- whose basename starts with @ghc-@/@ghcjs-@; bail at the
      -- filesystem root with a conservative fallback to two hops so
      -- the existing lib behaviour is preserved on layouts that
      -- don't follow this convention.
      buildDirAbs = i (buildDir lbi)
      searchRoot = findToolchainRoot buildDirAbs
      -- Definite units we expect to have a library archive on disk:
      -- either we have a matching IPI entry with non-empty hsLibraries,
      -- or the unit isn't in the IPI at all and we rely on the search
      -- to find an in-tree match (conservatively, we still expect at
      -- least one archive — header-only deps don't pass -package-id).
      expectedArchiveUidStrings =
        [ prettyShow (unDefUnitId duid)
        | DefiniteUnitId duid <- uids
        , let mIpi = PackageIndex.lookupUnitId pkgIdx (unDefUnitId duid)
        , maybe True (not . null . IPI.hsLibraries) mIpi
        ]
  searchedFromLibs <- concat <$> traverse (listMatching uidStrings libExts) libSearchDirs
  searchedFromBuild <- walkMatching uidStrings libExts searchRoot
  let foundCandidates = ordNub (ipiPaths ++ searchedFromLibs ++ searchedFromBuild)
  found <- filterM doesFileExist foundCandidates
  let foundNames = map FP.takeFileName found
      matched s = any (s `isInfixOf`) foundNames
      allExpectedFound = all matched expectedArchiveUidStrings
  return $ if allExpectedFound then Just found else Nothing
  where
    isHSLib uidStrings libExts n =
      "libHS" `isPrefixOf` n
        && any (`isInfixOf` n) uidStrings
        && any (`isSuffixOf` n) libExts

    listMatching uidStrings libExts dir = do
      exists <- doesDirectoryExist dir
      if not exists
        then return []
        else do
          names <- listDirectory dir
          return [dir FP.</> n | n <- names, isHSLib uidStrings libExts n]

    -- Depth-capped walk that skips hidden dirs and known-noise
    -- siblings (autogen, paths, doc, src tarballs). Without the cap
    -- this would descend into anything under
    -- @dist-newstyle/build/<plat>/<ghc>/<pkg>-V/@, which on a big
    -- monorepo can be thousands of files per exe link. Cabal's
    -- per-package layout doesn't exceed seven levels, so a cap of
    -- eight comfortably covers any in-tree component archive.
    walkMatching uidStrings libExts root = go (0 :: Int) root
      where
        maxDepth = 8
        skipDir n = case n of
          "" -> True
          ('.' : _) -> True
          "autogen" -> True
          "doc" -> True
          "src" -> True
          "tmp" -> True
          _ -> False
        go depth dir
          | depth > maxDepth = return []
          | otherwise = do
              exists <- doesDirectoryExist dir
              if not exists
                then return []
                else do
                  names <- listDirectory dir
                  fmap concat $ for names $ \n -> do
                    let p = dir FP.</> n
                    isDir <- doesDirectoryExist p
                    if isDir
                      then
                        if skipDir n
                          then return []
                          else go (depth + 1) p
                      else
                        if isHSLib uidStrings libExts n
                          then return [p]
                          else return []
