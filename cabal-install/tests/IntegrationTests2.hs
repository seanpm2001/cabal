{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

-- For the handy instance IsString PackageIdentifier
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Distribution.Client.DistDirLayout
import Distribution.Client.ProjectConfig
import Distribution.Client.Config (getCabalDir)
import Distribution.Client.TargetSelector hiding (DirActions(..))
import qualified Distribution.Client.TargetSelector as TS (DirActions(..))
import Distribution.Client.ProjectPlanning
import Distribution.Client.ProjectPlanning.Types
import Distribution.Client.ProjectBuilding
import Distribution.Client.ProjectOrchestration
         ( resolveTargets, distinctTargetComponents )
import Distribution.Client.TargetProblem
         ( TargetProblem', TargetProblem (..) )
import Distribution.Client.Types
         ( PackageLocation(..), UnresolvedSourcePackage
         , PackageSpecifier(..) )
import Distribution.Client.Targets
         ( UserConstraint(..), UserConstraintScope(UserAnyQualifier) )
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Solver.Types.SourcePackage as SP
import Distribution.Solver.Types.ConstraintSource
         ( ConstraintSource(ConstraintSourceUnknown) )
import Distribution.Solver.Types.PackageConstraint
         ( PackageProperty(PackagePropertySource) )

import qualified Distribution.Client.CmdBuild   as CmdBuild
import qualified Distribution.Client.CmdRepl    as CmdRepl
import qualified Distribution.Client.CmdRun     as CmdRun
import qualified Distribution.Client.CmdTest    as CmdTest
import qualified Distribution.Client.CmdBench   as CmdBench
import qualified Distribution.Client.CmdHaddock as CmdHaddock
import qualified Distribution.Client.CmdListBin as CmdListBin

import Distribution.Package
import Distribution.PackageDescription
import Distribution.InstalledPackageInfo (InstalledPackageInfo)
import Distribution.Simple.Setup (toFlag, HaddockFlags(..), defaultHaddockFlags)
import Distribution.Simple.Compiler
import Distribution.System
import Distribution.Version
import Distribution.ModuleName (ModuleName)
import Distribution.Text
import Distribution.Utils.Path

import qualified Data.Map as Map
import qualified Data.Set as Set
import Control.Monad
import Control.Concurrent (threadDelay)
import Control.Exception hiding (assert)
import System.FilePath
import System.Directory
import System.IO (hPutStrLn, stderr)

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Options
import Data.Tagged (Tagged(..))

import qualified Data.ByteString as BS

#if !MIN_VERSION_directory(1,2,7)
removePathForcibly :: FilePath -> IO ()
removePathForcibly = removeDirectoryRecursive
#endif

main :: IO ()
main =
  defaultMainWithIngredients
    (defaultIngredients ++ [includingOptions projectConfigOptionDescriptions])
    (withProjectConfig $ \config ->
      testGroup "Integration tests (internal)"
                (tests config))


tests :: ProjectConfig -> [TestTree]
tests config =
    --TODO: tests for:
    -- * normal success
    -- * dry-run tests with changes
  [ testGroup "Discovery and planning" $
    [ testCase "find root"      testFindProjectRoot
    , testCase "find root fail" testExceptionFindProjectRoot
    , testCase "no package"    (testExceptionInFindingPackage config)
    , testCase "no package2"   (testExceptionInFindingPackage2 config)
    , testCase "proj conf1"    (testExceptionInProjectConfig config)
    ]
  , testGroup "Target selectors" $
    [ testCaseSteps "valid"              testTargetSelectors
    , testCase      "bad syntax"         testTargetSelectorBadSyntax
    , testCaseSteps "ambiguous syntax"   testTargetSelectorAmbiguous
    , testCase      "no current pkg"     testTargetSelectorNoCurrentPackage
    , testCase      "no targets"         testTargetSelectorNoTargets
    , testCase      "project empty"      testTargetSelectorProjectEmpty
    , testCase      "canonicalized path" testTargetSelectorCanonicalizedPath
    , testCase      "problems (common)"  (testTargetProblemsCommon config)
    , testCaseSteps "problems (build)"   (testTargetProblemsBuild config)
    , testCaseSteps "problems (repl)"    (testTargetProblemsRepl config)
    , testCaseSteps "problems (run)"     (testTargetProblemsRun config)
    , testCaseSteps "problems (list-bin)" (testTargetProblemsListBin config)
    , testCaseSteps "problems (test)"    (testTargetProblemsTest config)
    , testCaseSteps "problems (bench)"   (testTargetProblemsBench config)
    , testCaseSteps "problems (haddock)" (testTargetProblemsHaddock config)
    ]
  , testGroup "Exceptions during building (local inplace)" $
    [ testCase "configure"   (testExceptionInConfigureStep config)
    , testCase "build"       (testExceptionInBuildStep config)
--    , testCase "register"   testExceptionInRegisterStep
    ]
    --TODO: need to repeat for packages for the store
    --TODO: need to check we can build sub-libs, foreign libs and exes
    -- components for non-local packages / packages in the store.

  , testGroup "Successful builds" $
    [ testCaseSteps "Setup script styles" (testSetupScriptStyles config)
    , testCase      "keep-going"          (testBuildKeepGoing config)
#ifndef mingw32_HOST_OS
    -- disabled because https://github.com/haskell/cabal/issues/6272
    , testCase      "local tarball"       (testBuildLocalTarball config)
#endif
    ]

  , testGroup "Regression tests" $
    [ testCase "issue #3324" (testRegressionIssue3324 config)
    ]
  ]


testFindProjectRoot :: Assertion
testFindProjectRoot = do
    Left (BadProjectRootExplicitFile file) <- findProjectRoot (Just testdir)
                                                              (Just testfile)
    file @?= testfile
  where
    testdir  = basedir </> "exception" </> "no-pkg2"
    testfile = "bklNI8O1OpOUuDu3F4Ij4nv3oAqN"


testExceptionFindProjectRoot :: Assertion
testExceptionFindProjectRoot = do
    Right (ProjectRootExplicit dir _) <- findProjectRoot (Just testdir) Nothing
    cwd <- getCurrentDirectory
    dir @?= cwd </> testdir
  where
    testdir = basedir </> "exception" </> "no-pkg2"


testTargetSelectors :: (String -> IO ()) -> Assertion
testTargetSelectors reportSubCase = do
    (_, _, _, localPackages, _) <- configureProject testdir config
    let readTargetSelectors' = readTargetSelectorsWith (dirActions testdir)
                                                       localPackages
                                                       Nothing

    reportSubCase "cwd"
    do Right ts <- readTargetSelectors' []
       ts @?= [TargetPackage TargetImplicitCwd ["p-0.1"] Nothing]

    reportSubCase "all"
    do Right ts <- readTargetSelectors'
                     ["all", ":all"]
       ts @?= replicate 2 (TargetAllPackages Nothing)

    reportSubCase "filter"
    do Right ts <- readTargetSelectors'
                     [ "libs",  ":cwd:libs"
                     , "flibs", ":cwd:flibs"
                     , "exes",  ":cwd:exes"
                     , "tests", ":cwd:tests"
                     , "benchmarks", ":cwd:benchmarks"]
       zipWithM_ (@?=) ts
         [ TargetPackage TargetImplicitCwd ["p-0.1"] (Just kind)
         | kind <- concatMap (replicate 2) [LibKind .. ]
         ]

    reportSubCase "all:filter"
    do Right ts <- readTargetSelectors'
                     [ "all:libs",  ":all:libs"
                     , "all:flibs", ":all:flibs"
                     , "all:exes",  ":all:exes"
                     , "all:tests", ":all:tests"
                     , "all:benchmarks", ":all:benchmarks"]
       zipWithM_ (@?=) ts
         [ TargetAllPackages (Just kind)
         | kind <- concatMap (replicate 2) [LibKind .. ]
         ]

    reportSubCase "pkg"
    do Right ts <- readTargetSelectors'
                     [       ":pkg:p", ".",  "./",   "p.cabal"
                     , "q",  ":pkg:q", "q/", "./q/", "q/q.cabal"]
       ts @?= replicate 4 (mkTargetPackage "p-0.1")
           ++ replicate 5 (mkTargetPackage "q-0.1")

    reportSubCase "pkg:filter"
    do Right ts <- readTargetSelectors'
                     [ "p:libs",  ".:libs",  ":pkg:p:libs"
                     , "p:flibs", ".:flibs", ":pkg:p:flibs"
                     , "p:exes",  ".:exes",  ":pkg:p:exes"
                     , "p:tests", ".:tests",  ":pkg:p:tests"
                     , "p:benchmarks", ".:benchmarks", ":pkg:p:benchmarks"
                     , "q:libs",  "q/:libs", ":pkg:q:libs"
                     , "q:flibs", "q/:flibs", ":pkg:q:flibs"
                     , "q:exes",  "q/:exes", ":pkg:q:exes"
                     , "q:tests", "q/:tests", ":pkg:q:tests"
                     , "q:benchmarks", "q/:benchmarks", ":pkg:q:benchmarks"]
       zipWithM_ (@?=) ts $
         [ TargetPackage TargetExplicitNamed ["p-0.1"] (Just kind)
         | kind <- concatMap (replicate 3) [LibKind .. ]
         ] ++
         [ TargetPackage TargetExplicitNamed ["q-0.1"] (Just kind)
         | kind <- concatMap (replicate 3) [LibKind .. ]
         ]

    reportSubCase "component"
    do Right ts <- readTargetSelectors'
                     [ "p", "lib:p", "p:lib:p", ":pkg:p:lib:p"
                     ,      "lib:q", "q:lib:q", ":pkg:q:lib:q" ]
       ts @?= replicate 4 (TargetComponent "p-0.1" (CLibName LMainLibName) WholeComponent)
           ++ replicate 3 (TargetComponent "q-0.1" (CLibName LMainLibName) WholeComponent)

    reportSubCase "module"
    do Right ts <- readTargetSelectors'
                     [ "P", "lib:p:P", "p:p:P", ":pkg:p:lib:p:module:P"
                     , "QQ", "lib:q:QQ", "q:q:QQ", ":pkg:q:lib:q:module:QQ"
                     , "pexe:PMain" -- p:P or q:QQ would be ambiguous here
                     , "qexe:QMain" -- package p vs component p
                     ]
       ts @?= replicate 4 (TargetComponent "p-0.1" (CLibName LMainLibName) (ModuleTarget "P"))
           ++ replicate 4 (TargetComponent "q-0.1" (CLibName LMainLibName) (ModuleTarget "QQ"))
           ++ [ TargetComponent "p-0.1" (CExeName "pexe") (ModuleTarget "PMain")
              , TargetComponent "q-0.1" (CExeName "qexe") (ModuleTarget "QMain")
              ]

    reportSubCase "file"
    do Right ts <- readTargetSelectors'
                     [ "./P.hs", "p:P.lhs", "lib:p:P.hsc", "p:p:P.hsc",
                                 ":pkg:p:lib:p:file:P.y"
                     , "q/QQ.hs", "q:QQ.lhs", "lib:q:QQ.hsc", "q:q:QQ.hsc",
                                  ":pkg:q:lib:q:file:QQ.y"
                     , "q/Q.hs", "q:Q.lhs", "lib:q:Q.hsc", "q:q:Q.hsc",
                                  ":pkg:q:lib:q:file:Q.y"
                     , "app/Main.hs", "p:app/Main.hs", "exe:ppexe:app/Main.hs", "p:ppexe:app/Main.hs",
                                  ":pkg:p:exe:ppexe:file:app/Main.hs"
                     ]
       ts @?= replicate 5 (TargetComponent "p-0.1" (CLibName LMainLibName) (FileTarget "P"))
           ++ replicate 5 (TargetComponent "q-0.1" (CLibName LMainLibName) (FileTarget "QQ"))
           ++ replicate 5 (TargetComponent "q-0.1" (CLibName LMainLibName) (FileTarget "Q"))
           ++ replicate 5 (TargetComponent "p-0.1" (CExeName "ppexe") (FileTarget ("app" </> "Main.hs")))
       -- Note there's a bit of an inconsistency here: for the single-part
       -- syntax the target has to point to a file that exists, whereas for
       -- all the other forms we don't require that.

    cleanProject testdir
  where
    testdir = "targets/simple"
    config  = mempty


testTargetSelectorBadSyntax :: Assertion
testTargetSelectorBadSyntax = do
    (_, _, _, localPackages, _) <- configureProject testdir config
    let targets = [ "foo bar",  " foo"
                  , "foo:", "foo::bar"
                  , "foo: ", "foo: :bar"
                  , "a:b:c:d:e:f", "a:b:c:d:e:f:g:h" ]
    Left errs <- readTargetSelectors localPackages Nothing targets
    zipWithM_ (@?=) errs (map TargetSelectorUnrecognised targets)
    cleanProject testdir
  where
    testdir = "targets/empty"
    config  = mempty


testTargetSelectorAmbiguous :: (String -> IO ()) -> Assertion
testTargetSelectorAmbiguous reportSubCase = do

    -- 'all' is ambiguous with packages and cwd components
    reportSubCase "ambiguous: all vs pkg"
    assertAmbiguous "all"
      [mkTargetPackage "all", mkTargetAllPackages]
      [mkpkg "all" []]

    reportSubCase "ambiguous: all vs cwd component"
    assertAmbiguous "all"
      [mkTargetComponent "other" (CExeName "all"), mkTargetAllPackages]
      [mkpkg "other" [mkexe "all"]]

    -- but 'all' is not ambiguous with non-cwd components, modules or files
    reportSubCase "unambiguous: all vs non-cwd comp, mod, file"
    assertUnambiguous "All"
      mkTargetAllPackages
      [ mkpkgAt "foo" [mkexe "All"] "foo"
      , mkpkg   "bar" [ mkexe "bar" `withModules` ["All"]
                      , mkexe "baz" `withCFiles` ["All"] ]
      ]

    -- filters 'libs', 'exes' etc are ambiguous with packages and
    -- local components
    reportSubCase "ambiguous: cwd-pkg filter vs pkg"
    assertAmbiguous "libs"
      [ mkTargetPackage "libs"
      , TargetPackage TargetImplicitCwd ["libs"] (Just LibKind) ]
      [mkpkg "libs" []]

    reportSubCase "ambiguous: filter vs cwd component"
    assertAmbiguous "exes"
      [ mkTargetComponent "other" (CExeName "exes")
      , TargetPackage TargetImplicitCwd ["other"] (Just ExeKind) ]
      [mkpkg "other" [mkexe "exes"]]

    -- but filters are not ambiguous with non-cwd components, modules or files
    reportSubCase "unambiguous: filter vs non-cwd comp, mod, file"
    assertUnambiguous "Libs"
      (TargetPackage TargetImplicitCwd ["bar"] (Just LibKind))
      [ mkpkgAt "foo" [mkexe "Libs"] "foo"
      , mkpkg   "bar" [ mkexe "bar" `withModules` ["Libs"]
                      , mkexe "baz" `withCFiles` ["Libs"] ]
      ]

    -- local components shadow packages and other components
    reportSubCase "unambiguous: cwd comp vs pkg, non-cwd comp"
    assertUnambiguous "foo"
      (mkTargetComponent "other" (CExeName "foo"))
      [ mkpkg   "other"  [mkexe "foo"]
      , mkpkgAt "other2" [mkexe "foo"] "other2" -- shadows non-local foo
      , mkpkg "foo" [] ]                        -- shadows package foo

    -- local components shadow modules and files
    reportSubCase "unambiguous: cwd comp vs module, file"
    assertUnambiguous "Foo"
      (mkTargetComponent "bar" (CExeName "Foo"))
      [ mkpkg "bar" [mkexe "Foo"]
      , mkpkg "other" [ mkexe "other"  `withModules` ["Foo"]
                      , mkexe "other2" `withCFiles`  ["Foo"] ]
      ]

    -- packages shadow non-local components
    reportSubCase "unambiguous: pkg vs non-cwd comp"
    assertUnambiguous "foo"
      (mkTargetPackage "foo")
      [ mkpkg "foo" []
      , mkpkgAt "other" [mkexe "foo"] "other" -- shadows non-local foo
      ]

    -- packages shadow modules and files
    reportSubCase "unambiguous: pkg vs module, file"
    assertUnambiguous "Foo"
      (mkTargetPackage "Foo")
      [ mkpkgAt "Foo" [] "foo"
      , mkpkg "other" [ mkexe "other"  `withModules` ["Foo"]
                      , mkexe "other2" `withCFiles`  ["Foo"] ]
      ]

    -- File target is ambiguous, part of multiple components
    reportSubCase "ambiguous: file in multiple comps"
    assertAmbiguous "Bar.hs"
      [ mkTargetFile "foo" (CExeName "bar")  "Bar"
      , mkTargetFile "foo" (CExeName "bar2") "Bar"
      ]
      [ mkpkg "foo" [ mkexe "bar"  `withModules` ["Bar"]
                    , mkexe "bar2" `withModules` ["Bar"] ]
      ]
    reportSubCase "ambiguous: file in multiple comps with path"
    assertAmbiguous ("src" </> "Bar.hs")
      [ mkTargetFile "foo" (CExeName "bar")  ("src" </> "Bar")
      , mkTargetFile "foo" (CExeName "bar2") ("src" </> "Bar")
      ]
      [ mkpkg "foo" [ mkexe "bar"  `withModules` ["Bar"] `withHsSrcDirs` ["src"]
                    , mkexe "bar2" `withModules` ["Bar"] `withHsSrcDirs` ["src"] ]
      ]

    -- non-exact case packages and components are ambiguous
    reportSubCase "ambiguous: non-exact-case pkg names"
    assertAmbiguous "Foo"
      [ mkTargetPackage "foo", mkTargetPackage "FOO" ]
      [ mkpkg "foo" [], mkpkg "FOO" [] ]
    reportSubCase "ambiguous: non-exact-case comp names"
    assertAmbiguous "Foo"
      [ mkTargetComponent "bar" (CExeName "foo")
      , mkTargetComponent "bar" (CExeName "FOO") ]
      [ mkpkg "bar" [mkexe "foo", mkexe "FOO"] ]

    -- exact-case Module or File over non-exact case package or component
    reportSubCase "unambiguous: module vs non-exact-case pkg, comp"
    assertUnambiguous "Baz"
      (mkTargetModule "other" (CExeName "other") "Baz")
      [ mkpkg "baz" [mkexe "BAZ"]
      , mkpkg "other" [ mkexe "other"  `withModules` ["Baz"] ]
      ]
    reportSubCase "unambiguous: file vs non-exact-case pkg, comp"
    assertUnambiguous "Baz"
      (mkTargetFile "other" (CExeName "other") "Baz")
      [ mkpkg "baz" [mkexe "BAZ"]
      , mkpkg "other" [ mkexe "other"  `withCFiles` ["Baz"] ]
      ]
  where
    assertAmbiguous :: String
                    -> [TargetSelector]
                    -> [SourcePackage (PackageLocation a)]
                    -> Assertion
    assertAmbiguous str tss pkgs = do
      res <- readTargetSelectorsWith
               fakeDirActions
               (map SpecificSourcePackage pkgs)
               Nothing
               [str]
      case res of
        Left [TargetSelectorAmbiguous _ tss'] ->
          sort (map snd tss') @?= sort tss
        _ -> assertFailure $ "expected Left [TargetSelectorAmbiguous _ _], "
                          ++ "got " ++ show res

    assertUnambiguous :: String
                      -> TargetSelector
                      -> [SourcePackage (PackageLocation a)]
                      -> Assertion
    assertUnambiguous str ts pkgs = do
      res <- readTargetSelectorsWith
               fakeDirActions
               (map SpecificSourcePackage pkgs)
               Nothing
               [str]
      case res of
        Right [ts'] -> ts' @?= ts
        _ -> assertFailure $ "expected Right [Target...], "
                          ++ "got " ++ show res

    fakeDirActions = TS.DirActions {
      TS.doesFileExist       = \_p -> return True,
      TS.doesDirectoryExist  = \_p -> return True,
      TS.canonicalizePath    = \p -> return ("/" </> p), -- FilePath.Unix.</> ?
      TS.getCurrentDirectory = return "/"
    }

    mkpkg :: String -> [Executable] -> SourcePackage (PackageLocation a)
    mkpkg pkgidstr exes = mkpkgAt pkgidstr exes ""

    mkpkgAt :: String -> [Executable] -> FilePath
            -> SourcePackage (PackageLocation a)
    mkpkgAt pkgidstr exes loc =
      SourcePackage {
        srcpkgPackageId = pkgid,
        srcpkgSource = LocalUnpackedPackage loc,
        srcpkgDescrOverride  = Nothing,
        srcpkgDescription = GenericPackageDescription {
          packageDescription = emptyPackageDescription { package = pkgid },
          gpdScannedVersion  = Nothing,
          genPackageFlags    = [],
          condLibrary        = Nothing,
          condSubLibraries   = [],
          condForeignLibs    = [],
          condExecutables    = [ ( exeName exe, CondNode exe [] [] )
                               | exe <- exes ],
          condTestSuites     = [],
          condBenchmarks     = []
        }
      }
      where
        pkgid = fromMaybe (error $ "failed to parse " ++ pkgidstr) $ simpleParse pkgidstr

    mkexe :: String -> Executable
    mkexe name = mempty { exeName = fromString name }

    withModules :: Executable -> [String] -> Executable
    withModules exe mods =
      exe { buildInfo = (buildInfo exe) { otherModules = map fromString mods } }

    withCFiles :: Executable -> [FilePath] -> Executable
    withCFiles exe files =
      exe { buildInfo = (buildInfo exe) { cSources = files } }

    withHsSrcDirs :: Executable -> [FilePath] -> Executable
    withHsSrcDirs exe srcDirs =
      exe { buildInfo = (buildInfo exe) { hsSourceDirs = map unsafeMakeSymbolicPath srcDirs }}


mkTargetPackage :: PackageId -> TargetSelector
mkTargetPackage pkgid =
    TargetPackage TargetExplicitNamed [pkgid] Nothing

mkTargetComponent :: PackageId -> ComponentName -> TargetSelector
mkTargetComponent pkgid cname =
    TargetComponent pkgid cname WholeComponent

mkTargetModule :: PackageId -> ComponentName -> ModuleName -> TargetSelector
mkTargetModule pkgid cname mname =
    TargetComponent pkgid cname (ModuleTarget mname)

mkTargetFile :: PackageId -> ComponentName -> String -> TargetSelector
mkTargetFile pkgid cname fname =
    TargetComponent pkgid cname (FileTarget fname)

mkTargetAllPackages :: TargetSelector
mkTargetAllPackages = TargetAllPackages Nothing

instance IsString PackageIdentifier where
    fromString pkgidstr = pkgid
      where pkgid = fromMaybe (error $"fromString @PackageIdentifier " ++ show pkgidstr) $ simpleParse pkgidstr


testTargetSelectorNoCurrentPackage :: Assertion
testTargetSelectorNoCurrentPackage = do
    (_, _, _, localPackages, _) <- configureProject testdir config
    let readTargetSelectors' = readTargetSelectorsWith (dirActions testdir)
                                                       localPackages
                                                       Nothing
        targets = [ "libs",  ":cwd:libs"
                  , "flibs", ":cwd:flibs"
                  , "exes",  ":cwd:exes"
                  , "tests", ":cwd:tests"
                  , "benchmarks", ":cwd:benchmarks"]
    Left errs <- readTargetSelectors' targets
    zipWithM_ (@?=) errs
      [ TargetSelectorNoCurrentPackage ts
      | target <- targets
      , let ts = fromMaybe (error $ "failed to parse target string " ++ target) $ parseTargetString target
      ]
    cleanProject testdir
  where
    testdir = "targets/complex"
    config  = mempty


testTargetSelectorNoTargets :: Assertion
testTargetSelectorNoTargets = do
    (_, _, _, localPackages, _) <- configureProject testdir config
    Left errs <- readTargetSelectors localPackages Nothing []
    errs @?= [TargetSelectorNoTargetsInCwd]
    cleanProject testdir
  where
    testdir = "targets/complex"
    config  = mempty


testTargetSelectorProjectEmpty :: Assertion
testTargetSelectorProjectEmpty = do
    (_, _, _, localPackages, _) <- configureProject testdir config
    Left errs <- readTargetSelectors localPackages Nothing []
    errs @?= [TargetSelectorNoTargetsInProject]
    cleanProject testdir
  where
    testdir = "targets/empty"
    config  = mempty


-- | Ensure we don't miss primary package and produce
-- TargetSelectorNoTargetsInCwd error due to symlink or
-- drive capitalisation mismatch when no targets are given
testTargetSelectorCanonicalizedPath :: Assertion
testTargetSelectorCanonicalizedPath = do
  (_, _, _, localPackages, _) <- configureProject testdir config
  cwd <- getCurrentDirectory
  let virtcwd = cwd </> basedir </> symlink
  -- Check that the symlink is there before running test as on Windows
  -- some versions/configurations of git won't pull down/create the symlink
  canRunTest <- doesDirectoryExist virtcwd
  when canRunTest (do
      let dirActions' = (dirActions symlink) { TS.getCurrentDirectory = return virtcwd }
      Right ts <- readTargetSelectorsWith dirActions' localPackages Nothing []
      ts @?= [TargetPackage TargetImplicitCwd ["p-0.1"] Nothing])
  cleanProject testdir
  where
    testdir = "targets/simple"
    symlink = "targets/symbolic-link-to-simple"
    config = mempty


testTargetProblemsCommon :: ProjectConfig -> Assertion
testTargetProblemsCommon config0 = do
    (_,elaboratedPlan,_) <- planProject testdir config

    let pkgIdMap :: Map.Map PackageName PackageId
        pkgIdMap = Map.fromList
                     [ (packageName p, packageId p)
                     | p <- InstallPlan.toList elaboratedPlan ]

        cases :: [( TargetSelector -> TargetProblem'
                  , TargetSelector
                  )]
        cases =
          [ -- Cannot resolve packages outside of the project
            ( \_ -> TargetProblemNoSuchPackage "foobar"
            , mkTargetPackage "foobar" )

            -- We cannot currently build components like testsuites or
            -- benchmarks from packages that are not local to the project
          , ( \_ -> TargetComponentNotProjectLocal
                      (pkgIdMap Map.! "filepath") (CTestName "filepath-tests")
                      WholeComponent
            , mkTargetComponent (pkgIdMap Map.! "filepath")
                                (CTestName "filepath-tests") )

            -- Components can be explicitly @buildable: False@
          , ( \_ -> TargetComponentNotBuildable "q-0.1" (CExeName "buildable-false") WholeComponent
            , mkTargetComponent "q-0.1" (CExeName "buildable-false") )

            -- Testsuites and benchmarks can be disabled by the solver if it
            -- cannot satisfy deps
          , ( \_ -> TargetOptionalStanzaDisabledBySolver "q-0.1" (CTestName "solver-disabled") WholeComponent
            , mkTargetComponent "q-0.1" (CTestName "solver-disabled") )

            -- Testsuites and benchmarks can be disabled explicitly by the
            -- user via config
          , ( \_ -> TargetOptionalStanzaDisabledByUser
                      "q-0.1" (CBenchName "user-disabled") WholeComponent
            , mkTargetComponent "q-0.1" (CBenchName "user-disabled") )

            -- An unknown package. The target selector resolution should only
            -- produce known packages, so this should not happen with the
            -- output from 'readTargetSelectors'.
          , ( \_ -> TargetProblemNoSuchPackage "foobar"
            , mkTargetPackage "foobar" )

            -- An unknown component of a known package. The target selector
            -- resolution should only produce known packages, so this should
            -- not happen with the output from 'readTargetSelectors'.
          , ( \_ -> TargetProblemNoSuchComponent "q-0.1" (CExeName "no-such")
            , mkTargetComponent "q-0.1" (CExeName "no-such") )
          ]
    assertTargetProblems
      elaboratedPlan
      CmdBuild.selectPackageTargets
      CmdBuild.selectComponentTarget
      cases
  where
    testdir = "targets/complex"
    config  = config0 {
      projectConfigLocalPackages = (projectConfigLocalPackages config0) {
        packageConfigBenchmarks = toFlag False
      }
    , projectConfigShared = (projectConfigShared config0) {
        projectConfigConstraints =
          [( UserConstraint (UserAnyQualifier "filepath") PackagePropertySource
           , ConstraintSourceUnknown )]
      }
    }


testTargetProblemsBuild :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsBuild config reportSubCase = do

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdBuild.selectPackageTargets
      CmdBuild.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "all-disabled"
    assertProjectTargetProblems
      "targets/all-disabled"
      config {
        projectConfigLocalPackages = (projectConfigLocalPackages config) {
          packageConfigBenchmarks = toFlag False
        }
      }
      CmdBuild.selectPackageTargets
      CmdBuild.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CBenchName "user-disabled")
                                 TargetDisabledByUser True
               , AvailableTarget "p-0.1" (CTestName "solver-disabled")
                                 TargetDisabledBySolver True
               , AvailableTarget "p-0.1" (CExeName "buildable-false")
                                 TargetNotBuildable True
               , AvailableTarget "p-0.1" (CLibName LMainLibName)
                                 TargetNotBuildable True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "enabled component kinds"
    -- When we explicitly enable all the component kinds then selecting the
    -- whole package selects those component kinds too
    do (_,elaboratedPlan,_) <- planProject "targets/variety" config {
           projectConfigLocalPackages = (projectConfigLocalPackages config) {
             packageConfigTests      = toFlag True,
             packageConfigBenchmarks = toFlag True
           }
         }
       assertProjectDistinctTargets
         elaboratedPlan
         CmdBuild.selectPackageTargets
         CmdBuild.selectComponentTarget
         [ mkTargetPackage "p-0.1" ]
         [ ("p-0.1-inplace",             (CLibName LMainLibName))
         , ("p-0.1-inplace-a-benchmark", CBenchName "a-benchmark")
         , ("p-0.1-inplace-a-testsuite", CTestName  "a-testsuite")
         , ("p-0.1-inplace-an-exe",      CExeName   "an-exe")
         , ("p-0.1-inplace-libp",        CFLibName  "libp")
         ]

    reportSubCase "disabled component kinds"
    -- When we explicitly disable all the component kinds then selecting the
    -- whole package only selects the library, foreign lib and exes
    do (_,elaboratedPlan,_) <- planProject "targets/variety" config {
           projectConfigLocalPackages = (projectConfigLocalPackages config) {
             packageConfigTests      = toFlag False,
             packageConfigBenchmarks = toFlag False
           }
         }
       assertProjectDistinctTargets
         elaboratedPlan
         CmdBuild.selectPackageTargets
         CmdBuild.selectComponentTarget
         [ mkTargetPackage "p-0.1" ]
         [ ("p-0.1-inplace",        (CLibName LMainLibName))
         , ("p-0.1-inplace-an-exe", CExeName  "an-exe")
         , ("p-0.1-inplace-libp",   CFLibName "libp")
         ]

    reportSubCase "requested component kinds"
    -- When we selecting the package with an explicit filter then we get those
    -- components even though we did not explicitly enable tests/benchmarks
    do (_,elaboratedPlan,_) <- planProject "targets/variety" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdBuild.selectPackageTargets
         CmdBuild.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] (Just TestKind)
         , TargetPackage TargetExplicitNamed ["p-0.1"] (Just BenchKind)
         ]
         [ ("p-0.1-inplace-a-benchmark", CBenchName "a-benchmark")
         , ("p-0.1-inplace-a-testsuite", CTestName  "a-testsuite")
         ]


testTargetProblemsRepl :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsRepl config reportSubCase = do

    reportSubCase "multiple-libs"
    assertProjectTargetProblems
      "targets/multiple-libs" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip CmdRepl.matchesMultipleProblem
               [ AvailableTarget "p-0.1" (CLibName LMainLibName)
                   (TargetBuildable () TargetRequestedByDefault) True
               , AvailableTarget "q-0.1" (CLibName LMainLibName)
                   (TargetBuildable () TargetRequestedByDefault) True
               ]
        , mkTargetAllPackages )
      ]

    reportSubCase "multiple-exes"
    assertProjectTargetProblems
      "targets/multiple-exes" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip CmdRepl.matchesMultipleProblem
               [ AvailableTarget "p-0.1" (CExeName "p2")
                   (TargetBuildable () TargetRequestedByDefault) True
               , AvailableTarget "p-0.1" (CExeName "p1")
                   (TargetBuildable () TargetRequestedByDefault) True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "multiple-tests"
    assertProjectTargetProblems
      "targets/multiple-tests" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip CmdRepl.matchesMultipleProblem
               [ AvailableTarget "p-0.1" (CTestName "p2")
                   (TargetBuildable () TargetNotRequestedByDefault) True
               , AvailableTarget "p-0.1" (CTestName "p1")
                   (TargetBuildable () TargetNotRequestedByDefault) True
               ]
        , TargetPackage TargetExplicitNamed ["p-0.1"] (Just TestKind) )
      ]

    reportSubCase "multiple targets"
    do (_,elaboratedPlan,_) <- planProject "targets/multiple-exes" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRepl.selectPackageTargets
         CmdRepl.selectComponentTarget
         [ mkTargetComponent "p-0.1" (CExeName "p1")
         , mkTargetComponent "p-0.1" (CExeName "p2")
         ]
         [ ("p-0.1-inplace-p1", CExeName "p1")
         , ("p-0.1-inplace-p2", CExeName "p2")
         ]

    reportSubCase "libs-disabled"
    assertProjectTargetProblems
      "targets/libs-disabled" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CLibName LMainLibName) TargetNotBuildable True ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "exes-disabled"
    assertProjectTargetProblems
      "targets/exes-disabled" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CExeName "p") TargetNotBuildable True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "test-only"
    assertProjectTargetProblems
      "targets/test-only" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CTestName "pexe")
                   (TargetBuildable () TargetNotRequestedByDefault) True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdRepl.selectPackageTargets
      CmdRepl.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "requested component kinds"
    do (_,elaboratedPlan,_) <- planProject "targets/variety" config
       -- by default we only get the lib
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRepl.selectPackageTargets
         CmdRepl.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] Nothing ]
         [ ("p-0.1-inplace", (CLibName LMainLibName)) ]
       -- When we select the package with an explicit filter then we get those
       -- components even though we did not explicitly enable tests/benchmarks
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRepl.selectPackageTargets
         CmdRepl.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] (Just TestKind) ]
         [ ("p-0.1-inplace-a-testsuite", CTestName  "a-testsuite") ]
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRepl.selectPackageTargets
         CmdRepl.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] (Just BenchKind) ]
         [ ("p-0.1-inplace-a-benchmark", CBenchName "a-benchmark") ]

testTargetProblemsListBin :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsListBin config reportSubCase = do
    reportSubCase "one-of-each"
    do (_,elaboratedPlan,_) <- planProject "targets/one-of-each" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdListBin.selectPackageTargets
         CmdListBin.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] Nothing
         ]
         [ ("p-0.1-inplace-p1",      CExeName   "p1")
         ]

    reportSubCase "multiple-exes"
    assertProjectTargetProblems
      "targets/multiple-exes" config
      CmdListBin.selectPackageTargets
      CmdListBin.selectComponentTarget
      [ ( flip CmdListBin.matchesMultipleProblem
               [ AvailableTarget "p-0.1" (CExeName "p2")
                   (TargetBuildable () TargetRequestedByDefault) True
               , AvailableTarget "p-0.1" (CExeName "p1")
                   (TargetBuildable () TargetRequestedByDefault) True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "multiple targets"
    do (_,elaboratedPlan,_) <- planProject "targets/multiple-exes" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdListBin.selectPackageTargets
         CmdListBin.selectComponentTarget
         [ mkTargetComponent "p-0.1" (CExeName "p1")
         , mkTargetComponent "p-0.1" (CExeName "p2")
         ]
         [ ("p-0.1-inplace-p1", CExeName "p1")
         , ("p-0.1-inplace-p2", CExeName "p2")
         ]

    reportSubCase "exes-disabled"
    assertProjectTargetProblems
      "targets/exes-disabled" config
      CmdListBin.selectPackageTargets
      CmdListBin.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CExeName "p") TargetNotBuildable True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdListBin.selectPackageTargets
      CmdListBin.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "lib-only"
    assertProjectTargetProblems
      "targets/lib-only" config
      CmdListBin.selectPackageTargets
      CmdListBin.selectComponentTarget
      [ (CmdListBin.noComponentsProblem, mkTargetPackage "p-0.1" )
      ]

testTargetProblemsRun :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsRun config reportSubCase = do
    reportSubCase "one-of-each"
    do (_,elaboratedPlan,_) <- planProject "targets/one-of-each" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRun.selectPackageTargets
         CmdRun.selectComponentTarget
         [ TargetPackage TargetExplicitNamed ["p-0.1"] Nothing
         ]
         [ ("p-0.1-inplace-p1",      CExeName   "p1")
         ]

    reportSubCase "multiple-exes"
    assertProjectTargetProblems
      "targets/multiple-exes" config
      CmdRun.selectPackageTargets
      CmdRun.selectComponentTarget
      [ ( flip CmdRun.matchesMultipleProblem
               [ AvailableTarget "p-0.1" (CExeName "p2")
                   (TargetBuildable () TargetRequestedByDefault) True
               , AvailableTarget "p-0.1" (CExeName "p1")
                   (TargetBuildable () TargetRequestedByDefault) True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "multiple targets"
    do (_,elaboratedPlan,_) <- planProject "targets/multiple-exes" config
       assertProjectDistinctTargets
         elaboratedPlan
         CmdRun.selectPackageTargets
         CmdRun.selectComponentTarget
         [ mkTargetComponent "p-0.1" (CExeName "p1")
         , mkTargetComponent "p-0.1" (CExeName "p2")
         ]
         [ ("p-0.1-inplace-p1", CExeName "p1")
         , ("p-0.1-inplace-p2", CExeName "p2")
         ]

    reportSubCase "exes-disabled"
    assertProjectTargetProblems
      "targets/exes-disabled" config
      CmdRun.selectPackageTargets
      CmdRun.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CExeName "p") TargetNotBuildable True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdRun.selectPackageTargets
      CmdRun.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "lib-only"
    assertProjectTargetProblems
      "targets/lib-only" config
      CmdRun.selectPackageTargets
      CmdRun.selectComponentTarget
      [ (CmdRun.noExesProblem, mkTargetPackage "p-0.1" )
      ]


testTargetProblemsTest :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsTest config reportSubCase = do

    reportSubCase "disabled by config"
    assertProjectTargetProblems
      "targets/tests-disabled"
      config {
        projectConfigLocalPackages = (projectConfigLocalPackages config) {
          packageConfigTests = toFlag False
        }
      }
      CmdTest.selectPackageTargets
      CmdTest.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CTestName "user-disabled")
                                 TargetDisabledByUser True
               , AvailableTarget "p-0.1" (CTestName "solver-disabled")
                                 TargetDisabledByUser True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "disabled by solver & buildable false"
    assertProjectTargetProblems
      "targets/tests-disabled"
      config
      CmdTest.selectPackageTargets
      CmdTest.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CTestName "user-disabled")
                                 TargetDisabledBySolver True
               , AvailableTarget "p-0.1" (CTestName "solver-disabled")
                                 TargetDisabledBySolver True
               ]
        , mkTargetPackage "p-0.1" )

      , ( flip TargetProblemNoneEnabled
               [ AvailableTarget "q-0.1" (CTestName "buildable-false")
                                 TargetNotBuildable True
               ]
        , mkTargetPackage "q-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdTest.selectPackageTargets
      CmdTest.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "no tests"
    assertProjectTargetProblems
      "targets/simple"
      config
      CmdTest.selectPackageTargets
      CmdTest.selectComponentTarget
      [ ( CmdTest.noTestsProblem, mkTargetPackage "p-0.1" )
      , ( CmdTest.noTestsProblem, mkTargetPackage "q-0.1" )
      ]

    reportSubCase "not a test"
    assertProjectTargetProblems
      "targets/variety"
      config
      CmdTest.selectPackageTargets
      CmdTest.selectComponentTarget $
      [ ( const (CmdTest.notTestProblem
                  "p-0.1" (CLibName LMainLibName))
        , mkTargetComponent "p-0.1" (CLibName LMainLibName) )

      , ( const (CmdTest.notTestProblem
                  "p-0.1" (CExeName "an-exe"))
        , mkTargetComponent "p-0.1" (CExeName "an-exe") )

      , ( const (CmdTest.notTestProblem
                  "p-0.1" (CFLibName "libp"))
        , mkTargetComponent "p-0.1" (CFLibName "libp") )

      , ( const (CmdTest.notTestProblem
                  "p-0.1" (CBenchName "a-benchmark"))
        , mkTargetComponent "p-0.1" (CBenchName "a-benchmark") )
      ] ++
      [ ( const (CmdTest.isSubComponentProblem
                          "p-0.1" cname (ModuleTarget modname))
        , mkTargetModule "p-0.1" cname modname )
      | (cname, modname) <- [ (CTestName  "a-testsuite", "TestModule")
                            , (CBenchName "a-benchmark", "BenchModule")
                            , (CExeName   "an-exe",      "ExeModule")
                            , ((CLibName LMainLibName),                 "P")
                            ]
      ] ++
      [ ( const (CmdTest.isSubComponentProblem
                          "p-0.1" cname (FileTarget fname))
        , mkTargetFile "p-0.1" cname fname)
      | (cname, fname) <- [ (CTestName  "a-testsuite", "Test.hs")
                          , (CBenchName "a-benchmark", "Bench.hs")
                          , (CExeName   "an-exe",      "Main.hs")
                          ]
      ]


testTargetProblemsBench :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsBench config reportSubCase = do

    reportSubCase "disabled by config"
    assertProjectTargetProblems
      "targets/benchmarks-disabled"
      config {
        projectConfigLocalPackages = (projectConfigLocalPackages config) {
          packageConfigBenchmarks = toFlag False
        }
      }
      CmdBench.selectPackageTargets
      CmdBench.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CBenchName "user-disabled")
                                 TargetDisabledByUser True
               , AvailableTarget "p-0.1" (CBenchName "solver-disabled")
                                 TargetDisabledByUser True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "disabled by solver & buildable false"
    assertProjectTargetProblems
      "targets/benchmarks-disabled"
      config
      CmdBench.selectPackageTargets
      CmdBench.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CBenchName "user-disabled")
                                 TargetDisabledBySolver True
               , AvailableTarget "p-0.1" (CBenchName "solver-disabled")
                                 TargetDisabledBySolver True
               ]
        , mkTargetPackage "p-0.1" )

      , ( flip TargetProblemNoneEnabled
               [ AvailableTarget "q-0.1" (CBenchName "buildable-false")
                                 TargetNotBuildable True
               ]
        , mkTargetPackage "q-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      CmdBench.selectPackageTargets
      CmdBench.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "no benchmarks"
    assertProjectTargetProblems
      "targets/simple"
      config
      CmdBench.selectPackageTargets
      CmdBench.selectComponentTarget
      [ ( CmdBench.noBenchmarksProblem, mkTargetPackage "p-0.1" )
      , ( CmdBench.noBenchmarksProblem, mkTargetPackage "q-0.1" )
      ]

    reportSubCase "not a benchmark"
    assertProjectTargetProblems
      "targets/variety"
      config
      CmdBench.selectPackageTargets
      CmdBench.selectComponentTarget $
      [ ( const (CmdBench.componentNotBenchmarkProblem
                  "p-0.1" (CLibName LMainLibName))
        , mkTargetComponent "p-0.1" (CLibName LMainLibName) )

      , ( const (CmdBench.componentNotBenchmarkProblem
                  "p-0.1" (CExeName "an-exe"))
        , mkTargetComponent "p-0.1" (CExeName "an-exe") )

      , ( const (CmdBench.componentNotBenchmarkProblem
                  "p-0.1" (CFLibName "libp"))
        , mkTargetComponent "p-0.1" (CFLibName "libp") )

      , ( const (CmdBench.componentNotBenchmarkProblem
                  "p-0.1" (CTestName "a-testsuite"))
        , mkTargetComponent "p-0.1" (CTestName "a-testsuite") )
      ] ++
      [ ( const (CmdBench.isSubComponentProblem
                          "p-0.1" cname (ModuleTarget modname))
        , mkTargetModule "p-0.1" cname modname )
      | (cname, modname) <- [ (CTestName  "a-testsuite", "TestModule")
                            , (CBenchName "a-benchmark", "BenchModule")
                            , (CExeName   "an-exe",      "ExeModule")
                            , ((CLibName LMainLibName),                 "P")
                            ]
      ] ++
      [ ( const (CmdBench.isSubComponentProblem
                          "p-0.1" cname (FileTarget fname))
        , mkTargetFile "p-0.1" cname fname)
      | (cname, fname) <- [ (CTestName  "a-testsuite", "Test.hs")
                          , (CBenchName "a-benchmark", "Bench.hs")
                          , (CExeName   "an-exe",      "Main.hs")
                          ]
      ]


testTargetProblemsHaddock :: ProjectConfig -> (String -> IO ()) -> Assertion
testTargetProblemsHaddock config reportSubCase = do

    reportSubCase "all-disabled"
    assertProjectTargetProblems
      "targets/all-disabled"
      config
      (let haddockFlags = mkHaddockFlags False True True False
        in CmdHaddock.selectPackageTargets haddockFlags)
      CmdHaddock.selectComponentTarget
      [ ( flip TargetProblemNoneEnabled
               [ AvailableTarget "p-0.1" (CBenchName "user-disabled")
                                 TargetDisabledByUser True
               , AvailableTarget "p-0.1" (CTestName "solver-disabled")
                                 TargetDisabledBySolver True
               , AvailableTarget "p-0.1" (CExeName "buildable-false")
                                 TargetNotBuildable True
               , AvailableTarget "p-0.1" (CLibName LMainLibName)
                                 TargetNotBuildable True
               ]
        , mkTargetPackage "p-0.1" )
      ]

    reportSubCase "empty-pkg"
    assertProjectTargetProblems
      "targets/empty-pkg" config
      (let haddockFlags = mkHaddockFlags False False False False
        in CmdHaddock.selectPackageTargets haddockFlags)
      CmdHaddock.selectComponentTarget
      [ ( TargetProblemNoTargets, mkTargetPackage "p-0.1" )
      ]

    reportSubCase "enabled component kinds"
    -- When we explicitly enable all the component kinds then selecting the
    -- whole package selects those component kinds too
    (_,elaboratedPlan,_) <- planProject "targets/variety" config
    let haddockFlags = mkHaddockFlags True True True True
     in assertProjectDistinctTargets
          elaboratedPlan
          (CmdHaddock.selectPackageTargets haddockFlags)
          CmdHaddock.selectComponentTarget
          [ mkTargetPackage "p-0.1" ]
          [ ("p-0.1-inplace",             (CLibName LMainLibName))
          , ("p-0.1-inplace-a-benchmark", CBenchName "a-benchmark")
          , ("p-0.1-inplace-a-testsuite", CTestName  "a-testsuite")
          , ("p-0.1-inplace-an-exe",      CExeName   "an-exe")
          , ("p-0.1-inplace-libp",        CFLibName  "libp")
          ]

    reportSubCase "disabled component kinds"
    -- When we explicitly disable all the component kinds then selecting the
    -- whole package only selects the library
    let haddockFlags = mkHaddockFlags False False False False
     in assertProjectDistinctTargets
          elaboratedPlan
          (CmdHaddock.selectPackageTargets haddockFlags)
          CmdHaddock.selectComponentTarget
          [ mkTargetPackage "p-0.1" ]
          [ ("p-0.1-inplace", (CLibName LMainLibName)) ]

    reportSubCase "requested component kinds"
    -- When we selecting the package with an explicit filter then it does not
    -- matter if the config was to disable all the component kinds
    let haddockFlags = mkHaddockFlags False False False False
     in assertProjectDistinctTargets
          elaboratedPlan
          (CmdHaddock.selectPackageTargets haddockFlags)
          CmdHaddock.selectComponentTarget
          [ TargetPackage TargetExplicitNamed ["p-0.1"] (Just FLibKind)
          , TargetPackage TargetExplicitNamed ["p-0.1"] (Just ExeKind)
          , TargetPackage TargetExplicitNamed ["p-0.1"] (Just TestKind)
          , TargetPackage TargetExplicitNamed ["p-0.1"] (Just BenchKind)
          ]
          [ ("p-0.1-inplace-a-benchmark", CBenchName "a-benchmark")
          , ("p-0.1-inplace-a-testsuite", CTestName  "a-testsuite")
          , ("p-0.1-inplace-an-exe",      CExeName   "an-exe")
          , ("p-0.1-inplace-libp",        CFLibName  "libp")
          ]
  where
    mkHaddockFlags flib exe test bench =
      defaultHaddockFlags {
        haddockForeignLibs = toFlag flib,
        haddockExecutables = toFlag exe,
        haddockTestSuites  = toFlag test,
        haddockBenchmarks  = toFlag bench
      }

assertProjectDistinctTargets
  :: forall err. (Eq err, Show err) =>
     ElaboratedInstallPlan
  -> (forall k. TargetSelector -> [AvailableTarget k] -> Either (TargetProblem err) [k])
  -> (forall k. SubComponentTarget ->  AvailableTarget k  -> Either (TargetProblem err)  k )
  -> [TargetSelector]
  -> [(UnitId, ComponentName)]
  -> Assertion
assertProjectDistinctTargets elaboratedPlan
                             selectPackageTargets
                             selectComponentTarget
                             targetSelectors
                             expectedTargets
  | Right targets <- results
  = distinctTargetComponents targets @?= Set.fromList expectedTargets

  | otherwise
  = assertFailure $ "assertProjectDistinctTargets: expected "
                 ++ "(Right targets) but got " ++ show results
  where
    results = resolveTargets
                selectPackageTargets
                selectComponentTarget
                elaboratedPlan
                Nothing
                targetSelectors


assertProjectTargetProblems
  :: forall err. (Eq err, Show err) =>
     FilePath -> ProjectConfig
  -> (forall k. TargetSelector
             -> [AvailableTarget k]
             -> Either (TargetProblem err) [k])
  -> (forall k. SubComponentTarget
             -> AvailableTarget k
             -> Either (TargetProblem err) k )
  -> [(TargetSelector -> TargetProblem err, TargetSelector)]
  -> Assertion
assertProjectTargetProblems testdir config
                            selectPackageTargets
                            selectComponentTarget
                            cases = do
    (_,elaboratedPlan,_) <- planProject testdir config
    assertTargetProblems
      elaboratedPlan
      selectPackageTargets
      selectComponentTarget
      cases


assertTargetProblems
  :: forall err. (Eq err, Show err) =>
     ElaboratedInstallPlan
  -> (forall k. TargetSelector -> [AvailableTarget k] -> Either (TargetProblem err) [k])
  -> (forall k. SubComponentTarget ->  AvailableTarget k  -> Either (TargetProblem err)  k )
  -> [(TargetSelector -> TargetProblem err, TargetSelector)]
  -> Assertion
assertTargetProblems elaboratedPlan selectPackageTargets selectComponentTarget =
    mapM_ (uncurry assertTargetProblem)
  where
    assertTargetProblem expected targetSelector =
      let res = resolveTargets selectPackageTargets selectComponentTarget
                               elaboratedPlan Nothing
                               [targetSelector] in
      case res of
        Left [problem] ->
          problem @?= expected targetSelector

        unexpected ->
          assertFailure $ "expected resolveTargets result: (Left [problem]) "
                       ++ "but got: " ++ show unexpected


testExceptionInFindingPackage :: ProjectConfig -> Assertion
testExceptionInFindingPackage config = do
    BadPackageLocations _ locs <- expectException "BadPackageLocations" $
      void $ planProject testdir config
    case locs of
      [BadLocGlobEmptyMatch "./*.cabal"] -> return ()
      _ -> assertFailure "expected BadLocGlobEmptyMatch"
    cleanProject testdir
  where
    testdir = "exception/no-pkg"


testExceptionInFindingPackage2 :: ProjectConfig -> Assertion
testExceptionInFindingPackage2 config = do
    BadPackageLocations _ locs <- expectException "BadPackageLocations" $
      void $ planProject testdir config
    case locs of
      [BadPackageLocationFile (BadLocDirNoCabalFile ".")] -> return ()
      _ -> assertFailure $ "expected BadLocDirNoCabalFile, got " ++ show locs
    cleanProject testdir
  where
    testdir = "exception/no-pkg2"


testExceptionInProjectConfig :: ProjectConfig -> Assertion
testExceptionInProjectConfig config = do
    BadPerPackageCompilerPaths ps <- expectException "BadPerPackageCompilerPaths" $
      void $ planProject testdir config
    case ps of
      [(pn,"ghc")] | "foo" == pn -> return ()
      _ -> assertFailure $ "expected (PackageName \"foo\",\"ghc\"), got "
                        ++ show ps
    cleanProject testdir
  where
    testdir = "exception/bad-config"


testExceptionInConfigureStep :: ProjectConfig -> Assertion
testExceptionInConfigureStep config = do
    (plan, res) <- executePlan =<< planProject testdir config
    (_pkga1, failure) <- expectPackageFailed plan res pkgidA1
    case buildFailureReason failure of
      ConfigureFailed _ -> return ()
      _ -> assertFailure $ "expected ConfigureFailed, got " ++ show failure
    cleanProject testdir
  where
    testdir = "exception/configure"
    pkgidA1 = PackageIdentifier "a" (mkVersion [1])


testExceptionInBuildStep :: ProjectConfig -> Assertion
testExceptionInBuildStep config = do
    (plan, res) <- executePlan =<< planProject testdir config
    (_pkga1, failure) <- expectPackageFailed plan res pkgidA1
    expectBuildFailed failure
  where
    testdir = "exception/build"
    pkgidA1 = PackageIdentifier "a" (mkVersion [1])

testSetupScriptStyles :: ProjectConfig -> (String -> IO ()) -> Assertion
testSetupScriptStyles config reportSubCase = do

  reportSubCase (show SetupCustomExplicitDeps)

  plan0@(_,_,sharedConfig) <- planProject testdir1 config

  let isOSX (Platform _ OSX) = True
      isOSX _ = False
  -- Skip the Custom tests when the shipped Cabal library is buggy
  unless (isOSX (pkgConfigPlatform sharedConfig)
       && compilerVersion (pkgConfigCompiler sharedConfig) < mkVersion [7,10]) $ do

    (plan1, res1) <- executePlan plan0
    pkg1          <- expectPackageInstalled plan1 res1 pkgidA
    elabSetupScriptStyle pkg1 @?= SetupCustomExplicitDeps
    hasDefaultSetupDeps pkg1 @?= Just False
    marker1 <- readFile (basedir </> testdir1 </> "marker")
    marker1 @?= "ok"
    removeFile (basedir </> testdir1 </> "marker")

    -- implicit deps implies 'Cabal < 2' which conflicts w/ GHC 8.2 or later
    when (compilerVersion (pkgConfigCompiler sharedConfig) < mkVersion [8,2]) $ do
      reportSubCase (show SetupCustomImplicitDeps)
      (plan2, res2) <- executePlan =<< planProject testdir2 config
      pkg2          <- expectPackageInstalled plan2 res2 pkgidA
      elabSetupScriptStyle pkg2 @?= SetupCustomImplicitDeps
      hasDefaultSetupDeps pkg2 @?= Just True
      marker2 <- readFile (basedir </> testdir2 </> "marker")
      marker2 @?= "ok"
      removeFile (basedir </> testdir2 </> "marker")

    reportSubCase (show SetupNonCustomInternalLib)
    (plan3, res3) <- executePlan =<< planProject testdir3 config
    pkg3          <- expectPackageInstalled plan3 res3 pkgidA
    elabSetupScriptStyle pkg3 @?= SetupNonCustomInternalLib
{-
    --TODO: the SetupNonCustomExternalLib case is hard to test since it
    -- requires a version of Cabal that's later than the one we're testing
    -- e.g. needs a .cabal file that specifies cabal-version: >= 2.0
    -- and a corresponding Cabal package that we can use to try and build a
    -- default Setup.hs.
    reportSubCase (show SetupNonCustomExternalLib)
    (plan4, res4) <- executePlan =<< planProject testdir4 config
    pkg4          <- expectPackageInstalled plan4 res4 pkgidA
    pkgSetupScriptStyle pkg4 @?= SetupNonCustomExternalLib
-}
  where
    testdir1 = "build/setup-custom1"
    testdir2 = "build/setup-custom2"
    testdir3 = "build/setup-simple"
    pkgidA   = PackageIdentifier "a" (mkVersion [0,1])
    -- The solver fills in default setup deps explicitly, but marks them as such
    hasDefaultSetupDeps = fmap defaultSetupDepends
                        . setupBuildInfo . elabPkgDescription

-- | Test the behaviour with and without @--keep-going@
--
testBuildKeepGoing :: ProjectConfig -> Assertion
testBuildKeepGoing config = do
    -- P is expected to fail, Q does not depend on P but without
    -- parallel build and without keep-going then we don't build Q yet.
    (plan1, res1) <- executePlan =<< planProject testdir (config `mappend` keepGoing False)
    (_, failure1) <- expectPackageFailed plan1 res1 "p-0.1"
    expectBuildFailed failure1
    _ <- expectPackageConfigured plan1 res1 "q-0.1"

    -- With keep-going then we should go on to successfully build Q
    (plan2, res2) <- executePlan
                 =<< planProject testdir (config `mappend` keepGoing True)
    (_, failure2) <- expectPackageFailed plan2 res2 "p-0.1"
    expectBuildFailed failure2
    _ <- expectPackageInstalled plan2 res2 "q-0.1"
    return ()
  where
    testdir = "build/keep-going"
    keepGoing kg =
      mempty {
        projectConfigBuildOnly = mempty {
          projectConfigKeepGoing = toFlag kg
        }
      }

-- | Test we can successfully build packages from local tarball files.
--
testBuildLocalTarball :: ProjectConfig -> Assertion
testBuildLocalTarball config = do
    -- P is a tarball package, Q is a local dir package that depends on it.
    (plan, res) <- executePlan =<< planProject testdir config
    _ <- expectPackageInstalled plan res "p-0.1"
    _ <- expectPackageInstalled plan res "q-0.1"
    return ()
  where
    testdir = "build/local-tarball"

-- | See <https://github.com/haskell/cabal/issues/3324>
--
-- This test just doesn't seem to work on Windows,
-- due filesystem woes.
--
testRegressionIssue3324 :: ProjectConfig -> Assertion
testRegressionIssue3324 config = when (buildOS /= Windows) $ do
    -- expected failure first time due to missing dep
    (plan1, res1) <- executePlan =<< planProject testdir config
    (_pkgq, failure) <- expectPackageFailed plan1 res1 "q-0.1"
    expectBuildFailed failure

    -- add the missing dep, now it should work
    let qcabal  = basedir </> testdir </> "q" </> "q.cabal"
    withFileFinallyRestore qcabal $ do
      tryFewTimes $ BS.appendFile qcabal ("  build-depends: p\n")
      (plan2, res2) <- executePlan =<< planProject testdir config
      _ <- expectPackageInstalled plan2 res2 "p-0.1"
      _ <- expectPackageInstalled plan2 res2 "q-0.1"
      return ()
  where
    testdir = "regression/3324"


---------------------------------
-- Test utils to plan and build
--

basedir :: FilePath
basedir = "tests" </> "IntegrationTests2"

dirActions :: FilePath -> TS.DirActions IO
dirActions testdir =
    defaultDirActions {
      TS.doesFileExist       = \p ->
        TS.doesFileExist defaultDirActions (virtcwd </> p),

      TS.doesDirectoryExist  = \p ->
        TS.doesDirectoryExist defaultDirActions (virtcwd </> p),

      TS.canonicalizePath    = \p ->
        TS.canonicalizePath defaultDirActions (virtcwd </> p),

      TS.getCurrentDirectory =
        TS.canonicalizePath defaultDirActions virtcwd
    }
  where
    virtcwd = basedir </> testdir

type ProjDetails = (DistDirLayout,
                    CabalDirLayout,
                    ProjectConfig,
                    [PackageSpecifier UnresolvedSourcePackage],
                    BuildTimeSettings)

configureProject :: FilePath -> ProjectConfig -> IO ProjDetails
configureProject testdir cliConfig = do
    cabalDir <- getCabalDir
    let cabalDirLayout = defaultCabalDirLayout cabalDir

    projectRootDir <- canonicalizePath (basedir </> testdir)
    isexplict      <- doesFileExist (projectRootDir </> "cabal.project")
    let projectRoot
          | isexplict = ProjectRootExplicit projectRootDir
                                           (projectRootDir </> "cabal.project")
          | otherwise = ProjectRootImplicit projectRootDir
        distDirLayout = defaultDistDirLayout projectRoot Nothing

    -- Clear state between test runs. The state remains if the previous run
    -- ended in an exception (as we leave the files to help with debugging).
    cleanProject testdir

    (projectConfig, localPackages) <-
      rebuildProjectConfig verbosity
                           distDirLayout
                           cliConfig

    let buildSettings = resolveBuildTimeSettings
                          verbosity cabalDirLayout
                          projectConfig

    return (distDirLayout,
            cabalDirLayout,
            projectConfig,
            localPackages,
            buildSettings)

type PlanDetails = (ProjDetails,
                    ElaboratedInstallPlan,
                    ElaboratedSharedConfig)

planProject :: FilePath -> ProjectConfig -> IO PlanDetails
planProject testdir cliConfig = do

    projDetails@
      (distDirLayout,
       cabalDirLayout,
       projectConfig,
       localPackages,
       _buildSettings) <- configureProject testdir cliConfig

    (elaboratedPlan, _, elaboratedShared, _, _) <-
      rebuildInstallPlan verbosity
                         distDirLayout cabalDirLayout
                         projectConfig
                         localPackages

    return (projDetails,
            elaboratedPlan,
            elaboratedShared)

executePlan :: PlanDetails -> IO (ElaboratedInstallPlan, BuildOutcomes)
executePlan ((distDirLayout, cabalDirLayout, _, _, buildSettings),
             elaboratedPlan,
             elaboratedShared) = do

    let targets :: Map.Map UnitId [ComponentTarget]
        targets =
          Map.fromList
            [ (unitid, [ComponentTarget cname WholeComponent])
            | ts <- Map.elems (availableTargets elaboratedPlan)
            , AvailableTarget {
                availableTargetStatus = TargetBuildable (unitid, cname) _
              } <- ts
            ]
        elaboratedPlan' = pruneInstallPlanToTargets
                            TargetActionBuild targets
                            elaboratedPlan

    pkgsBuildStatus <-
      rebuildTargetsDryRun distDirLayout elaboratedShared
                           elaboratedPlan'

    let elaboratedPlan'' = improveInstallPlanWithUpToDatePackages
                             pkgsBuildStatus elaboratedPlan'

    buildOutcomes <-
      rebuildTargets verbosity
                     distDirLayout
                     (cabalStoreDirLayout cabalDirLayout)
                     elaboratedPlan''
                     elaboratedShared
                     pkgsBuildStatus
                     -- Avoid trying to use act-as-setup mode:
                     buildSettings { buildSettingNumJobs = 1 }

    return (elaboratedPlan'', buildOutcomes)

cleanProject :: FilePath -> IO ()
cleanProject testdir = do
    alreadyExists <- doesDirectoryExist distDir
    when alreadyExists $ removePathForcibly distDir
  where
    projectRoot    = ProjectRootImplicit (basedir </> testdir)
    distDirLayout  = defaultDistDirLayout projectRoot Nothing
    distDir        = distDirectory distDirLayout


verbosity :: Verbosity
verbosity = minBound --normal --verbose --maxBound --minBound



-------------------------------------------
-- Tasty integration to adjust the config
--

withProjectConfig :: (ProjectConfig -> TestTree) -> TestTree
withProjectConfig testtree =
    askOption $ \ghcPath ->
      testtree (mkProjectConfig ghcPath)

mkProjectConfig :: GhcPath -> ProjectConfig
mkProjectConfig (GhcPath ghcPath) =
    mempty {
      projectConfigShared = mempty {
        projectConfigHcPath = maybeToFlag ghcPath
      },
     projectConfigBuildOnly = mempty {
       projectConfigNumJobs = toFlag (Just 1)
     }
    }
  where
    maybeToFlag = maybe mempty toFlag


data GhcPath = GhcPath (Maybe FilePath)
  deriving Typeable

instance IsOption GhcPath where
  defaultValue = GhcPath Nothing
  optionName   = Tagged "with-ghc"
  optionHelp   = Tagged "The ghc compiler to use"
  parseValue   = Just . GhcPath . Just

projectConfigOptionDescriptions :: [OptionDescription]
projectConfigOptionDescriptions = [Option (Proxy :: Proxy GhcPath)]


---------------------------------------
-- HUint style utils for this context
--

expectException :: Exception e => String -> IO a -> IO e
expectException expected action = do
    res <- try action
    case res of
      Left  e -> return e
      Right _ -> throwIO $ HUnitFailure Nothing $ "expected an exception " ++ expected

expectPackagePreExisting :: ElaboratedInstallPlan -> BuildOutcomes -> PackageId
                         -> IO InstalledPackageInfo
expectPackagePreExisting plan buildOutcomes pkgid = do
    planpkg <- expectPlanPackage plan pkgid
    case (planpkg, InstallPlan.lookupBuildOutcome planpkg buildOutcomes) of
      (InstallPlan.PreExisting pkg, Nothing)
                       -> return pkg
      (_, buildResult) -> unexpectedBuildResult "PreExisting" planpkg buildResult

expectPackageConfigured :: ElaboratedInstallPlan -> BuildOutcomes -> PackageId
                        -> IO ElaboratedConfiguredPackage
expectPackageConfigured plan buildOutcomes pkgid = do
    planpkg <- expectPlanPackage plan pkgid
    case (planpkg, InstallPlan.lookupBuildOutcome planpkg buildOutcomes) of
      (InstallPlan.Configured pkg, Nothing)
                       -> return pkg
      (_, buildResult) -> unexpectedBuildResult "Configured" planpkg buildResult

expectPackageInstalled :: ElaboratedInstallPlan -> BuildOutcomes -> PackageId
                       -> IO ElaboratedConfiguredPackage
expectPackageInstalled plan buildOutcomes pkgid = do
    planpkg <- expectPlanPackage plan pkgid
    case (planpkg, InstallPlan.lookupBuildOutcome planpkg buildOutcomes) of
      (InstallPlan.Configured pkg, Just (Right _result)) -- result isn't used by any test
                       -> return pkg
      -- package can be installed in the global .store!
      -- (when installing from tarball!)
      (InstallPlan.Installed pkg, Nothing)
                       -> return pkg
      (_, buildResult) -> unexpectedBuildResult "Installed" planpkg buildResult

expectPackageFailed :: ElaboratedInstallPlan -> BuildOutcomes -> PackageId
                    -> IO (ElaboratedConfiguredPackage, BuildFailure)
expectPackageFailed plan buildOutcomes pkgid = do
    planpkg <- expectPlanPackage plan pkgid
    case (planpkg, InstallPlan.lookupBuildOutcome planpkg buildOutcomes) of
      (InstallPlan.Configured pkg, Just (Left failure))
                       -> return (pkg, failure)
      (_, buildResult) -> unexpectedBuildResult "Failed" planpkg buildResult

unexpectedBuildResult :: String -> ElaboratedPlanPackage
                      -> Maybe (Either BuildFailure BuildResult) -> IO a
unexpectedBuildResult expected planpkg buildResult =
    throwIO $ HUnitFailure Nothing $
         "expected to find " ++ display (packageId planpkg) ++ " in the "
      ++ expected ++ " state, but it is actually in the " ++ actual ++ " state."
  where
    actual = case (buildResult, planpkg) of
      (Nothing, InstallPlan.PreExisting{})       -> "PreExisting"
      (Nothing, InstallPlan.Configured{})        -> "Configured"
      (Just (Right _), InstallPlan.Configured{}) -> "Installed"
      (Just (Left  _), InstallPlan.Configured{}) -> "Failed"
      (Nothing, InstallPlan.Installed{})         -> "Installed globally"
      _                                          -> "Impossible! " ++ show buildResult ++ show planpkg

expectPlanPackage :: ElaboratedInstallPlan -> PackageId
                  -> IO ElaboratedPlanPackage
expectPlanPackage plan pkgid =
    case [ pkg
         | pkg <- InstallPlan.toList plan
         , packageId pkg == pkgid ] of
      [pkg] -> return pkg
      []    -> throwIO $ HUnitFailure Nothing $
                   "expected to find " ++ display pkgid
                ++ " in the install plan but it's not there"
      _     -> throwIO $ HUnitFailure Nothing $
                   "expected to find only one instance of " ++ display pkgid
                ++ " in the install plan but there's several"

expectBuildFailed :: BuildFailure -> IO ()
expectBuildFailed (BuildFailure _ (BuildFailed _)) = return ()
expectBuildFailed (BuildFailure _ reason) =
    assertFailure $ "expected BuildFailed, got " ++ show reason

---------------------------------------
-- Other utils
--

-- | Allow altering a file during a test, but then restore it afterwards
--
-- We read into the memory, as filesystems are tricky. (especially Windows)
--
withFileFinallyRestore :: FilePath -> IO a -> IO a
withFileFinallyRestore file action = do
    originalContents <- BS.readFile file
    action `finally` handle onIOError (tryFewTimes $ BS.writeFile file originalContents)
  where
    onIOError :: IOException -> IO ()
    onIOError e = putStrLn $ "WARNING: Cannot restore " ++ file ++ "; " ++ show e

-- Hopefully works around some Windows file-locking things.
-- Use with care:
--
-- Try action 4 times, with small sleep in between,
-- retrying if it fails for 'IOException' reason.
--
tryFewTimes :: forall a. IO a -> IO a
tryFewTimes action = go (3 :: Int) where
    go :: Int -> IO a
    go !n | n <= 0    = action
          | otherwise = action `catch` onIOError n

    onIOError :: Int -> IOException -> IO a
    onIOError n e = do
        hPutStrLn stderr $ "Trying " ++ show n ++ " after " ++ show e
        threadDelay 10000
        go (n - 1)
