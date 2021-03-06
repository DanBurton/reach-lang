module Reach.CompilerTool where

import Control.Monad.Except
import qualified Filesystem.Path.CurrentOS as FP
import System.Directory

import Reach.Compiler
import Reach.CompilerNL(compileNL)

data CompilerToolOpts = CompilerToolOpts
  { cto_outputDir :: FilePath
  , cto_source :: FilePath
  , cto_expCon :: Bool
  , cto_expComp :: Bool
  }

makeCompilerOpts :: CompilerToolOpts -> IO CompilerOpts
makeCompilerOpts CompilerToolOpts{..} = do
  let srcp = cto_source
  let srcbp = FP.basename $ FP.decodeString srcp
  let outd = cto_outputDir
  let outdp = FP.decodeString outd
  let outn ext = FP.encodeString $ FP.append outdp $ srcbp `FP.addExtension` ext
  let out ext con = writeFile (outn ext) con
  createDirectoryIfMissing True outd
  return $ CompilerOpts
    { output = out
    , output_name = outn
    , source = srcp
    , expCon = cto_expCon
    }

compilerToolMain :: CompilerToolOpts -> IO ()
compilerToolMain ctool_opts@CompilerToolOpts{..} = do
  copts <- makeCompilerOpts ctool_opts
  when (cto_expComp) (compileNL copts)
  compile copts
