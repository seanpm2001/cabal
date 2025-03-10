-- -fno-warn-deprecations for use of Map.foldWithKey
{-# OPTIONS_GHC -fno-warn-deprecations #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PackageDescription.Configuration
-- Copyright   :  Thomas Schilling, 2007
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This is about the cabal configurations feature. It exports
-- 'finalizePD' and 'flattenPackageDescription' which are
-- functions for converting 'GenericPackageDescription's down to
-- 'PackageDescription's. It has code for working with the tree of conditions
-- and resolving or flattening conditions.

module Distribution.PackageDescription.Configuration (
    finalizePD,
    flattenPackageDescription,

    -- Utils
    parseCondition,
    freeVars,
    extractCondition,
    extractConditions,
    addBuildableCondition,
    mapCondTree,
    mapTreeData,
    mapTreeConds,
    mapTreeConstrs,
    transformAllBuildInfos,
    transformAllBuildDepends,
    transformAllBuildDependsN,
  ) where

import Distribution.Compat.Prelude
import Prelude ()

-- lens
import qualified Distribution.Types.BuildInfo.Lens                 as L
import qualified Distribution.Types.GenericPackageDescription.Lens as L
import qualified Distribution.Types.PackageDescription.Lens        as L
import qualified Distribution.Types.SetupBuildInfo.Lens            as L

import           Distribution.Compat.CharParsing             hiding (char)
import qualified Distribution.Compat.CharParsing             as P
import           Distribution.Compat.Lens
import           Distribution.Compiler
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Utils
import           Distribution.Parsec
import           Distribution.Pretty
import           Distribution.System
import           Distribution.Types.Component
import Distribution.Utils.Path
import           Distribution.Types.ComponentRequestedSpec
import           Distribution.Types.DependencyMap
import           Distribution.Types.PackageVersionConstraint
import           Distribution.Utils.Generic
import           Distribution.Version

import qualified Data.Map.Lazy as Map
import           Data.Tree     (Tree (Node))

------------------------------------------------------------------------------

-- | Simplify a configuration condition using the OS and arch names.  Returns
--   the names of all the flags occurring in the condition.
simplifyWithSysParams :: OS -> Arch -> CompilerInfo -> Condition ConfVar
                      -> (Condition FlagName, [FlagName])
simplifyWithSysParams os arch cinfo cond = (cond', flags)
  where
    (cond', flags) = simplifyCondition cond interp
    interp (OS os')    = Right $ os' == os
    interp (Arch arch') = Right $ arch' == arch
    interp (Impl comp vr)
      | matchImpl (compilerInfoId cinfo) = Right True
      | otherwise = case compilerInfoCompat cinfo of
          -- fixme: treat Nothing as unknown, rather than empty list once we
          --        support partial resolution of system parameters
          Nothing     -> Right False
          Just compat -> Right (any matchImpl compat)
          where
            matchImpl (CompilerId c v) = comp == c && v `withinRange` vr
    interp (PackageFlag f) = Left f

-- TODO: Add instances and check
--
-- prop_sC_idempotent cond a o = cond' == cond''
--   where
--     cond'  = simplifyCondition cond a o
--     cond'' = simplifyCondition cond' a o
--
-- prop_sC_noLits cond a o = isLit res || not (hasLits res)
--   where
--     res = simplifyCondition cond a o
--     hasLits (Lit _) = True
--     hasLits (CNot c) = hasLits c
--     hasLits (COr l r) = hasLits l || hasLits r
--     hasLits (CAnd l r) = hasLits l || hasLits r
--     hasLits _ = False
--

-- | Parse a configuration condition from a string.
parseCondition :: CabalParsing m => m (Condition ConfVar)
parseCondition = condOr
  where
    condOr   = sepByNonEmpty condAnd (oper "||") >>= return . foldl1 COr
    condAnd  = sepByNonEmpty cond (oper "&&")>>= return . foldl1 CAnd
    -- TODO: try?
    cond     = sp >> (boolLiteral <|> inparens condOr <|> notCond <|> osCond
                      <|> archCond <|> flagCond <|> implCond )
    inparens   = between (P.char '(' >> sp) (sp >> P.char ')' >> sp)
    notCond  = P.char '!' >> sp >> cond >>= return . CNot
    osCond   = string "os" >> sp >> inparens osIdent >>= return . Var
    archCond = string "arch" >> sp >> inparens archIdent >>= return . Var
    flagCond = string "flag" >> sp >> inparens flagIdent >>= return . Var
    implCond = string "impl" >> sp >> inparens implIdent >>= return . Var
    boolLiteral   = fmap Lit  parsec
    archIdent     = fmap Arch parsec
    osIdent       = fmap OS   parsec
    flagIdent     = fmap (PackageFlag . mkFlagName . lowercase) (munch1 isIdentChar)
    isIdentChar c = isAlphaNum c || c == '_' || c == '-'
    oper s        = sp >> string s >> sp
    sp            = spaces
    implIdent     = do i <- parsec
                       vr <- sp >> option anyVersion parsec
                       return $ Impl i vr

------------------------------------------------------------------------------

-- | Result of dependency test. Isomorphic to @Maybe d@ but renamed for
--   clarity.
data DepTestRslt d = DepOk | MissingDeps d

instance Semigroup d => Monoid (DepTestRslt d) where
    mempty = DepOk
    mappend = (<>)

instance Semigroup d => Semigroup (DepTestRslt d) where
    DepOk <> x     = x
    x     <> DepOk = x
    (MissingDeps d) <> (MissingDeps d') = MissingDeps (d <> d')


-- | Try to find a flag assignment that satisfies the constraints of all trees.
--
-- Returns either the missing dependencies, or a tuple containing the
-- resulting data, the associated dependencies, and the chosen flag
-- assignments.
--
-- In case of failure, the union of the dependencies that led to backtracking
-- on all branches is returned.
-- [TODO: Could also be specified with a function argument.]
--
-- TODO: The current algorithm is rather naive.  A better approach would be to:
--
-- * Rule out possible paths, by taking a look at the associated dependencies.
--
-- * Infer the required values for the conditions of these paths, and
--   calculate the required domains for the variables used in these
--   conditions.  Then picking a flag assignment would be linear (I guess).
--
-- This would require some sort of SAT solving, though, thus it's not
-- implemented unless we really need it.
--
resolveWithFlags ::
     [(FlagName,[Bool])]
        -- ^ Domain for each flag name, will be tested in order.
  -> ComponentRequestedSpec
  -> OS      -- ^ OS where the installed artifacts will run (host OS)
  -> Arch    -- ^ Arch where the installed artifacts will run (host Arch)
  -> CompilerInfo  -- ^ Compiler information
  -> [PackageVersionConstraint]  -- ^ Additional constraints
  -> [CondTree ConfVar [Dependency] PDTagged]
  -> ([Dependency] -> DepTestRslt [Dependency])  -- ^ Dependency test function.
  -> Either [Dependency] (TargetSet PDTagged, FlagAssignment)
       -- ^ Either the missing dependencies (error case), or a pair of
       -- (set of build targets with dependencies, chosen flag assignments)
resolveWithFlags dom enabled os arch impl constrs trees checkDeps =
    either (Left . fromDepMapUnion) Right $ explore (build mempty dom)
  where
    -- simplify trees by (partially) evaluating all conditions and converting
    -- dependencies to dependency maps.
    simplifiedTrees :: [CondTree FlagName DependencyMap PDTagged]
    simplifiedTrees = map ( mapTreeConstrs toDepMap  -- convert to maps
                          . addBuildableConditionPDTagged
                          . mapTreeConds (fst . simplifyWithSysParams os arch impl))
                          trees

    -- @explore@ searches a tree of assignments, backtracking whenever a flag
    -- introduces a dependency that cannot be satisfied.  If there is no
    -- solution, @explore@ returns the union of all dependencies that caused
    -- it to backtrack.  Since the tree is constructed lazily, we avoid some
    -- computation overhead in the successful case.
    explore :: Tree FlagAssignment
            -> Either DepMapUnion (TargetSet PDTagged, FlagAssignment)
    explore (Node flags ts) =
        let targetSet = TargetSet $ flip map simplifiedTrees $
                -- apply additional constraints to all dependencies
                first (`constrainBy` constrs) .
                simplifyCondTree (env flags)
            deps = overallDependencies enabled targetSet
        in case checkDeps (fromDepMap deps) of
             DepOk | null ts   -> Right (targetSet, flags)
                   | otherwise -> tryAll $ map explore ts
             MissingDeps mds   -> Left (toDepMapUnion mds)

    -- Builds a tree of all possible flag assignments.  Internal nodes
    -- have only partial assignments.
    build :: FlagAssignment -> [(FlagName, [Bool])] -> Tree FlagAssignment
    build assigned [] = Node assigned []
    build assigned ((fn, vals) : unassigned) =
        Node assigned $ map (\v -> build (insertFlagAssignment fn v assigned) unassigned) vals

    tryAll :: [Either DepMapUnion a] -> Either DepMapUnion a
    tryAll = foldr mp mz

    -- special version of `mplus' for our local purposes
    mp :: Either DepMapUnion a -> Either DepMapUnion a -> Either DepMapUnion a
    mp m@(Right _) _           = m
    mp _           m@(Right _) = m
    mp (Left xs)   (Left ys)   = Left (xs <> ys)

    -- `mzero'
    mz :: Either DepMapUnion a
    mz = Left (DepMapUnion Map.empty)

    env :: FlagAssignment -> FlagName -> Either FlagName Bool
    env flags flag = (maybe (Left flag) Right . lookupFlagAssignment flag) flags

-- | Transforms a 'CondTree' by putting the input under the "then" branch of a
-- conditional that is True when Buildable is True. If 'addBuildableCondition'
-- can determine that Buildable is always True, it returns the input unchanged.
-- If Buildable is always False, it returns the empty 'CondTree'.
addBuildableCondition :: (Eq v, Monoid a, Monoid c) => (a -> BuildInfo)
                      -> CondTree v c a
                      -> CondTree v c a
addBuildableCondition getInfo t =
  case extractCondition (buildable . getInfo) t of
    Lit True  -> t
    Lit False -> CondNode mempty mempty []
    c         -> CondNode mempty mempty [condIfThen c t]

-- | This is a special version of 'addBuildableCondition' for the 'PDTagged'
-- type.
--
-- It is not simply a specialisation. It is more complicated than it
-- ought to be because of the way the 'PDTagged' monoid instance works. The
-- @mempty = 'PDNull'@ forgets the component type, which has the effect of
-- completely deleting components that are not buildable.
--
-- See <https://github.com/haskell/cabal/pull/4094> for more details.
--
addBuildableConditionPDTagged :: (Eq v, Monoid c) =>
                                 CondTree v c PDTagged
                              -> CondTree v c PDTagged
addBuildableConditionPDTagged t =
    case extractCondition (buildable . getInfo) t of
      Lit True  -> t
      Lit False -> deleteConstraints t
      c         -> CondNode mempty mempty [condIfThenElse c t (deleteConstraints t)]
  where
    deleteConstraints = mapTreeConstrs (const mempty)

    getInfo :: PDTagged -> BuildInfo
    getInfo (Lib l) = libBuildInfo l
    getInfo (SubComp _ c) = componentBuildInfo c
    getInfo PDNull = mempty


-- Note: extracting buildable conditions.
-- --------------------------------------
--
-- If the conditions in a cond tree lead to Buildable being set to False, then
-- none of the dependencies for this cond tree should actually be taken into
-- account. On the other hand, some of the flags may only be decided in the
-- solver, so we cannot necessarily make the decision whether a component is
-- Buildable or not prior to solving.
--
-- What we are doing here is to partially evaluate a condition tree in order to
-- extract the condition under which Buildable is True. The predicate determines
-- whether data under a 'CondTree' is buildable.

-- | Extract conditions matched by the given predicate from all cond trees in a
-- 'GenericPackageDescription'.
extractConditions :: (BuildInfo -> Bool) -> GenericPackageDescription
                     -> [Condition ConfVar]
extractConditions f gpkg =
  concat [
      extractCondition (f . libBuildInfo)             <$> maybeToList (condLibrary gpkg)
    , extractCondition (f . libBuildInfo)       . snd <$> condSubLibraries   gpkg
    , extractCondition (f . buildInfo)          . snd <$> condExecutables gpkg
    , extractCondition (f . testBuildInfo)      . snd <$> condTestSuites  gpkg
    , extractCondition (f . benchmarkBuildInfo) . snd <$> condBenchmarks  gpkg
    ]


-- | A map of package constraints that combines version ranges using 'unionVersionRanges'.
newtype DepMapUnion = DepMapUnion { unDepMapUnion :: Map PackageName (VersionRange, NonEmptySet LibraryName) }

instance Semigroup DepMapUnion where
    DepMapUnion x <> DepMapUnion y = DepMapUnion $
        Map.unionWith unionVersionRanges' x y

unionVersionRanges'
    :: (VersionRange, NonEmptySet LibraryName)
    -> (VersionRange, NonEmptySet LibraryName)
    -> (VersionRange, NonEmptySet LibraryName)
unionVersionRanges' (vr, cs) (vr', cs') = (unionVersionRanges vr vr', cs <> cs')

toDepMapUnion :: [Dependency] -> DepMapUnion
toDepMapUnion ds =
  DepMapUnion $ Map.fromListWith unionVersionRanges' [ (p,(vr,cs)) | Dependency p vr cs <- ds ]


fromDepMapUnion :: DepMapUnion -> [Dependency]
fromDepMapUnion m = [ Dependency p vr cs | (p,(vr,cs)) <- Map.toList (unDepMapUnion m) ]

freeVars :: CondTree ConfVar c a  -> [FlagName]
freeVars t = [ f | PackageFlag f <- freeVars' t ]
  where
    freeVars' (CondNode _ _ ifs) = concatMap compfv ifs
    compfv (CondBranch c ct mct) = condfv c ++ freeVars' ct ++ maybe [] freeVars' mct
    condfv c = case c of
      Var v      -> [v]
      Lit _      -> []
      CNot c'    -> condfv c'
      COr c1 c2  -> condfv c1 ++ condfv c2
      CAnd c1 c2 -> condfv c1 ++ condfv c2


------------------------------------------------------------------------------

-- | A set of targets with their package dependencies
newtype TargetSet a = TargetSet [(DependencyMap, a)]

-- | Combine the target-specific dependencies in a TargetSet to give the
-- dependencies for the package as a whole.
overallDependencies :: ComponentRequestedSpec -> TargetSet PDTagged -> DependencyMap
overallDependencies enabled (TargetSet targets) = mconcat depss
  where
    (depss, _) = unzip $ filter (removeDisabledSections . snd) targets
    removeDisabledSections :: PDTagged -> Bool
    -- UGH. The embedded componentName in the 'Component's here is
    -- BLANK.  I don't know whose fault this is but I'll use the tag
    -- instead. -- ezyang
    removeDisabledSections (Lib _)     = componentNameRequested
                                           enabled
                                           (CLibName LMainLibName)
    removeDisabledSections (SubComp t c)
        -- Do NOT use componentName
        = componentNameRequested enabled
        $ case c of
            CLib  _ -> CLibName (LSubLibName t)
            CFLib _ -> CFLibName   t
            CExe  _ -> CExeName    t
            CTest _ -> CTestName   t
            CBench _ -> CBenchName t
    removeDisabledSections PDNull      = True

-- | Collect up the targets in a TargetSet of tagged targets, storing the
-- dependencies as we go.
flattenTaggedTargets :: TargetSet PDTagged -> (Maybe Library, [(UnqualComponentName, Component)])
flattenTaggedTargets (TargetSet targets) = foldr untag (Nothing, []) targets where
  untag (depMap, pdTagged) accum = case (pdTagged, accum) of
    (Lib _, (Just _, _)) -> userBug "Only one library expected"
    (Lib l, (Nothing, comps)) -> (Just $ redoBD l, comps)
    (SubComp n c, (mb_lib, comps))
      | any ((== n) . fst) comps ->
        userBug $ "There exist several components with the same name: '" ++ prettyShow n ++ "'"
      | otherwise -> (mb_lib, (n, redoBD c) : comps)
    (PDNull, x) -> x  -- actually this should not happen, but let's be liberal
    where
      redoBD :: L.HasBuildInfo a => a -> a
      redoBD = set L.targetBuildDepends $ fromDepMap depMap

------------------------------------------------------------------------------
-- Convert GenericPackageDescription to PackageDescription
--

data PDTagged = Lib Library
              | SubComp UnqualComponentName Component
              | PDNull
              deriving Show

instance Monoid PDTagged where
    mempty = PDNull
    mappend = (<>)

instance Semigroup PDTagged where
    PDNull    <> x      = x
    x         <> PDNull = x
    Lib l     <> Lib l' = Lib (l <> l')
    SubComp n x <> SubComp n' x' | n == n' = SubComp n (x <> x')
    _         <> _  = cabalBug "Cannot combine incompatible tags"

-- | Create a package description with all configurations resolved.
--
-- This function takes a `GenericPackageDescription` and several environment
-- parameters and tries to generate `PackageDescription` by finding a flag
-- assignment that result in satisfiable dependencies.
--
-- It takes as inputs a not necessarily complete specifications of flags
-- assignments, an optional package index as well as platform parameters.  If
-- some flags are not assigned explicitly, this function will try to pick an
-- assignment that causes this function to succeed.  The package index is
-- optional since on some platforms we cannot determine which packages have
-- been installed before.  When no package index is supplied, every dependency
-- is assumed to be satisfiable, therefore all not explicitly assigned flags
-- will get their default values.
--
-- This function will fail if it cannot find a flag assignment that leads to
-- satisfiable dependencies.  (It will not try alternative assignments for
-- explicitly specified flags.)  In case of failure it will return the missing
-- dependencies that it encountered when trying different flag assignments.
-- On success, it will return the package description and the full flag
-- assignment chosen.
--
-- Note that this drops any stanzas which have @buildable: False@.  While
-- this is arguably the right thing to do, it means we give bad error
-- messages in some situations, see #3858.
--
finalizePD ::
     FlagAssignment  -- ^ Explicitly specified flag assignments
  -> ComponentRequestedSpec
  -> (Dependency -> Bool) -- ^ Is a given dependency satisfiable from the set of
                          -- available packages?  If this is unknown then use
                          -- True.
  -> Platform      -- ^ The 'Arch' and 'OS'
  -> CompilerInfo  -- ^ Compiler information
  -> [PackageVersionConstraint]  -- ^ Additional constraints
  -> GenericPackageDescription
  -> Either [Dependency]
            (PackageDescription, FlagAssignment)
             -- ^ Either missing dependencies or the resolved package
             -- description along with the flag assignments chosen.
finalizePD userflags enabled satisfyDep
        (Platform arch os) impl constraints
        (GenericPackageDescription pkg _ver flags mb_lib0 sub_libs0 flibs0 exes0 tests0 bms0) = do
  (targetSet, flagVals) <-
    resolveWithFlags flagChoices enabled os arch impl constraints condTrees check
  let
    (mb_lib, comps) = flattenTaggedTargets targetSet
    mb_lib' = fmap libFillInDefaults mb_lib
    comps' = flip map comps $ \(n,c) -> foldComponent
      (\l -> CLib   (libFillInDefaults l)   { libName = LSubLibName n
                                            , libExposed = False })
      (\l -> CFLib  (flibFillInDefaults l)  { foreignLibName = n })
      (\e -> CExe   (exeFillInDefaults e)   { exeName = n })
      (\t -> CTest  (testFillInDefaults t)  { testName = n })
      (\b -> CBench (benchFillInDefaults b) { benchmarkName = n })
      c
    (sub_libs', flibs', exes', tests', bms') = partitionComponents comps'
  return ( pkg { library = mb_lib'
               , subLibraries = sub_libs'
               , foreignLibs = flibs'
               , executables = exes'
               , testSuites = tests'
               , benchmarks = bms'
               }
         , flagVals )
  where
    -- Combine lib, exes, and tests into one list of @CondTree@s with tagged data
    condTrees =    maybeToList (fmap (mapTreeData Lib) mb_lib0)
                ++ map (\(name,tree) -> mapTreeData (SubComp name . CLib) tree) sub_libs0
                ++ map (\(name,tree) -> mapTreeData (SubComp name . CFLib) tree) flibs0
                ++ map (\(name,tree) -> mapTreeData (SubComp name . CExe) tree) exes0
                ++ map (\(name,tree) -> mapTreeData (SubComp name . CTest) tree) tests0
                ++ map (\(name,tree) -> mapTreeData (SubComp name . CBench) tree) bms0

    flagChoices    = map (\(MkPackageFlag n _ d manual) -> (n, d2c manual n d)) flags
    d2c manual n b = case lookupFlagAssignment n userflags of
                     Just val -> [val]
                     Nothing
                      | manual -> [b]
                      | otherwise -> [b, not b]
    --flagDefaults = map (\(n,x:_) -> (n,x)) flagChoices
    check ds     = let missingDeps = filter (not . satisfyDep) ds
                   in if null missingDeps
                      then DepOk
                      else MissingDeps missingDeps

{-
let tst_p = (CondNode [1::Int] [Distribution.Package.Dependency "a" AnyVersion] [])
let tst_p2 = (CondNode [1::Int] [Distribution.Package.Dependency "a" (EarlierVersion (Version [1,0] [])), Distribution.Package.Dependency "a" (LaterVersion (Version [2,0] []))] [])

let p_index = Distribution.Simple.PackageIndex.fromList [Distribution.Package.PackageIdentifier "a" (Version [0,5] []), Distribution.Package.PackageIdentifier "a" (Version [2,5] [])]
let look = not . null . Distribution.Simple.PackageIndex.lookupDependency p_index
let looks ds = mconcat $ map (\d -> if look d then DepOk else MissingDeps [d]) ds
resolveWithFlags [] Distribution.System.Linux Distribution.System.I386 (Distribution.Compiler.GHC,Version [6,8,2] []) [tst_p] looks   ===>  Right ...
resolveWithFlags [] Distribution.System.Linux Distribution.System.I386 (Distribution.Compiler.GHC,Version [6,8,2] []) [tst_p2] looks  ===>  Left ...
-}

-- | Flatten a generic package description by ignoring all conditions and just
-- join the field descriptors into on package description.  Note, however,
-- that this may lead to inconsistent field values, since all values are
-- joined into one field, which may not be possible in the original package
-- description, due to the use of exclusive choices (if ... else ...).
--
-- TODO: One particularly tricky case is defaulting.  In the original package
-- description, e.g., the source directory might either be the default or a
-- certain, explicitly set path.  Since defaults are filled in only after the
-- package has been resolved and when no explicit value has been set, the
-- default path will be missing from the package description returned by this
-- function.
flattenPackageDescription :: GenericPackageDescription -> PackageDescription
flattenPackageDescription
  (GenericPackageDescription pkg _ _ mlib0 sub_libs0 flibs0 exes0 tests0 bms0) =
    pkg { library      = mlib
        , subLibraries = reverse sub_libs
        , foreignLibs  = reverse flibs
        , executables  = reverse exes
        , testSuites   = reverse tests
        , benchmarks   = reverse bms
        }
  where
    mlib = f <$> mlib0
      where f lib = (libFillInDefaults . fst . ignoreConditions $ lib) { libName = LMainLibName }
    sub_libs = flattenLib  <$> sub_libs0
    flibs    = flattenFLib <$> flibs0
    exes     = flattenExe  <$> exes0
    tests    = flattenTst  <$> tests0
    bms      = flattenBm   <$> bms0
    flattenLib (n, t) = libFillInDefaults $ (fst $ ignoreConditions t)
      { libName = LSubLibName n, libExposed = False }
    flattenFLib (n, t) = flibFillInDefaults $ (fst $ ignoreConditions t)
      { foreignLibName = n }
    flattenExe (n, t) = exeFillInDefaults $ (fst $ ignoreConditions t)
      { exeName = n }
    flattenTst (n, t) = testFillInDefaults $ (fst $ ignoreConditions t)
      { testName = n }
    flattenBm (n, t) = benchFillInDefaults $ (fst $ ignoreConditions t)
      { benchmarkName = n }

-- This is in fact rather a hack.  The original version just overrode the
-- default values, however, when adding conditions we had to switch to a
-- modifier-based approach.  There, nothing is ever overwritten, but only
-- joined together.
--
-- This is the cleanest way i could think of, that doesn't require
-- changing all field parsing functions to return modifiers instead.
libFillInDefaults :: Library -> Library
libFillInDefaults lib@(Library { libBuildInfo = bi }) =
    lib { libBuildInfo = biFillInDefaults bi }

flibFillInDefaults :: ForeignLib -> ForeignLib
flibFillInDefaults flib@(ForeignLib { foreignLibBuildInfo = bi }) =
    flib { foreignLibBuildInfo = biFillInDefaults bi }

exeFillInDefaults :: Executable -> Executable
exeFillInDefaults exe@(Executable { buildInfo = bi }) =
    exe { buildInfo = biFillInDefaults bi }

testFillInDefaults :: TestSuite -> TestSuite
testFillInDefaults tst@(TestSuite { testBuildInfo = bi }) =
    tst { testBuildInfo = biFillInDefaults bi }

benchFillInDefaults :: Benchmark -> Benchmark
benchFillInDefaults bm@(Benchmark { benchmarkBuildInfo = bi }) =
    bm { benchmarkBuildInfo = biFillInDefaults bi }

biFillInDefaults :: BuildInfo -> BuildInfo
biFillInDefaults bi =
    if null (hsSourceDirs bi)
    then bi { hsSourceDirs = [sameDirectory] }
    else bi

-- Walk a 'GenericPackageDescription' and apply @onBuildInfo@/@onSetupBuildInfo@
-- to all nested 'BuildInfo'/'SetupBuildInfo' values.
transformAllBuildInfos :: (BuildInfo -> BuildInfo)
                       -> (SetupBuildInfo -> SetupBuildInfo)
                       -> GenericPackageDescription
                       -> GenericPackageDescription
transformAllBuildInfos onBuildInfo onSetupBuildInfo =
  over L.traverseBuildInfos onBuildInfo
  . over (L.packageDescription . L.setupBuildInfo . traverse) onSetupBuildInfo

-- | Walk a 'GenericPackageDescription' and apply @f@ to all nested
-- @build-depends@ fields.
transformAllBuildDepends :: (Dependency -> Dependency)
                         -> GenericPackageDescription
                         -> GenericPackageDescription
transformAllBuildDepends f =
  over (L.traverseBuildInfos . L.targetBuildDepends . traverse) f
  . over (L.packageDescription . L.setupBuildInfo . traverse . L.setupDepends . traverse) f
  -- cannot be point-free as normal because of higher rank
  . over (\f' -> L.allCondTrees $ traverseCondTreeC f') (map f)

-- | Walk a 'GenericPackageDescription' and apply @f@ to all nested
-- @build-depends@ fields.
transformAllBuildDependsN :: ([Dependency] -> [Dependency])
                          -> GenericPackageDescription
                          -> GenericPackageDescription
transformAllBuildDependsN f =
  over (L.traverseBuildInfos . L.targetBuildDepends) f
  . over (L.packageDescription . L.setupBuildInfo . traverse . L.setupDepends) f
  -- cannot be point-free as normal because of higher rank
  . over (\f' -> L.allCondTrees $ traverseCondTreeC f') f
