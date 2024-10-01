module ParseOptions
  ( Options(..)
  , parseOptions
  ) where

import Options.Applicative

data Options = Options
  { replicas :: Int
  , crashes  :: Int
  , cmdRate :: Int
  , time :: Int 
  , batchSize :: Int
  }

optionsParser :: Parser Options
optionsParser = Options
  <$> option auto
      ( long "replicas"
     <> short 'r'
     <> metavar "REPLICAS"
     <> help "Number of replicas"
     <> value 10 -- Default value for replicas
     <> showDefault )
  <*> option auto
      ( long "crashes"
     <> short 'c'
     <> metavar "CRASHES"
     <> help "Number of crashes"
     <> value 0 -- Default value for crashes
     <> showDefault )
  <*> option auto
      ( long "cmdRate"
     <> short 'm'
     <> metavar "CMDRATE"
     <> help "Number of commands sent to each node per client tick"
     <> value 1 -- Default value for crashes
     <> showDefault )
  <*> option auto
      ( long "time"
     <> short 't'
     <> metavar "TIME"
     <> help "Number of seconds to run experiment"
     <> value 10 -- Default value for crashes
     <> showDefault )
  <*> option auto
      ( long "batchSize"
     <> short 'b'
     <> metavar "BATCHSIZE"
     <> help "Number of commands included in a block"
     <> value 10 -- Default value for crashes
     <> showDefault )
  -- <*> option auto
  --     ( long "delta"
  --    <> short 'd'
  --    <> metavar "DELTA"
  --    <> help "Synchronous network bound in seconds, also message rate for certain protocols"
  --    <> value 1 -- Default value for crashes
  --    <> showDefault )

parseOptions :: IO Options
parseOptions = execParser opts
  where
    opts = info (optionsParser <**> helper)
      ( fullDesc
     <> progDesc "Run the program with the given number of replicas, crashes, and clients"
     <> header "Distributed Process Example" )