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

import Data.Maybe
import Data.Binary -- Objects have to be binary to send over the network

import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization



import Control.Lens.Getter ( view, Getting )

import System.Random (StdGen, Random, randomR, newStdGen)
import Data.Foldable (find)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))




--commands sent by clients
data Command = Command {cmdId :: !String, deliverTime :: !Int, proposeTime :: !Int}
    deriving (Show, Generic, Typeable, Eq)

--hash of a block
data BlockHash = BlockHash String | TimeoutView Int
    deriving (Show, Generic, Typeable, Eq, Ord)

--placeholder cryptographic signature
data Signature = Signature String
    deriving (Show, Generic, Typeable, Eq)

--block datatype, contains list of commands, justifying quorum certificate qc, height, block hash, and parent block.
--Note that it references the entire blockchain through the parent block link
data Block = Block {blockHash :: BlockHash, content :: [Command],qc :: QC, height :: Int, parent :: [Block]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlock :: Block 
genesisBlock = Block {content = [], qc = genesisQC, height = 0, blockHash = BlockHash "genesis", parent = []}

--block datatype linking to the hash of the parent instead of the entire blockchain as in Block.
data SingleBlock = SingleBlock {blockHashS :: BlockHash, contentS :: V.Vector Command, qcS :: QC, heightS :: Int, parentS :: [BlockHash]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlockSingle :: SingleBlock
genesisBlockSingle = SingleBlock {blockHashS = BlockHash "genesis", contentS = V.fromList [], qcS = genesisQC, heightS = 0, parentS = []}


--Quorum certificate, list of signatures and hash of signed block.
data QC = QC {hash :: BlockHash, signatures :: [Signature]}
    deriving (Show, Generic, Typeable, Eq)

--see initialization of event-driven Hotstuff.
genesisQC :: QC 
genesisQC = QC {signatures = [], hash = BlockHash "genesis"}
genesisQCHigh :: QC 
genesisQCHigh = QC {signatures = [], hash = BlockHash "genesis"}

--message types between nodes. CommandMsg for client commands, DeliverCmd to share confirmed commands and the block height. VoteMsg for votes in chained hotstuff. ProposeMsg for leader proposals. NewViewMsg is the new view sent by replicas upon timeout.
data MessageType = CommandMsg Command | DeliverMsg {deliverHeight :: Int, deliverCommands :: V.Vector Command} | VoteMsg {votedBlock :: BlockHash, sign :: Signature} | ProposeMsg {proposal :: SingleBlock, pView :: Int} | NewViewMsg {newViewQC :: QC, newViewId :: Int, newViewSign :: Signature}
    deriving (Show, Generic, Typeable)

--generic message for networking between processes.
data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: MessageType}
               deriving (Show, Generic, Typeable)

data Tick = Tick deriving (Show, Generic, Typeable, Eq)

instance Binary Signature
instance Binary BlockHash
instance Binary Command
instance Binary QC
instance Binary Block
-- instance Binary SingleBlock
instance Binary SingleBlock where
    put (SingleBlock blockHashS contentS qcS heightS  parentS) = do
        put (V.toList contentS)
        put qcS
        put heightS
        put blockHashS
        put parentS
    
    get = do
        contentList <- get
        qcS <- get
        heightS <- get
        blockHashS <- get
        parentS <- get
        return $ SingleBlock blockHashS (V.fromList contentList) qcS heightS  parentS
-- instance Binary MessageType
instance Binary MessageType where
    put (CommandMsg cmd) = do
        putWord8 0
        put cmd
    put (DeliverMsg height cmds) = do
        putWord8 1
        put height
        put (V.toList cmds)
    put (ProposeMsg proposal view) = do
        putWord8 2
        put proposal
        put view
    put (NewViewMsg newViewQC newViewId newViewSign) = do
        putWord8 2
        put newViewQC
        put newViewId
        put newViewSign
    put (VoteMsg block sign) = do
        putWord8 5
        put block
        put sign

    get = do
        tag <- getWord8
        case tag of
            0 -> CommandMsg <$> get
            1 -> do
                height <- get
                cmdList <- get
                return $ DeliverMsg height (V.fromList cmdList)
            2 -> ProposeMsg <$> get <*> get
            4 -> NewViewMsg <$> get <*> get <*> get
            5 -> VoteMsg <$> get <*> get
            _ -> fail "Invalid MessageType tag"
instance Binary Message
instance Binary Tick

data ClientState = ClientState {
    _sentCount :: !Int, --number of sent commands
    _deliveredCount :: !Int, --number of delivered commands
    _lastDelivered :: !(V.Vector Command), --last batch of delivered commands
    _rHeight :: !Int, --height of last received confirmed block
    _randomGenCli :: !StdGen, --last random number generation
    _clientBatchSize :: !Int, --size of delivered batches, same as server batchSize
    _tickCount :: !Int --tick counter
} deriving (Show, Eq)
makeLenses ''ClientState


data ServerState = ServerState {
    _vHeight :: !Int, --view height
    _cView :: !Int, --current view
    _bLock :: !SingleBlock, --Locked block
    _bExec :: !SingleBlock, --Last executed block
    _bLeaf :: !SingleBlock, --recent leaf
    _bRecent :: ![SingleBlock], --list of received blocks
    _qcHigh :: !QC, --highest received quorum certificate
    _voteList :: !(Map.Map BlockHash [Signature]), --list of received votes
    _ticksSinceMsg :: !(Map.Map ProcessId Int), --time ticks since receiving a message, used as timer
    _batchSize :: !Int, --number of commands per block
    _serverTickCount :: !Int, --tick count since start
    _randomGen :: !StdGen --last random number generation
} deriving (Show)
makeLenses ''ServerState

data ServerConfig = ServerConfig {
    myId  :: ProcessId, --id of server
    peers :: [ProcessId], --list of server peers
    staticSignature :: Signature, --placeholder cryptographic signature
    timeout :: Int, --number of ticks to timeout
    clients :: [ProcessId] --list of clients
} deriving (Show)


newtype ClientAction a = ClientAction {runClientAction :: RWS ServerConfig [Message] ClientState a}
    deriving (Functor, Applicative, Monad, MonadState ClientState,
              MonadWriter [Message], MonadReader ServerConfig)

newtype ServerAction a = ServerAction {runAction :: RWS ServerConfig [Message] ServerState a}
    deriving (Functor, Applicative, Monad, MonadState ServerState,
              MonadWriter [Message], MonadReader ServerConfig)

