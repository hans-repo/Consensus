{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
import qualified Data.Map as Map
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)

import Data.Maybe
import Data.Binary (Binary) -- Objects have to be binary to send over the network
import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization

import Control.Monad.RWS.Strict (
    RWS, MonadReader, MonadWriter, MonadState, ask, tell, get, execRWS, liftIO)
import Control.Monad (replicateM, forever)
import Control.Concurrent (threadDelay)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))
import Control.Lens.Getter ( view, Getting )

import System.Random (StdGen, Random, randomR, newStdGen)
import Data.Foldable (find)

data Command = Command String
    deriving (Show, Generic, Typeable, Eq)

data BlockHash = BlockHash String | TimeoutView Int
    deriving (Show, Generic, Typeable, Eq, Ord)

data Signature = Signature String
    deriving (Show, Generic, Typeable, Eq)

data Block = Block {content :: [Command], qc :: QC, height :: Int, blockHash :: BlockHash, parent :: [Block]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlock :: Block 
genesisBlock = Block {content = [], qc = genesisQC, height = 0, blockHash = BlockHash "genesis", parent = []}



data SingleBlock = SingleBlock {contentS :: [Command], qcS :: QC, heightS :: Int, blockHashS :: BlockHash, parentS :: BlockHash}
    deriving (Show, Generic, Typeable, Eq)


data QC = QC {signatures :: [Signature], hash :: BlockHash}
    deriving (Show, Generic, Typeable, Eq)

--see initialization of event-driven Hotstuff.
genesisQC :: QC 
genesisQC = QC {signatures = [], hash = BlockHash "genesis"}
genesisQCHigh :: QC 
genesisQCHigh = QC {signatures = [], hash = BlockHash "genesis"}

data MessageType = CommandMsg Command | DeliverCmd {deliverHeight :: Int, numCommands :: Int} | VoteMsg {votedBlock :: BlockHash, sign :: Signature} | ProposeMsg {proposal :: SingleBlock, pView :: Int} | NewViewMsg {newViewQC :: QC, newViewId :: Int, newViewSign :: Signature}
    deriving (Show, Generic, Typeable)


data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: MessageType}
               deriving (Show, Generic, Typeable)

data Tick = Tick deriving (Show, Generic, Typeable)

instance Binary Signature
instance Binary BlockHash
instance Binary QC
instance Binary Command
instance Binary Block
instance Binary SingleBlock
instance Binary MessageType
instance Binary Message
instance Binary Tick

data ClientState = ClientState {
    _sentCount :: Int,
    _deliveredCount :: Int,
    _rHeight :: Int,
    _randomGenCli :: StdGen
} deriving (Show)
makeLenses ''ClientState

data ServerState = ServerState {
    _vHeight :: Int,
    _cView :: Int,
    _bLock :: Block,
    _bExec :: Block,
    _bLeaf :: Block,
    _bRecent :: [Block],
    _qcHigh :: QC,
    _voteList :: Map.Map BlockHash [Signature],
    _ticksSinceMsg :: Map.Map ProcessId Int,
    _mempool :: [Command],
    _randomGen :: StdGen
} deriving (Show)
makeLenses ''ServerState

data ServerConfig = ServerConfig {
    myId  :: ProcessId,
    peers :: [ProcessId],
    staticSignature :: Signature,
    timeout :: Int,
    clients :: [ProcessId]
} deriving (Show)


randomWithinClient :: Random r => (r,r) -> ClientAction r
randomWithinClient bounds = randomGenCli %%= randomR bounds

randomWithin :: Random r => (r,r) -> ServerAction r
randomWithin bounds = randomGen %%= randomR bounds

newtype ClientAction a = ClientAction {runClientAction :: RWS ServerConfig [Message] ClientState a}
    deriving (Functor, Applicative, Monad, MonadState ClientState,
              MonadWriter [Message], MonadReader ServerConfig)

newtype ServerAction a = ServerAction {runAction :: RWS ServerConfig [Message] ServerState a}
    deriving (Functor, Applicative, Monad, MonadState ServerState,
              MonadWriter [Message], MonadReader ServerConfig)


findBlock :: BlockHash -> [Block] -> Block 
findBlock h [b,_] = findBlockDepth h b
findBlock h (b:bs) | h == blockHash b = b 
                   | otherwise = findBlock h bs 
                
findBlockDepth :: BlockHash -> Block -> Block
findBlockDepth h b | h == blockHash b = b 
                   | b == genesisBlock = genesisBlock
                   | otherwise = findBlockDepth h (head $ parent b)

singleToFull :: SingleBlock -> [Block] -> Block
singleToFull sb bRecent = let parentBlock = findBlock (parentS sb) bRecent
                   in Block {content = contentS sb, qc = qcS sb, height = heightS sb, blockHash = blockHashS sb, parent = [parentBlock]}

appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list


-- Event driven Hotstuff
onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState _ cView bLock _ bLeafOld bRecentOld qcHigh _ _ mempool _ <- get
    let block = Block {content = mempool, qc = qcHigh, height = cView + 1, blockHash = BlockHash (show hash), parent = [bLeafOld]}
    bLeaf .= block
    bRecent .= appendIfNotExists block bRecentOld
    let singleBlock = SingleBlock {contentS = mempool, qcS = qcHigh, heightS = cView + 1, blockHashS = BlockHash (show hash), parentS = blockHash bLeafOld}
    broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cView})

onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNewSingle pView = do 
    ServerState vHeightOld cViewOld bLock _ _ bRecentOld _ _ _ mempoolOld _ <- get
    ServerConfig myPid peers staticSignature _ _<- ask
    let bNew = singleToFull bNewSingle bRecentOld 
        action | (height bNew > vHeightOld) && ( hash (qc bNew) == blockHash bLock || height bNew > height bLock) = do
                                -- next view, reset timers for all peers
                                cView += 1
                                ticksSinceMsg .= Map.fromList [(key, 0) | key <- peers]
                                vHeight .= height bNew
                                sendSingle myPid (getLeader peers (1+ cViewOld)) (VoteMsg {votedBlock = blockHash bNew, sign = staticSignature})
               | otherwise = return ()
    action
    bRecent .= appendIfNotExists bNew bRecentOld
    updateChain bNew
    mempool .= filter (`notElem` content bNew) mempoolOld


onReceiveVote :: Int -> BlockHash -> Signature -> ServerAction ()
onReceiveVote quorum bNewHash sign = do 
    ServerState _ _ _ _ _ bRecent qcHigh voteListOld _ _ _ <- get
    let bNew = findBlock bNewHash bRecent
        votes = voteListOld
        votesB = fromMaybe [] (Map.lookup (blockHash bNew) votes)
    let actionAddToList | sign `elem` votesB = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (blockHash bNew) [sign] voteListOld
    actionAddToList
    let action  | length votesB >= quorum = do updateQCHigh $ QC {signatures = votesB, hash = blockHash bNew}
                | otherwise = return ()
    action

updateChain :: Block -> ServerAction ()
updateChain bStar = do 
    ServerState _ _ bLockOld bExecOld _ bRecent qcHigh _ _ _ _ <- get
    updateQCHigh $ qc bStar
    let b'' = findBlock (hash $ qc bStar) bRecent
        b'  = findBlockDepth (hash $ qc b'') b''
        b   = findBlockDepth (hash $ qc b') b'
        actionL | height b' > height bLockOld = do bLock .= b'
                | otherwise = return ()
        actionC | (parent b'' == [b']) && (parent b' == [b]) = do onCommit bExecOld b 
                                                                  bExec .= b
                | otherwise = return ()
    actionL 
    actionC 

onCommit :: Block -> Block -> ServerAction ()
onCommit bExec b = do 
    let action | height bExec < height b = do onCommit bExec (head (parent b))
                                              execute (height bExec) (content b)
               | otherwise = return ()
    action


-- Pacemaker from paper
getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)


--Need to input the latest block so that findBlock doesn't search from bLeaf which isn't updated yet
updateQCHigh :: QC -> ServerAction ()
updateQCHigh qc = do
    ServerState _ _ _ _ _ bRecent qcHighOld _ _ _ _ <- get
    let qcNode = findBlock (hash qc) bRecent
        qcNodeOld = findBlock (hash qcHighOld) bRecent
        action  | height qcNode > height qcNodeOld = do qcHigh .= qc
                                                        bLeaf .= qcNode
                | otherwise = return ()
    action

onNextSyncView :: ServerAction ()
onNextSyncView = do 
    ServerState _ cViewOld _ _ _ _ qcHigh _ _ _ _ <- get
    ServerConfig myPid peers staticSignature _ _<- ask
    -- next view, reset timers for all peers
    cView += 1
    ticksSinceMsg .= Map.fromList [(key, 0) | key <- peers]
    sendSingle myPid (getLeader peers (1+ cViewOld)) (NewViewMsg {newViewQC= qcHigh, newViewId = cViewOld, newViewSign = staticSignature}) 


onReceiveNewView :: Int -> Int -> QC -> Signature -> ServerAction ()
onReceiveNewView quorum view qc sign = do 
    ServerState _ _ _ _ _ _ _ voteListOld _ _ _ <- get
    let votes = voteListOld
        votesT = fromMaybe [] (Map.lookup (TimeoutView view) votes)
    let actionAddToList | sign `elem` votesT = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (TimeoutView view) [sign] voteListOld
    actionAddToList
    updateQCHigh qc

 -- confirm delivery to all clients and servers
execute :: Int -> [Command] -> ServerAction ()
execute height cmds = do 
    ServerConfig _ _ _ _ clients<- ask
    ServerState _ _ _ _ _ _ _ _ _ mempoolOld _ <- get
    mempool .= filter (`notElem` cmds) mempoolOld
    broadcastAll clients (DeliverCmd {numCommands = length cmds, deliverHeight = height})
    

-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState _ cView _ _ bLeaf _ _ voteList ticksSinceMsgOld _ _ <- get
    --increment ticks for every peer
    ticksSinceMsg .= Map.map (+1) ticksSinceMsgOld

    let leader = getLeader peers cView
        quorum = 2 * div (length peers) 3 + 1
        votesB = fromMaybe [] (Map.lookup (blockHash bLeaf) voteList)
        votesT = fromMaybe [] (Map.lookup (TimeoutView (cView-1)) voteList)
    let actionLead
    -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
            | leader == myPid && (length votesB >= quorum || length votesT >= quorum || bLeaf == genesisBlock) = onPropose
            | otherwise = return ()
    actionLead
    let actionNewView 
            | Map.findWithDefault 0 leader ticksSinceMsgOld > timeout = onNextSyncView
            | otherwise = return ()
    actionNewView


-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive commands from client
msgHandler (Message sender recipient (CommandMsg cmd)) = do
    ServerState _ _ _ _ _ _ _ _ _ mempoolOld _  <- get
    mempool .= cmd:mempoolOld
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg bNew pView)) = do 
    --handle proposal
    onReceiveProposal bNew pView
msgHandler (Message sender recipient (VoteMsg b sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _<- ask
    let quorum = 2 * div (length peers) 3 + 1
    onReceiveVote quorum b sign
msgHandler (Message sender recipient (NewViewMsg qc view sign)) = do
    --handle new view message
    ServerConfig _ peers _ _ _<- ask
    let quorum = 2 * div (length peers) 3 + 1
    onReceiveNewView quorum view qc sign

--Client behavior
--continuously send commands from client to all servers
tickClientHandler :: Tick -> ClientAction ()
tickClientHandler Tick = do
    ServerConfig myPid peers _ _ _<- ask
    let n = 2
    sendNCommands n peers
    sentCount += n

sendNCommands :: Int -> [ProcessId] -> ClientAction ()
sendNCommands 0 _ = return ()
sendNCommands n peers = do sendSingleCommand peers
                           sendNCommands (n-1) peers

sendSingleCommand :: [ProcessId] -> ClientAction ()
sendSingleCommand peers = do 
    let bound1 :: Int
        bound1 = maxBound
    command <- randomWithinClient (0, bound1)
    let commandString = show command
    broadcastAllClient peers (CommandMsg (Command commandString))
    sentCount += 1

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient delivered) = do
    ClientState _ _ lastHeight _ <- get
    let action
            | lastHeight < deliverHeight delivered = do rHeight += 1
                                                        deliveredCount += numCommands delivered
            | otherwise = return ()
    action




-- Broadcasting
broadcastAll :: [ProcessId] -> MessageType -> ServerAction ()
broadcastAll [single] content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
broadcastAll (single:recipients) content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
    broadcastAll recipients content

sendSingle :: ProcessId -> ProcessId -> MessageType -> ServerAction ()
sendSingle myId single content = do
    tell [Message myId single content]

broadcastAllClient :: [ProcessId] -> MessageType -> ClientAction ()
broadcastAllClient [single] content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
broadcastAllClient (single:recipients) content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
    broadcastAllClient recipients content


-- network stack (impure)
spawnServer :: Process ProcessId
spawnServer = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers " ++ show otherPids
    clientPids <- expect
    say $ "received clients " ++ show clientPids
    let tickTime = 10^6
        timeoutMicroSeconds = 5*10^6
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 0 genesisBlock genesisBlock genesisBlock [genesisBlock] genesisQCHigh Map.empty (Map.fromList [(key, 0) | key <- otherPids]) [] randomGen)

spawnClient :: Process ProcessId
spawnClient = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers at client" ++ show otherPids
    clientPids <- expect
    let tickTime = 10^6
        timeoutMicroSeconds = 2*10^6
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 0 randomGen)


spawnAll :: Int -> Int -> Process ()
spawnAll count clientCount = do
    pids <- replicateM count spawnServer
    
    clientPids <- replicateM clientCount spawnClient
    let allPids = pids ++ clientPids
    mapM_ (`send` pids) allPids
    say $ "sent servers " ++ show pids
    mapM_ (`send` clientPids) allPids
    say $ "sent clients " ++ show clientPids
    kill (head pids) "crashed first leader"

runServer :: ServerConfig -> ServerState -> Process ()
runServer config state = do
    let run handler msg = return $ execRWS (runAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandler,
            match $ run tickServerHandler]
    
    let prints -- | False = return () --null outputMessages = return ()
               | null outputMessages = return ()
               | otherwise = do --say $ "Current state: " ++ show state' ++ "\n"
                                say $ "Sending Messages : " ++ show outputMessages ++ "\n"
    prints
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    runServer config state'

runClient :: ServerConfig -> ClientState -> Process ()
runClient config state = do
    let run handler msg = return $ execRWS (runClientAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandlerCli,
            match $ run tickClientHandler]
    say $ "Current state: " ++ show state'++ "\n"
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    runClient config state'

main = do
    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll 5 1)
    putStrLn "Push enter to exit"
    getLine