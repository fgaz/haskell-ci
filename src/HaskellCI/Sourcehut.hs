-- | Take configuration, produce 'Sourcehut'.
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module HaskellCI.Sourcehut (
    SourcehutOptions(..),
    makeSourcehut,
    sourcehutHeader,
    ) where

import HaskellCI.Prelude

import qualified Data.Map.Strict                 as M
import qualified Data.Set                        as S
import qualified Distribution.Pretty             as C
import qualified Distribution.Types.GenericPackageDescription as C
import qualified Distribution.Types.PackageDescription as C
import qualified Distribution.Types.VersionRange as C
import qualified Distribution.Utils.ShortText    as C
import System.FilePath.Posix (takeFileName)

import Cabal.Project
import HaskellCI.Auxiliary
import HaskellCI.Compiler
import HaskellCI.Config
import HaskellCI.Jobs
import HaskellCI.List
import HaskellCI.Package
import HaskellCI.Sh
import HaskellCI.Sourcehut.Yaml
import HaskellCI.VersionInfo

-------------------------------------------------------------------------------
-- Sourcehut options
-------------------------------------------------------------------------------

data SourcehutOptions src = SourcehutOptions
    { sourcehutOptPath :: FilePath
    , sourcehutOptSource :: src
    , sourcehutOptParallel :: Bool
    }
  deriving Show

-------------------------------------------------------------------------------
-- Sourcehut header
-------------------------------------------------------------------------------

sourcehutHeader :: Bool -> [String] -> [String]
sourcehutHeader insertVersion argv =
    [ "This Sourcehut job script has been generated by a script via"
    , ""
    , "  haskell-ci " ++ unwords [ "'" ++ a ++ "'" | a <- argv ]
    , ""
    , "To regenerate the script (for example after adjusting tested-with) run"
    , ""
    , "  haskell-ci regenerate"
    , ""
    , "For more information, see https://github.com/haskell-CI/haskell-ci"
    , ""
    ] ++
    verlines ++
    [ "REGENDATA " ++ if insertVersion then show (haskellCIVerStr, argv) else show argv
    , ""
    ]
  where
    verlines
        | insertVersion = [ "version: " ++ haskellCIVerStr , "" ]
        | otherwise     = []

-------------------------------------------------------------------------------
-- Generate sourcehut configuration
-------------------------------------------------------------------------------

{-
Sourcehut–specific notes:

* We don't use -j for parallelism, as machines could have different numbers of
  cores
* By default we run jobs sequentially, since on the sr.ht instance parallelism
  is limited and build machines are fast
-}

makeSourcehut
    :: [String]
    -> Config
    -> SourcehutOptions String
    -> Project URI Void Package
    -> JobVersions
    -> Either HsCiError Sourcehut
makeSourcehut _argv config@Config {..} SourcehutOptions {..} prj jobs@JobVersions {..} =
    Sourcehut <$>
        if sourcehutOptParallel
        then parallelManifests
        else M.singleton "all" <$> sequentialManifest
  where
    Auxiliary {..} = auxiliary config prj jobs

    parallelManifests :: Either HsCiError (M.Map String SourcehutManifest)
    parallelManifests = fmap (M.mapKeys dispGhcVersionShort) $
        sequence $ M.fromSet (mkManifest . S.singleton) linuxVersions

    sequentialManifest :: Either HsCiError SourcehutManifest
    sequentialManifest = mkManifest linuxVersions

    mkManifest :: Set CompilerVersion -> Either HsCiError SourcehutManifest
    mkManifest compilers = do
        prepare <- fmap (SourcehutTask "all-prepare") $ runSh $ do
            sh "export PATH=$PATH:/opt/cabal/bin"
            tell_env "PATH" "$PATH:/opt/cabal/bin"
            sh "cabal update"
        tasks <- concat <$> traverse mkTasksForGhc (S.toList compilers)
        return SourcehutManifest
            { srhtManifestImage = cfgUbuntu
            , srhtManifestPackages =
                  toList cfgApt ++
                  ( "gcc" : "cabal-install-3.4" :
                      (dispGhcVersion <$> S.toList compilers))
            , srhtManifestRepositories = M.singleton
                  "hvr-ghc"
                  ("http://ppa.launchpad.net/hvr/ghc/ubuntu " ++ C.prettyShow cfgUbuntu ++ " main ff3aeacef6f88286")
            , srhtManifestArtifacts = []
            , srhtManifestSources = [sourcehutOptSource]
            , srhtManifestTasks = prepare : tasks
            , srhtManifestTriggers = SourcehutTriggerEmail <$> getEmails prj
            , srhtManifestEnvironment = mempty
            }

    clonePath :: FilePath
    clonePath = removeSuffix ".git" $ takeFileName sourcehutOptSource

    -- MAYBE reader for job and clonePath
    mkTasksForGhc :: CompilerVersion -> Either HsCiError [SourcehutTask]
    mkTasksForGhc job = sequence $ buildList $ do
        sourcehutRun "prepare" job clonePath $
            sh $ "cabal configure -w /opt/ghc/bin/" ++ dispGhcVersion job
        sourcehutRun "check" job clonePath $
            sh "cabal check"
        when cfgInstallDeps $ sourcehutRun "dependencies" job clonePath $ do
            sh "cabal build all --enable-tests --only-dependencies"
            sh "cabal build all --only-dependencies"
        sourcehutRun "build" job clonePath $
            sh "cabal build all"
        sourcehutRun "test" job clonePath $
            sh "cabal test all --enable-tests"
        when (hasLibrary && not (equivVersionRanges C.noVersion cfgHaddock)) $ sourcehutRun "haddock" job clonePath $
            sh "cabal haddock all"

removeSuffix :: String -> String -> String
removeSuffix suffix orig =
    fromMaybe orig $ stripSuffix suffix orig
  where
    stripSuffix sf str = reverse <$> stripPrefix (reverse sf) (reverse str)

getEmails :: Project URI Void Package -> [String]
getEmails = fmap (C.fromShortText . C.maintainer . C.packageDescription . pkgGpd) . prjPackages

sourcehutRun :: String -> CompilerVersion -> FilePath -> ShM () -> ListBuilder (Either HsCiError SourcehutTask) ()
sourcehutRun name job clonePath shm = item $ do
    shs <- runSh $ do
        -- 2164: -e is set by default
        sh' [2164] $ "cd " ++ clonePath
        shm
    return $ SourcehutTask (ghcVersionTask <> "-" <> name) shs
  where ghcVersionTask = (\c -> if c == '.' then '_' else c) <$> dispGhcVersionShort job

tell_env' :: String -> String -> String
tell_env' k v = "echo " ++ show ("export " ++ k ++ "=" ++ v) ++ " >> ~/.buildenv"

tell_env :: String -> String -> ShM ()
tell_env k v = sh $ tell_env' k v
