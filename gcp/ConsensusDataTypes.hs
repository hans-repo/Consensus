{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
{-# LANGUAGE BangPatterns #-}

module ConsensusDataTypes (
    module ConsensusDataTypes,
    module Control.Lens,
    module Control.Distributed.Process.Serializable,
    fromMaybe,
    Random, randomR, newStdGen,
    Process, ProcessId,
    threadDelay,
    Binary
) where

import qualified Data.Map as Map
import qualified Data.Vector as V

import Control.Distributed.Process (Process, ProcessId)
import Control.Distributed.Process.Serializable
import Control.Monad.RWS.Strict (
    RWS, MonadReader, MonadWriter, MonadState)
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM)

import Data.Maybe
import Data.Binary -- Objects have to be binary to send over the network

import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization



import Control.Lens.Getter ( view, Getting )

import System.Random (StdGen, Random, randomR, newStdGen)
import Data.Foldable (find)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))

--commands sent by clients
-- data Command = Command {cmdId :: String, deliverTime :: Int, proposeTime :: Int}
--     deriving (Show, Generic, Typeable, Eq)

data DagInput = DagInput {dag :: [String], deliverTime :: Int, proposeTime :: Int }
    deriving (Show, Generic, Typeable, Eq)

--hash of a block
data BlockHash = BlockHash String
    deriving (Show, Generic, Typeable, Eq, Ord)

--placeholder cryptographic signature
data Signature = Signature String
    deriving (Show, Generic, Typeable, Eq)

-- --block datatype, contains list of commands, justifying quorum certificate qc, height, block hash, and parent block.
-- --Note that it references the entire blockchain through the parent block link
-- data Block = Block {content :: [Command], height :: Int, blockHash :: BlockHash, parent :: [Block]}
--     deriving (Show, Generic, Typeable, Eq)

-- genesisBlock :: Block 
-- genesisBlock = Block {content = [], height = 0, blockHash = BlockHash "genesis", parent = []}

-- --block datatype linking to the hash of the parent instead of the entire blockchain as in Block.
-- data SingleBlock = SingleBlock {contentS :: V.Vector Command, heightS :: Int, blockHashS :: BlockHash, parentS :: [BlockHash]}
--     deriving (Show, Generic, Typeable, Eq)

-- genesisBlockSingle :: SingleBlock
-- genesisBlockSingle = SingleBlock {contentS = V.fromList [], heightS = 0, blockHashS = BlockHash "genesis", parentS = []}


--message types between nodes. CommandMsg for client commands, DeliverCmd to share confirmed commands and the block height. VoteMsg for votes in chained hotstuff. ProposeMsg for leader proposals. NewViewMsg is the new view sent by replicas upon timeout.
data MessageType = DeliverMsg {tickLatency :: Int, deliverCommands :: DagInput} | ProposeMsg {proposal :: DagInput} | VoteMsg {vote :: DagInput, proposes :: [DagInput]}
    deriving (Show, Generic, Typeable, Eq)

--generic message for networking between processes.
data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: MessageType}
               deriving (Show, Generic, Typeable)

data ServerTick = ServerTick Double deriving (Show, Generic, Typeable, Eq)

data ClientTick = ClientTick Double deriving (Show, Generic, Typeable, Eq)

instance Binary DagInput
instance Binary Signature
instance Binary BlockHash
-- instance Binary Command
instance Binary MessageType
instance Binary Message
instance Binary ServerTick
instance Binary ClientTick

data ClientState = ClientState {
    _sentCount :: !Int, --number of sent commands
    _deliveredCount :: !Int, --number of delivered commands
    _lastDelivered :: !(V.Vector DagInput), --last batch of delivered commands
    _currLatency :: !Double, --height of last received confirmed block
    _randomGenCli :: !StdGen, --last random number generation
    _clientBatchSize :: !Int, ----size of delivered batches, same as server batchSize
    _timerPosixCli :: Double, --last timer in POSIX double
    _tickCount :: !Int --tick counter
} deriving (Show, Eq)
makeLenses ''ClientState

data ServerState = ServerState {
    _phase :: String,
    _proposeList :: [DagInput], --list of received proposals
    _voteList :: [DagInput], --list of received votes
    _timerPosix :: !Double, --last timer in POSIX double
    _randomGen :: StdGen, --last random number generation
    _serverTickCount :: Int --tick counter
} deriving (Show)
makeLenses ''ServerState

data ServerConfig = ServerConfig {
    myId  :: ProcessId, --id of server
    peers :: [ProcessId], --list of server peers
    staticSignature :: Signature, --placeholder cryptographic signature
    timeout :: Int, --number of ticks to trigger Delta
    timePerTick :: Int, --number of microseconds per tick
    clients :: [ProcessId] --list of clients
} deriving (Show)


newtype ClientAction a = ClientAction {runClientAction :: RWS ServerConfig [Message] ClientState a}
    deriving (Functor, Applicative, Monad, MonadState ClientState,
              MonadWriter [Message], MonadReader ServerConfig)

newtype ServerAction a = ServerAction {runAction :: RWS ServerConfig [Message] ServerState a}
    deriving (Functor, Applicative, Monad, MonadState ServerState,
              MonadWriter [Message], MonadReader ServerConfig)
