{-# LANGUAGE CPP #-}
{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module Paths_distributed_process_extras (
    version,
    getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir,
    getDataFileName, getSysconfDir
  ) where


import qualified Control.Exception as Exception
import qualified Data.List as List
import Data.Version (Version(..))
import System.Environment (getEnv)
import Prelude


#if defined(VERSION_base)

#if MIN_VERSION_base(4,0,0)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#else
catchIO :: IO a -> (Exception.Exception -> IO a) -> IO a
#endif

#else
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#endif
catchIO = Exception.catch

version :: Version
version = Version [0,3,5] []

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir `joinFileName` name)

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath



bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath
bindir     = "/Users/hans/.cabal/bin"
libdir     = "/Users/hans/.cabal/lib/aarch64-osx-ghc-9.2.8/distributed-process-extras-0.3.5-inplace"
dynlibdir  = "/Users/hans/.cabal/lib/aarch64-osx-ghc-9.2.8"
datadir    = "/Users/hans/.cabal/share/aarch64-osx-ghc-9.2.8/distributed-process-extras-0.3.5"
libexecdir = "/Users/hans/.cabal/libexec/aarch64-osx-ghc-9.2.8/distributed-process-extras-0.3.5"
sysconfdir = "/Users/hans/.cabal/etc"

getBinDir     = catchIO (getEnv "distributed_process_extras_bindir")     (\_ -> return bindir)
getLibDir     = catchIO (getEnv "distributed_process_extras_libdir")     (\_ -> return libdir)
getDynLibDir  = catchIO (getEnv "distributed_process_extras_dynlibdir")  (\_ -> return dynlibdir)
getDataDir    = catchIO (getEnv "distributed_process_extras_datadir")    (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "distributed_process_extras_libexecdir") (\_ -> return libexecdir)
getSysconfDir = catchIO (getEnv "distributed_process_extras_sysconfdir") (\_ -> return sysconfdir)




joinFileName :: String -> String -> FilePath
joinFileName ""  fname = fname
joinFileName "." fname = fname
joinFileName dir ""    = dir
joinFileName dir fname
  | isPathSeparator (List.last dir) = dir ++ fname
  | otherwise                       = dir ++ pathSeparator : fname

pathSeparator :: Char
pathSeparator = '/'

isPathSeparator :: Char -> Bool
isPathSeparator c = c == '/'
