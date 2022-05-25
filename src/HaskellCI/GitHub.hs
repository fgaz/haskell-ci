{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module HaskellCI.GitHub (
    makeGitHub,
    githubHeader,
) where

import HaskellCI.Prelude

import Control.Applicative (optional)

import qualified Crypto.Hash.SHA256              as SHA256
import qualified Data.Attoparsec.Text            as Atto
import qualified Data.Binary                     as Binary
import qualified Data.Binary.Put                 as Binary
import qualified Data.ByteString.Base16          as Base16
import qualified Data.ByteString.Char8           as BS8
import qualified Data.Map.Strict                 as Map
import qualified Data.Set                        as S
import qualified Data.Text                       as T
import qualified Distribution.Fields.Pretty      as C
import qualified Distribution.Package            as C
import qualified Distribution.Pretty             as C
import qualified Distribution.Types.VersionRange as C
import qualified Distribution.Version            as C

import Cabal.Project
import HaskellCI.Auxiliary
import HaskellCI.Compiler
import HaskellCI.Config
import HaskellCI.Config.ConstraintSet
import HaskellCI.Config.Docspec
import HaskellCI.Config.Doctest
import HaskellCI.Config.HLint
import HaskellCI.Config.Installed
import HaskellCI.Config.Jobs
import HaskellCI.Config.PackageScope
import HaskellCI.Config.Ubuntu
import HaskellCI.Config.Validity
import HaskellCI.GitConfig
import HaskellCI.GitHub.Yaml
import HaskellCI.HeadHackage
import HaskellCI.Jobs
import HaskellCI.List
import HaskellCI.MonadErr
import HaskellCI.Package
import HaskellCI.Sh
import HaskellCI.ShVersionRange
import HaskellCI.Tools
import HaskellCI.VersionInfo

-- $setup
-- >>> :set -XOverloadedStrings

-------------------------------------------------------------------------------
-- GitHub header
-------------------------------------------------------------------------------

githubHeader :: Bool -> [String] -> [String]
githubHeader insertVersion argv =
    [ "This GitHub workflow config has been generated by a script via"
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
-- GitHub
-------------------------------------------------------------------------------

{-
GitHub Actions–specific notes:

* We use -j2 for parallelism, as GitHub's virtual machines use 2 cores, per
  https://docs.github.com/en/free-pro-team@latest/actions/reference/specifications-for-github-hosted-runners#supported-runners-and-hardware-resources.
-}

makeGitHub
    :: [String]
    -> Config
    -> GitConfig
    -> Project URI Void Package
    -> JobVersions
    -> Either HsCiError GitHub
makeGitHub _argv config@Config {..} gitconfig prj jobs@JobVersions {..} = do
    let envEnv = Map.fromList
            [ ("HCNAME", "${{ matrix.compiler }}")         -- e.g. ghc-8.8.4
            , ("HCKIND", "${{ matrix.compilerKind }}")     --      ghc
            , ("HCVER",  "${{ matrix.compilerVersion }}")  --      8.8.4
            ]

    -- Validity checks
    checkConfigValidity config jobs
    when (cfgSubmodules && cfgUbuntu < Focal) $
        throwErr $ ValidationError $ unwords
            [ "Using submodules on the GitHub Actions backend requires"
            , "Ubuntu 20.04 (Focal Fossa) or later."
            ]

    steps <- sequence $ buildList $ do
        -- This have to be first, since the packages we install depend on
        -- whether we need GHCJS or not.
        when anyGHCJS $ githubRun' "Set GHCJS environment variables" envEnv $ sh $ intercalate "\n"
            [ "if [ $HCKIND = ghcjs ]; then"
            , tell_env' "GHCJS" "true"
            , tell_env' "GHCJSARITH" "1"
            , "else"
            , tell_env' "GHCJS" "false"
            , tell_env' "GHCJSARITH" "0"
            , "fi"
            ]

        githubRun' "apt" envEnv $ do
            sh "apt-get update"
            let corePkgs :: [String]
                corePkgs =
                    [ "gnupg"
                    , "ca-certificates"
                    , "dirmngr"
                    , "curl"
                    , "git"
                    , "software-properties-common"
                    , "libtinfo5"
                    ] ++
                    -- Installing libnuma-dev is required to work around
                    -- https://gitlab.haskell.org/haskell/ghcup-hs/-/blob/b0522507be6fa991a819aaf22f9a551757380821/README.md#libnuma-required
                    [ "libnuma-dev"
                    | GHC (C.mkVersion [8,4,4]) `elem` allVersions
                    , GHC (C.mkVersion [8,4,4]) & isGHCUP
                    ]
            sh $ "apt-get install -y --no-install-recommends " ++ unwords corePkgs

            let installGhcup :: ShM ()
                installGhcup = do
                    let ghcupVer = C.prettyShow cfgGhcupVersion
                    sh $ "mkdir -p \"$HOME/.ghcup/bin\""
                    sh $ "curl -sL https://downloads.haskell.org/ghcup/" ++ ghcupVer ++ "/x86_64-linux-ghcup-" ++ ghcupVer ++ " > \"$HOME/.ghcup/bin/ghcup\""
                    sh $ "chmod a+x \"$HOME/.ghcup/bin/ghcup\""

                installGhcupCabal :: ShM ()
                installGhcupCabal =
                    sh $ "\"$HOME/.ghcup/bin/ghcup\" install cabal " ++ cabalFullVer

            hvrppa <- runSh $ do
                sh "apt-add-repository -y 'ppa:hvr/ghc'"
                when anyGHCJS $ do
                    sh_if RangeGHCJS "apt-add-repository -y 'ppa:hvr/ghcjs'"
                    sh_if RangeGHCJS "curl -sSL \"https://deb.nodesource.com/gpgkey/nodesource.gpg.key\" | apt-key add -"
                    sh_if RangeGHCJS $ "apt-add-repository -y 'deb https://deb.nodesource.com/node_10.x " ++ ubuntuVer ++ " main'"
                sh "apt-get update"
                let basePackages  = ["\"$HCNAME\"" ] ++ [ "cabal-install-" ++ cabalVer | not cfgGhcupCabal ] ++ S.toList cfgApt
                    ghcjsPackages = ["ghc-8.4.4", "nodejs"]
                    baseInstall   = "apt-get install -y " ++ unwords basePackages
                    ghcjsInstall  = "apt-get install -y " ++ unwords (basePackages ++ ghcjsPackages)
                if anyGHCJS
                    then if_then_else RangeGHCJS ghcjsInstall baseInstall
                    else sh baseInstall
                when cfgGhcupCabal $ do
                    installGhcup
                    installGhcupCabal

            ghcup <- runSh $ do
                installGhcup
                sh $ "\"$HOME/.ghcup/bin/ghcup\" install ghc \"$HCVER\""
                installGhcupCabal
                unless (null cfgApt) $ do
                    sh "apt-get update"
                    sh $ "apt-get install -y " ++ unwords (S.toList cfgApt)

            setup hvrppa ghcup

        githubRun' "Set PATH and environment variables" envEnv $ do
            echo_to "$GITHUB_PATH" "$HOME/.cabal/bin"

            -- Hack: happy needs ghc. Let's install version matching GHCJS.
            -- At the moment, there is only GHCJS-8.4, so we install GHC-8.4.4
            when anyGHCJS $
                echo_if_to RangeGHCJS "$GITHUB_PATH" "/opt/ghc/8.4.4/bin"

            tell_env "LANG" "C.UTF-8"

            tell_env "CABAL_DIR"    "$HOME/.cabal"
            tell_env "CABAL_CONFIG" "$HOME/.cabal/config"

            sh "HCDIR=/opt/$HCKIND/$HCVER"

            let ghcupCabalPath = tell_env "CABAL" $ "$HOME/.ghcup/bin/cabal-" ++ cabalFullVer ++ " -vnormal+nowrap"

            hvrppa <- runSh $ do
                let hc = "$HCDIR/bin/$HCKIND"
                sh $ "HC=" ++ hc -- HC is an absolute path.
                tell_env "HC" "$HC"
                tell_env "HCPKG" $ hc ++ "-pkg"
                tell_env "HADDOCK" "$HCDIR/bin/haddock"
                if cfgGhcupCabal
                then ghcupCabalPath
                else tell_env "CABAL" $ "/opt/cabal/" ++ cabalVer ++ "/bin/cabal -vnormal+nowrap"

            ghcup <- runSh $ do
                let hc = "$HOME/.ghcup/bin/$HCKIND-$HCVER"
                sh $ "HC=" ++ hc -- HC is an absolute path.
                tell_env "HC"      "$HC"
                tell_env "HCPKG" $ "$HOME/.ghcup/bin/$HCKIND-pkg-$HCVER"
                tell_env "HADDOCK" "$HOME/.ghcup/bin/haddock-$HCVER"
                ghcupCabalPath

            setup hvrppa ghcup

            sh "HCNUMVER=$(${HC} --numeric-version|perl -ne '/^(\\d+)\\.(\\d+)\\.(\\d+)(\\.(\\d+))?$/; print(10000 * $1 + 100 * $2 + ($3 == 0 ? $5 != 1 : $3))')"
            tell_env "HCNUMVER" "$HCNUMVER"

            if_then_else (Range cfgTests)
                (tell_env' "ARG_TESTS" "--enable-tests")
                (tell_env' "ARG_TESTS" "--disable-tests")
            if_then_else (Range cfgBenchmarks)
                (tell_env' "ARG_BENCH" "--enable-benchmarks")
                (tell_env' "ARG_BENCH" "--disable-benchmarks")
            if_then_else (Range cfgHeadHackage \/ RangePoints (S.singleton GHCHead))
                (tell_env' "HEADHACKAGE" "true")
                (tell_env' "HEADHACKAGE" "false")

            tell_env "ARG_COMPILER" "--$HCKIND --with-compiler=$HC"

            unless anyGHCJS $
                tell_env "GHCJSARITH" "0"

        githubRun "env" $ do
            sh "env"

        githubRun "write cabal config" $ do
            sh "mkdir -p $CABAL_DIR"
            cat "$CABAL_CONFIG" $ unlines
                [ "remote-build-reporting: anonymous"
                , "write-ghc-environment-files: never"
                , "remote-repo-cache: $CABAL_DIR/packages"
                , "logs-dir:          $CABAL_DIR/logs"
                , "world-file:        $CABAL_DIR/world"
                , "extra-prog-path:   $CABAL_DIR/bin"
                , "symlink-bindir:    $CABAL_DIR/bin"
                , "installdir:        $CABAL_DIR/bin"
                , "build-summary:     $CABAL_DIR/logs/build.log"
                , "store-dir:         $CABAL_DIR/store"
                , "install-dirs user"
                , "  prefix: $CABAL_DIR"
                , "repository hackage.haskell.org"
                , "  url: http://hackage.haskell.org/"
                ]

            -- Add head.hackage repository to ~/.cabal/config
            -- (locally you want to add it to cabal.project)
            unless (S.null headGhcVers) $ sh $ concat $
                [ "if $HEADHACKAGE; then\n"
                , catCmd "$CABAL_CONFIG" $ unlines headHackageRepoStanza
                , "\nfi"
                ]

            -- Cabal jobs
            for_ (cfgJobs >>= cabalJobs) $ \n ->
                cat "$CABAL_CONFIG" $ unlines
                    [ "jobs: " ++ show n
                    ]

            -- GHC jobs + ghc-options
            for_ (cfgJobs >>= ghcJobs) $ \m -> do
                sh_if (Range $ C.orLaterVersion (C.mkVersion [7,8])) $ "GHCJOBS=-j" ++ show m

            cat "$CABAL_CONFIG" $ unlines
                [ "program-default-options"
                , "  ghc-options: $GHCJOBS +RTS -M3G -RTS"
                ]

            sh "cat $CABAL_CONFIG"

        githubRun "versions" $ do
            sh "$HC --version || true"
            sh "$HC --print-project-git-commit-id || true"
            sh "$CABAL --version || true"
            when anyGHCJS $ do
                sh_if RangeGHCJS "node --version"
                sh_if RangeGHCJS "echo $GHCJS"

        githubRun "update cabal index" $ do
            sh "$CABAL v2-update -v"

        let toolsConfigHash :: String
            toolsConfigHash = take 8 $ BS8.unpack $ Base16.encode $ SHA256.hashlazy $ Binary.runPut $ do
                Binary.put cfgDoctest
                Binary.put cfgHLint
                Binary.put cfgGhcupJobs -- GHC location affects doctest, e.g

        when (doctestEnabled || cfgHLintEnabled cfgHLint) $ githubUses "cache (tools)" "actions/cache@v2"
            [ ("key", "${{ runner.os }}-${{ matrix.compiler }}-tools-" ++ toolsConfigHash)
            , ("path", "~/.haskell-ci-tools")
            ]

        githubRun "install cabal-plan" $ do
            sh "mkdir -p $HOME/.cabal/bin"
            sh "curl -sL https://github.com/haskell-hvr/cabal-plan/releases/download/v0.6.2.0/cabal-plan-0.6.2.0-x86_64-linux.xz > cabal-plan.xz"
            sh "echo 'de73600b1836d3f55e32d80385acc055fd97f60eaa0ab68a755302685f5d81bc  cabal-plan.xz' | sha256sum -c -"
            sh "xz -d < cabal-plan.xz > $HOME/.cabal/bin/cabal-plan"
            sh "rm -f cabal-plan.xz"
            sh "chmod a+x $HOME/.cabal/bin/cabal-plan"
            sh "cabal-plan --version"

        when anyGHCJS $ githubRun "install happy" $ do
            for_ cfgGhcjsTools $ \t ->
                sh_if RangeGHCJS $ "$CABAL v2-install -w ghc-8.4.4 --ignore-project -j2" ++ C.prettyShow t

        when docspecEnabled $ githubRun "install cabal-docspec" $ do
            let hash = cfgDocspecHash cfgDocspec
                url  = cfgDocspecUrl cfgDocspec
            sh "mkdir -p $HOME/.cabal/bin"
            sh $ "curl -sL " ++ url ++ " > cabal-docspec.xz"
            sh $ "echo '" ++ hash ++ "  cabal-docspec.xz' | sha256sum -c -"
            sh "xz -d < cabal-docspec.xz > $HOME/.cabal/bin/cabal-docspec"
            sh "rm -f cabal-docspec.xz"
            sh "chmod a+x $HOME/.cabal/bin/cabal-docspec"
            sh "cabal-docspec --version"

        when doctestEnabled $ githubRun "install doctest" $ do
            let range = Range (cfgDoctestEnabled cfgDoctest) /\ doctestJobVersionRange
            sh_if range "$CABAL --store-dir=$HOME/.haskell-ci-tools/store v2-install $ARG_COMPILER --ignore-project -j2 doctest --constraint='doctest ^>=0.20'"
            sh_if range "doctest --version"

        let hlintVersionConstraint
                | C.isAnyVersion (cfgHLintVersion cfgHLint) = ""
                | otherwise = " --constraint='hlint " ++ prettyShow (cfgHLintVersion cfgHLint) ++ "'"
        when (cfgHLintEnabled cfgHLint) $ githubRun "install hlint" $ do
            let forHLint = sh_if (hlintJobVersionRange allVersions cfgHeadHackage (cfgHLintJob cfgHLint))
            if cfgHLintDownload cfgHLint
            then do
                -- install --dry-run and use perl regex magic to find a hlint version
                -- -v is important
                forHLint $ "HLINTVER=$(cd /tmp && (${CABAL} v2-install -v $ARG_COMPILER --dry-run hlint " ++ hlintVersionConstraint ++ " |  perl -ne 'if (/\\bhlint-(\\d+(\\.\\d+)*)\\b/) { print \"$1\"; last; }')); echo \"HLint version $HLINTVER\""
                forHLint $ "if [ ! -e $HOME/.haskell-ci-tools/hlint-$HLINTVER/hlint ]; then " ++ unwords
                    [ "echo \"Downloading HLint version $HLINTVER\";"
                    , "mkdir -p $HOME/.haskell-ci-tools;"
                    , "curl --write-out 'Status Code: %{http_code} Redirects: %{num_redirects} Total time: %{time_total} Total Dsize: %{size_download}\\n' --silent --location --output $HOME/.haskell-ci-tools/hlint-$HLINTVER.tar.gz \"https://github.com/ndmitchell/hlint/releases/download/v$HLINTVER/hlint-$HLINTVER-x86_64-linux.tar.gz\";"
                    , "tar -xzv -f $HOME/.haskell-ci-tools/hlint-$HLINTVER.tar.gz -C $HOME/.haskell-ci-tools;"
                    , "fi"
                    ]
                forHLint "mkdir -p $CABAL_DIR/bin && ln -sf \"$HOME/.haskell-ci-tools/hlint-$HLINTVER/hlint\" $CABAL_DIR/bin/hlint"
                forHLint "hlint --version"

            else do
                forHLint $ "$CABAL --store-dir=$HOME/.haskell-ci-tools/store v2-install $ARG_COMPILER --ignore-project -j2 hlint" ++ hlintVersionConstraint
                forHLint "hlint --version"

        githubUses "checkout" "actions/checkout@v2" $ buildList $ do
            item ("path", "source")
            when cfgSubmodules $
                item ("submodules", "true")

        githubRun "initial cabal.project for sdist" $ do
            sh "touch cabal.project"
            for_ pkgs $ \pkg ->
                echo_if_to (RangePoints $ pkgJobs pkg) "cabal.project" $ "packages: $GITHUB_WORKSPACE/source/" ++ pkgDir pkg
            sh "cat cabal.project"

        githubRun "sdist" $ do
            sh "mkdir -p sdist"
            sh "$CABAL sdist all --output-dir $GITHUB_WORKSPACE/sdist"

        githubRun "unpack" $ do
            sh "mkdir -p unpacked"
            sh "find sdist -maxdepth 1 -type f -name '*.tar.gz' -exec tar -C $GITHUB_WORKSPACE/unpacked -xzvf {} \\;"

        githubRun "generate cabal.project" $ do
            for_ pkgs $ \Pkg{pkgName} -> do
                sh $ pkgNameDirVariable' pkgName ++ "=\"$(find \"$GITHUB_WORKSPACE/unpacked\" -maxdepth 1 -type d -regex '.*/" ++ pkgName ++ "-[0-9.]*')\""
                tell_env (pkgNameDirVariable' pkgName) (pkgNameDirVariable pkgName)

            sh "rm -f cabal.project cabal.project.local"
            sh "touch cabal.project"
            sh "touch cabal.project.local"

            for_ pkgs $ \pkg ->
                echo_if_to (RangePoints $ pkgJobs pkg) "cabal.project" $ "packages: " ++ pkgNameDirVariable (pkgName pkg)

            -- per package options
            case cfgErrorMissingMethods of
                PackageScopeNone  -> pure ()
                PackageScopeLocal -> for_ pkgs $ \Pkg{pkgName,pkgJobs} -> do
                    let range = Range (C.orLaterVersion (C.mkVersion [8,2])) /\ RangePoints pkgJobs
                    echo_if_to range "cabal.project" $ "package " ++ pkgName
                    echo_if_to range "cabal.project" $ "    ghc-options: -Werror=missing-methods"
                PackageScopeAll   -> cat "cabal.project" $ unlines
                    [ "package *"
                    , "  ghc-options: -Werror=missing-methods"
                    ]

            -- extra cabal.project fields
            cat "cabal.project" $ C.showFields' (const []) (const id) 2 $ extraCabalProjectFields "$GITHUB_WORKSPACE/source/"

            -- If using head.hackage, allow building with newer versions of GHC boot libraries.
            -- Note that we put this in a cabal.project file, not ~/.cabal/config, in order to avoid
            -- https://github.com/haskell/cabal/issues/7291.
            unless (S.null headGhcVers) $ sh $ concat $
                [ "if $HEADHACKAGE; then\n"
                , "echo \"allow-newer: $($HCPKG list --simple-output | sed -E 's/([a-zA-Z-]+)-[0-9.]+/*:\\1,/g')\" >> cabal.project\n"
                , "fi"
                ]

            -- also write cabal.project.local file with
            -- @
            -- constraints: base installed
            -- constraints: array installed
            -- ...
            --
            -- omitting any local package names
            case normaliseInstalled cfgInstalled of
                InstalledDiff pns -> sh $ unwords
                    [ "$HCPKG list --simple-output --names-only"
                    , "| perl -ne 'for (split /\\s+/) { print \"constraints: $_ installed\\n\" unless /" ++ re ++ "/; }'"
                    , ">> cabal.project.local"
                    ]
                  where
                    pns' = S.map C.unPackageName pns `S.union` foldMap (S.singleton . pkgName) pkgs
                    re = "^(" ++ intercalate "|" (S.toList pns') ++ ")$"

                InstalledOnly pns | not (null pns') -> cat "cabal.project.local" $ unlines
                    [ "constraints: " ++ pkg ++ " installed"
                    | pkg <- S.toList pns'
                    ]
                  where
                    pns' = S.map C.unPackageName pns `S.difference` foldMap (S.singleton . pkgName) pkgs

                -- otherwise: nothing
                _ -> pure ()

            sh "cat cabal.project"
            sh "cat cabal.project.local"

        githubRun "dump install plan" $ do
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dry-run all"
            sh "cabal-plan"

        -- This a hack. https://github.com/actions/cache/issues/109
        -- Hashing Java - Maven style.
        githubUses "cache" "actions/cache@v2"
            [ ("key", "${{ runner.os }}-${{ matrix.compiler }}-${{ github.sha }}")
            , ("restore-keys", "${{ runner.os }}-${{ matrix.compiler }}-")
            , ("path", "~/.cabal/store")
            ]

        -- install dependencies
        when cfgInstallDeps $ githubRun "install dependencies" $ do
            sh "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks --dependencies-only -j2 all"
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dependencies-only -j2 all"

        -- build w/o tests benchs
        unless (equivVersionRanges C.noVersion cfgNoTestsNoBench) $ githubRun "build w/o tests" $ do
            sh "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all"

        -- build
        githubRun "build" $ do
            sh "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH all --write-ghc-environment-files=always"

        -- tests
        githubRun "tests" $ do
            let range = RangeGHC /\ Range (cfgTests /\ cfgRunTests) /\ hasTests
            sh_if range $ "$CABAL v2-test $ARG_COMPILER $ARG_TESTS $ARG_BENCH all" ++ testShowDetails

            when (anyGHCJS && cfgGhcjsTests) $ sh $ unlines $
                [ "pkgdir() {"
                , "  case $1 in"
                ] ++
                [ "    " ++ pkgName ++ ") echo " ++ pkgNameDirVariable pkgName ++ " ;;"
                | Pkg{pkgName} <- pkgs
                ] ++
                [ "  esac"
                , "}"
                ]

            when cfgGhcjsTests $ sh_if (RangeGHCJS /\ hasTests) $ unwords
                [ "cabal-plan list-bins '*:test:*' | while read -r line; do"
                , "testpkg=$(echo \"$line\" | perl -pe 's/:.*//');"
                , "testexe=$(echo \"$line\" | awk '{ print $2 }');"
                , "echo \"testing $textexe in package $textpkg\";"
                , "(cd \"$(pkgdir $testpkg)\" && nodejs \"$testexe\".jsexe/all.js);"
                , "done"
                ]

        -- doctest
        when doctestEnabled $ githubRun "doctest" $ do
            let doctestOptions = unwords $ cfgDoctestOptions cfgDoctest

            unless (null $ cfgDoctestFilterEnvPkgs cfgDoctest) $ do
                -- cabal-install mangles unit ids on the OSX,
                -- removing the vowels to make filepaths shorter
                let manglePkgNames :: String -> [String]
                    manglePkgNames n
                        | null macosVersions = [n]
                        | otherwise          = [n, filter notVowel n]
                      where
                        notVowel c = notElem c ("aeiou" :: String)
                let filterPkgs = intercalate "|" $ concatMap (manglePkgNames . C.unPackageName) $ cfgDoctestFilterEnvPkgs cfgDoctest
                sh $ "perl -i -e 'while (<ARGV>) { print unless /package-id\\s+(" ++ filterPkgs ++ ")-\\d+(\\.\\d+)*/; }' .ghc.environment.*"

            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} ->
                when (C.mkPackageName pkgName `notElem` cfgDoctestFilterSrcPkgs cfgDoctest) $ do
                    for_ (doctestArgs pkgGpd) $ \args -> do
                        let args' = unwords args
                        let vr = Range (cfgDoctestEnabled cfgDoctest)
                              /\ doctestJobVersionRange
                              /\ RangePoints pkgJobs

                        unless (null args) $ do
                            change_dir_if vr $ pkgNameDirVariable pkgName
                            sh_if vr $ "doctest " ++ doctestOptions ++ " " ++ args'

        -- docspec
        when docspecEnabled $ githubRun "docspec" $ do
            -- docspec doesn't work with non-GHC (i.e. GHCJS)
            let docspecRange' = docspecRange /\ RangeGHC
            -- we need to rebuild, if tests screwed something.
            sh_if docspecRange' "$CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH all"
            sh_if docspecRange' cabalDocspec

        -- hlint
        when (cfgHLintEnabled cfgHLint) $ githubRun "hlint" $ do
            let "" <+> ys = ys
                xs <+> "" = xs
                xs <+> ys = xs ++ " " ++ ys

                prependSpace "" = ""
                prependSpace xs = " " ++ xs

            let hlintOptions = prependSpace $ maybe "" ("-h ${GITHUB_WORKSPACE}/source/" ++) (cfgHLintYaml cfgHLint) <+> unwords (cfgHLintOptions cfgHLint)

            for_ pkgs $ \Pkg{pkgName,pkgGpd,pkgJobs} -> do
                for_ (hlintArgs pkgGpd) $ \args -> do
                    let args' = unwords args
                    unless (null args) $
                        sh_if (hlintJobVersionRange allVersions cfgHeadHackage (cfgHLintJob cfgHLint) /\ RangePoints pkgJobs) $
                        "(cd " ++ pkgNameDirVariable pkgName ++ " && hlint" ++ hlintOptions ++ " " ++ args' ++ ")"

        -- cabal check
        when cfgCheck $ githubRun "cabal check" $ do
            for_ pkgs $ \Pkg{pkgName,pkgJobs} -> do
                let range = RangePoints pkgJobs
                change_dir_if range $ pkgNameDirVariable pkgName
                sh_if range "${CABAL} -vnormal check"

        -- haddock
        when (not (equivVersionRanges C.noVersion cfgHaddock)) $ githubRun "haddock" $ do
            let range = RangeGHC /\ Range cfgHaddock
            sh_if range "$CABAL v2-haddock --haddock-all $ARG_COMPILER --with-haddock $HADDOCK $ARG_TESTS $ARG_BENCH all"

        -- unconstrained build
        unless (equivVersionRanges C.noVersion cfgUnconstrainted) $ githubRun "unconstrained build" $ do
            let range = Range cfgUnconstrainted
            sh_if range "rm -f cabal.project.local"
            sh_if range "$CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all"

        -- constraint sets
        unless (null cfgConstraintSets) $ githubRun "prepare for constraint sets" $ do
            sh "rm -f cabal.project.local"

        for_ cfgConstraintSets $ \cs -> githubRun ("constraint set " ++ csName cs) $ do
            let range
                  | csGhcjs cs  = Range (csGhcVersions cs)
                  | otherwise   = RangeGHC /\ Range (csGhcVersions cs)

            let sh_cs           = sh_if range
            let sh_cs' r        = sh_if (range /\ r)
            let testFlag        = if csTests cs then "--enable-tests" else "--disable-tests"
            let benchFlag       = if csBenchmarks cs then "--enable-benchmarks" else "--disable-benchmarks"
            let constraintFlags = map (\x ->  "--constraint='" ++ x ++ "'") (csConstraints cs)
            let allFlags        = unwords (testFlag : benchFlag : constraintFlags)

            when cfgInstallDeps $ sh_cs $ "$CABAL v2-build $ARG_COMPILER " ++ allFlags ++ " --dependencies-only -j2 all"
            sh_cs $ "$CABAL v2-build $ARG_COMPILER " ++ allFlags ++ " all"
            when (docspecEnabled && csDocspec cs) $
                sh_cs' docspecRange cabalDocspec
            when (csRunTests cs) $
                sh_cs' hasTests $ "$CABAL v2-test $ARG_COMPILER " ++ allFlags ++ " all"
            when (csHaddock cs) $
                sh_cs $ "$CABAL v2-haddock --haddock-all $ARG_COMPILER " ++ withHaddock ++ " " ++ allFlags ++ " all"

    -- assembling everything
    return GitHub
        { ghName = actionName
        , ghOn = GitHubOn
            { ghBranches = cfgOnlyBranches
            }
        , ghJobs = Map.fromList $ buildList $ do
            item (mainJobName, GitHubJob
                { ghjName            = actionName ++ " - Linux - ${{ matrix.compiler }}"
                  -- NB: The Ubuntu version used in `runs-on` isn't
                  -- particularly important since we use a Docker container.
                , ghjRunsOn          = "ubuntu-20.04"
                , ghjNeeds           = []
                , ghjSteps           = steps
                , ghjIf              = Nothing
                , ghjContainer       = Just $ "buildpack-deps:" ++ ubuntuVer
                , ghjContinueOnError = Just "${{ matrix.allow-failure }}"
                , ghjServices        = mconcat
                    [ Map.singleton "postgres" postgresService | cfgPostgres ]
                , ghjTimeout         = max 10 cfgTimeoutMinutes
                , ghjMatrix          =
                    [ GitHubMatrixEntry
                        { ghmeCompiler     = compiler
                        , ghmeAllowFailure =
                               previewGHC cfgHeadHackage compiler
                            || maybeGHC False (`C.withinRange` cfgAllowFailures) compiler
                        , ghmeSetupMethod = if isGHCUP compiler then GHCUP else HVRPPA
                        }
                    | compiler <- reverse $ toList linuxVersions
                    , compiler /= GHCHead -- TODO: Make this work
                                          -- https://github.com/haskell-CI/haskell-ci/issues/458
                    ]
                })
            unless (null cfgIrcChannels) $
                ircJob actionName mainJobName projectName config gitconfig
        }
  where
    actionName  = fromMaybe "Haskell-CI" cfgGitHubActionName
    mainJobName = "linux"

    ubuntuVer    = showUbuntu cfgUbuntu
    cabalVer     = dispCabalVersion cfgCabalInstallVersion
    cabalFullVer = dispCabalVersion $ cfgCabalInstallVersion <&> \ver ->
        case C.versionNumbers ver of
            [3,6] -> C.mkVersion [3,6,2,0]
            [x,y] -> C.mkVersion [x,y,0,0]
            _     -> ver

    Auxiliary {..} = auxiliary config prj jobs

    anyGHCJS = any isGHCJS allVersions
    anyGHCUP = any isGHCUP allVersions
    allGHCUP = all isGHCUP allVersions

    -- Generate a setup block for hvr-ppa or ghcup, or both.
    setup :: [Sh] -> [Sh] -> ShM ()
    setup hvrppa ghcup
        | allGHCUP     = traverse_ liftSh ghcup
        | not anyGHCUP = traverse_ liftSh hvrppa
        -- SC2192: ${{ ...}} will match (ShellCheck think it doesn't)
        -- SC2129: individual redirects
        -- SC2296: Parameter expansions can't start with {. Double check syntax. -- ${{ }} in YAML templating.
        | otherwise    = sh' [2193, 2129, 2296] $ unlines $
            [ "if [ \"${{ matrix.setup-method }}\" = ghcup ]; then"
            ] ++
            [ "  " ++ shToString s
            | s <- ghcup
            ] ++
            [ "else"
            ] ++
            [ "  " ++ shToString s
            | s <- hvrppa
            ] ++
            [ "fi"
            ]

    -- job to be setup with ghcup
    isGHCUP :: CompilerVersion -> Bool
    isGHCUP v = compilerWithinRange v (RangeGHC /\ Range cfgGhcupJobs)

    -- GHC versions which need head.hackage
    headGhcVers :: Set CompilerVersion
    headGhcVers = S.filter (previewGHC cfgHeadHackage) allVersions

    -- step primitives
    githubRun' :: String -> Map.Map String String ->  ShM () -> ListBuilder (Either HsCiError GitHubStep) ()
    githubRun' name env shm = item $ do
        shs <- runSh shm
        return $ GitHubStep name $ Left $ GitHubRun shs env

    githubRun :: String -> ShM () -> ListBuilder (Either HsCiError GitHubStep) ()
    githubRun name = githubRun' name mempty

    githubUses :: String -> String -> [(String, String)] -> ListBuilder (Either HsCiError GitHubStep) ()
    githubUses name action with = item $ return $
        GitHubStep name $ Right $ GitHubUses action Nothing (Map.fromList with)

    -- shell primitives
    echo_to' :: FilePath -> String -> String
    echo_to' fp s = "echo " ++ show s ++ " >> " ++ fp

    echo_to :: FilePath -> String -> ShM ()
    echo_to fp s = sh $ echo_to' fp s

    echo_if_to :: CompilerRange -> FilePath -> String -> ShM ()
    echo_if_to range fp s = sh_if range $ echo_to' fp s

    change_dir_if :: CompilerRange -> String -> ShM ()
    change_dir_if range dir = sh_if range ("cd " ++ dir ++ " || false")

    tell_env' :: String -> String -> String
    tell_env' k v = "echo " ++ show (k ++ "=" ++ v) ++ " >> \"$GITHUB_ENV\""

    tell_env :: String -> String -> ShM ()
    tell_env k v = sh $ tell_env' k v

    if_then_else :: CompilerRange -> String -> String -> ShM ()
    if_then_else range con alt
        | all (`compilerWithinRange` range) allVersions       = sh con
        | not $ any (`compilerWithinRange` range) allVersions = sh alt
        | otherwise = sh $ unwords
        [ "if ["
        , compilerVersionArithPredicate allVersions range
        , "-ne 0 ]"
        , "; then"
        , con
        , ";"
        , "else"
        , alt
        , ";"
        , "fi"
        ]

    sh_if :: CompilerRange -> String -> ShM ()
    sh_if range con
        | all (`compilerWithinRange` range) allVersions       = sh con
        | not $ any (`compilerWithinRange` range) allVersions = pure ()
        | otherwise = sh $ unwords
        [ "if ["
        , compilerVersionArithPredicate allVersions range
        , "-ne 0 ]"
        , "; then"
        , con
        , ";"
        , "fi"
        ]

    -- Needed to work around haskell/cabal#6214
    withHaddock :: String
    withHaddock = "--with-haddock $HADDOCK"

    cabalDocspec :: String
    cabalDocspec =
      let docspecOptions = cfgDocspecOptions cfgDocspec in
      unwords $ "cabal-docspec $ARG_COMPILER" : docspecOptions

    docspecRange :: CompilerRange
    docspecRange = Range (cfgDocspecEnabled cfgDocspec)

postgresService :: GitHubService
postgresService = GitHubService
    { ghServImage   = "postgres:10"
    , ghServOptions = Just "--health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5"
    , ghServEnv     = Map.fromList
          [ ("POSTGRES_PASSWORD", "postgres")
          ]
    }

ircJob :: String -> String -> String -> Config -> GitConfig -> ListBuilder (String, GitHubJob) ()
ircJob actionName mainJobName projectName cfg gitconfig = item ("irc", GitHubJob
    { ghjName            = actionName ++ " (IRC notification)"
    , ghjRunsOn          = "ubuntu-18.04"
    , ghjNeeds           = [mainJobName]
    , ghjIf              = jobCondition
    , ghjContainer       = Nothing
    , ghjContinueOnError = Nothing
    , ghjMatrix          = []
    , ghjServices        = mempty
    , ghjSteps           = [ ircStep serverChannelName success
                           | serverChannelName <- serverChannelNames
                           , success <- [True, False]
                           ]
    , ghjTimeout         = 10
    })
  where
    serverChannelNames = cfgIrcChannels cfg

    jobCondition :: Maybe String
    jobCondition
        | cfgIrcIfInOriginRepo cfg
        , Just url <- Map.lookup "origin" (gitCfgRemotes gitconfig)
        , Just repo <- parseGitHubRepo url

        = Just
        $ "${{ always() && (github.repository == '" ++ T.unpack repo ++ "') }}"

        | otherwise
        = Just "${{ always() }}"
        -- Use always() above to ensure that the IRC job will still run even if
        -- the build job itself fails (see #437).

    ircStep :: String -> Bool -> GitHubStep
    ircStep serverChannelName success =
        let (serverName, channelName) = break (== '#') serverChannelName

            result | success   = "success"
                   | otherwise = "failure"

            resultPastTense | success   = "succeeded"
                            | otherwise = "failed"

            eqCheck | success   = "=="
                    | otherwise = "!=" in

        GitHubStep ("IRC " ++ result ++ " notification (" ++ serverChannelName ++ ")") $ Right $
        GitHubUses "Gottox/irc-message-action@v1.1"
                   (Just $ "needs." ++ mainJobName ++ ".result " ++ eqCheck ++ " 'success'") $
        Map.fromList $ buildList $ do
            item ("server",   serverName)
            item ("channel",  channelName)
            item ("nickname", fromMaybe "github-actions" $ cfgIrcNickname cfg)
            for_ (cfgIrcPassword cfg) $ \p ->
                item ("sasl_password", p)
            item ("message",  "\x0313" ++ projectName ++ "\x03/\x0306${{ github.ref }}\x03 "
                                       ++ "\x0314${{ github.sha }}\x03 "
                                       ++ "https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }} "
                                       ++ "The build " ++ resultPastTense ++ ".")

catCmd :: FilePath -> String -> String
catCmd path contents = concat
    [ "cat >> " ++ path ++ " <<EOF\n"
    , contents
    , "EOF"
    ]

cat :: FilePath -> String -> ShM ()
cat path contents = sh $ catCmd path contents

-- | GitHub is very lenient and undocumented. We accept something.
-- Please, write a patch, if you need an extra scheme to be accepted.
--
-- >>> parseGitHubRepo "git@github.com:haskell-CI/haskell-ci.git"
-- Just "haskell-CI/haskell-ci"
--
-- >>> parseGitHubRepo "git@github.com:haskell-CI/haskell-ci"
-- Just "haskell-CI/haskell-ci"
--
-- >>> parseGitHubRepo "https://github.com/haskell-CI/haskell-ci.git"
-- Just "haskell-CI/haskell-ci"
--
-- >>> parseGitHubRepo "https://github.com/haskell-CI/haskell-ci"
-- Just "haskell-CI/haskell-ci"
--
-- >>> parseGitHubRepo "git://github.com/haskell-CI/haskell-ci"
-- Just "haskell-CI/haskell-ci"
--
parseGitHubRepo :: Text -> Maybe Text
parseGitHubRepo t =
    either (const Nothing) Just $ Atto.parseOnly (parser <* Atto.endOfInput) t
  where
    parser :: Atto.Parser Text
    parser = sshP <|> httpsP

    sshP :: Atto.Parser Text
    sshP = do
        _ <- optional (Atto.string "git://")
        _ <- Atto.string "git@github.com:"
        repo <- Atto.takeWhile (/= '.')
        _ <- optional (Atto.string ".git")
        return repo

    httpsP :: Atto.Parser Text
    httpsP = do
        _ <- Atto.string "https" <|> Atto.string "git"
        _ <- Atto.string "://github.com/"
        repo <- Atto.takeWhile (/= '.')
        _ <- optional (Atto.string ".git")
        return repo
