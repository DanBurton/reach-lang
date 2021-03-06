module Main where

import Data.Char
import System.Directory
import System.Environment
import Options.Applicative

import Reach.CompilerTool

data CompilerToolArgs = CompilerToolArgs
  { cta_outputDir :: FilePath
  , cta_source :: FilePath
  }

data CompilerToolEnv = CompilerToolEnv
  { cte_expCon :: Bool
  , cte_expComp :: Bool
  }

makeCompilerToolOpts :: CompilerToolArgs -> CompilerToolEnv -> CompilerToolOpts
makeCompilerToolOpts CompilerToolArgs{..} CompilerToolEnv{..} = CompilerToolOpts
  { cto_outputDir = cta_outputDir
  , cto_source = cta_source
  , cto_expCon = cte_expCon
  , cto_expComp = cte_expComp
  }

compiler :: FilePath -> Parser CompilerToolArgs
compiler cwd = CompilerToolArgs
  <$> strOption
  ( long "output"
    <> short 'o'
    <> metavar "DIR"
    <> help "Directory for output files"
    <> showDefault
    <> value cwd )
  <*> strArgument (metavar "SOURCE")


checkTruthyEnv :: String -> IO Bool
checkTruthyEnv varName = do
  varValMay <- lookupEnv varName
  case varValMay of
    Just varVal -> return $ not isFalsy where
      isFalsy = isNo || isFalse || isEmpty || isZero
      varValLower = map toLower varVal
      isNo = varValLower == "no"
      isFalse = varValLower == "false"
      isEmpty = varValLower == ""
      isZero = varValLower == "0"
    Nothing -> return False

getCompilerArgs :: IO CompilerToolArgs
getCompilerArgs = do
  cwd <- getCurrentDirectory
  let opts = info ( compiler cwd <**> helper )
               ( fullDesc
               <> progDesc "verify and compile an Reach program"
               <> header "reachc - Reach compiler" )
  execParser opts

getCompilerEnv :: IO CompilerToolEnv
getCompilerEnv = do
  expCon <- checkTruthyEnv "REACHC_ENABLE_EXPERIMENTAL_CONNECTORS"
  expComp <- checkTruthyEnv "REACHC_ENABLE_EXPERIMENTAL_COMPILER"
  return CompilerToolEnv
    { cte_expCon = expCon
    , cte_expComp = expComp
    }

main :: IO ()
main = do
  args <- getCompilerArgs
  env <- getCompilerEnv
  let ctool_opts = makeCompilerToolOpts args env
  compilerToolMain ctool_opts
