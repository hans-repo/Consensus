{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
import qualified Data.Map as Map
import qualified Data.Vector as V
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)
import Control.Distributed.Process.Serializable (Serializable)
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

--commands sent by clients
data Command = Command {cmdId :: String, deliverTime :: Int, proposeTime :: Int}
    deriving (Show, Generic, Typeable, Eq)

--hash of a block
data BlockHash = BlockHash String | TimeoutView Int
    deriving (Show, Generic, Typeable, Eq, Ord)

--placeholder cryptographic signature
data Signature = Signature String
    deriving (Show, Generic, Typeable, Eq)

--block datatype, contains list of commands, justifying quorum certificate qc, height, block hash, and parent block.
--Note that it references the entire blockchain through the parent block link
data Block = Block {content :: [Command], qc :: QC, height :: Int, blockHash :: BlockHash, parent :: [Block]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlock :: Block 
genesisBlock = Block {content = [], qc = genesisQC, height = 0, blockHash = BlockHash "genesis", parent = []}


--block datatype linking to the hash of the parent instead of the entire blockchain as in Block.
data SingleBlock = SingleBlock {contentS :: [Command], qcS :: QC, heightS :: Int, blockHashS :: BlockHash, parentS :: BlockHash}
    deriving (Show, Generic, Typeable, Eq)

--Quorum certificate, list of signatures and hash of signed block.
data QC = QC {signatures :: [Signature], hash :: BlockHash}
    deriving (Show, Generic, Typeable, Eq)

--see initialization of event-driven Hotstuff.
genesisQC :: QC 
genesisQC = QC {signatures = [], hash = BlockHash "genesis"}
genesisQCHigh :: QC 
genesisQCHigh = QC {signatures = [], hash = BlockHash "genesis"}

--message types between nodes. CommandMsg for client commands, DeliverCmd to share confirmed commands and the block height. VoteMsg for votes in chained hotstuff. ProposeMsg for leader proposals. NewViewMsg is the new view sent by replicas upon timeout.
data MessageType = CommandMsg Command | DeliverMsg {deliverHeight :: Int, deliverCommands :: [Command]} | VoteMsg {votedBlock :: BlockHash, sign :: Signature} | ProposeMsg {proposal :: SingleBlock, pView :: Int} | NewViewMsg {newViewQC :: QC, newViewId :: Int, newViewSign :: Signature}
    deriving (Show, Generic, Typeable)

--generic message for networking between processes.
data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: MessageType}
               deriving (Show, Generic, Typeable)

data Tick = Tick deriving (Show, Generic, Typeable, Eq)

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
    _sentCount :: Int, --number of sent commands
    _deliveredCount :: Int, --number of delivered commands
    -- _lastDelivered :: [Command], --last batch of delivered commands
    _lastDelivered :: V.Vector Command,
    _rHeight :: Int, --height of last received confirmed block
    _randomGenCli :: StdGen, --last random number generation
    _msgRate :: Int, --received batch sizes
    _tickCount :: Int --tick counter
} deriving (Show, Eq)
makeLenses ''ClientState

data ServerState = ServerState {
    _vHeight :: Int, --view height
    _cView :: Int, --current view
    _bLock :: Block, --Locked block
    _bExec :: Block, --Last executed block
    _bLeaf :: Block, --recent leaf
    _bRecent :: [Block], --list of received blocks
    _qcHigh :: QC, --highest received quorum certificate
    _voteList :: Map.Map BlockHash [Signature], --list of received votes
    _ticksSinceMsg :: Map.Map ProcessId Int, --time ticks since receiving a message, used as timer
    _mempool :: [Command], --list of unconfirmed commands
    _batchSize :: !Int, --number of commands per block
    _randomGen :: StdGen, --last random number generation
    _serverTickCount :: Int
} deriving (Show)
makeLenses ''ServerState

data ServerConfig = ServerConfig {
    myId  :: ProcessId, --id of server
    peers :: [ProcessId], --list of server peers
    staticSignature :: Signature, --placeholder cryptographic signature
    timeout :: Int, --number of ticks to timeout
    clients :: [ProcessId] --list of clients
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
    ServerState _ cView bLock _ bLeafOld bRecentOld qcHigh _ _ mempool batchSize _ serverTickCount<- get
    mempoolBlock <- createBatch serverTickCount batchSize
    let block = Block {content = V.toList mempoolBlock, qc = qcHigh, height = cView + 1, blockHash = BlockHash (show hash), parent = [bLeafOld]}
    bLeaf .= block
    bRecent .= appendIfNotExists block bRecentOld
    let singleBlock = SingleBlock {contentS = V.toList mempoolBlock, qcS = qcHigh, heightS = cView + 1, blockHashS = BlockHash (show hash), parentS = blockHash bLeafOld}
    broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cView})

createBatch :: Int -> Int -> ServerAction (V.Vector Command)
createBatch serverTickCount size = do
    let go i !acc | i >= size = return acc
                    | otherwise = do
                        commandInt <- randomWithin (0, maxBound :: Int)
                        let commandString = show commandInt
                            newCmd = Command {cmdId = commandString, deliverTime = 0, proposeTime = serverTickCount}
                        go (i + 1) $! (acc `V.snoc` newCmd)
    go 0 V.empty

onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNewSingle pView = do 
    ServerState vHeightOld cViewOld bLock _ _ bRecentOld _ _ _ mempoolOld _ _ _<- get
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


onReceiveVote :: BlockHash -> Signature -> ServerAction ()
onReceiveVote bNewHash sign = do 
    ServerState _ _ _ _ _ bRecent _ voteListOld _ _ _ _ _<- get
    let bNew = findBlock bNewHash bRecent
        votesB = fromMaybe [] (Map.lookup (blockHash bNew) voteListOld)
    let actionAddToList | sign `elem` votesB = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (blockHash bNew) [sign] voteListOld                              
    actionAddToList
    -- get state again for the new voteList
    ServerState _ _ _ _ _ _ _ voteListNew ticksSinceMsg _ _ _ _<- get
    let votesBNew = fromMaybe [] (Map.lookup (blockHash bNew) voteListNew)
        quorum = 2 * div (Map.size ticksSinceMsg) 3 + 1
    let action  | length votesBNew >= quorum = do updateQCHigh $ QC {signatures = votesBNew, hash = blockHash bNew}
                | otherwise = return ()
    action

onCommit :: Block -> Block -> ServerAction ()
onCommit bExec b = do 
    let action | height bExec < height b = do onCommit bExec (head (parent b))
                                              execute (height bExec) (content b)
               | otherwise = return ()
    action

 -- confirm delivery to all clients and servers
execute :: Int -> [Command] -> ServerAction ()
execute height cmds = do 
    ServerConfig _ _ _ _ clients<- ask
    ServerState _ _ _ _ _ _ _ _ _ mempoolOld _ _ ticks<- get
    mempool .= filter (`notElem` cmds) mempoolOld
    let deliveredCmds = map (setDeliverTime ticks) cmds
    broadcastAll clients (DeliverMsg {deliverCommands = deliveredCmds, deliverHeight = height})
    
setDeliverTime :: Int -> Command -> Command
setDeliverTime tickCount cmd = Command {cmdId = cmdId cmd, deliverTime = tickCount, proposeTime = proposeTime cmd}


--Need to input the latest block so that findBlock doesn't search from bLeaf which isn't updated yet
updateQCHigh :: QC -> ServerAction ()
updateQCHigh qc = do
    ServerState _ _ _ _ _ bRecent qcHighOld _ _ _ _ _ _<- get
    let qcNode = findBlock (hash qc) bRecent
        qcNodeOld = findBlock (hash qcHighOld) bRecent
        action  | height qcNode > height qcNodeOld = do qcHigh .= qc
                                                        bLeaf .= qcNode
                | otherwise = return ()
    action

updateChain :: Block -> ServerAction ()
updateChain bStar = do 
    ServerState _ _ bLockOld bExecOld _ bRecent qcHigh _ _ _ _ _ _<- get
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


-- Pacemaker from paper
getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)

onNextSyncView :: ServerAction ()
onNextSyncView = do 
    ServerState _ cViewOld _ _ _ _ qcHigh _ _ _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _<- ask
    -- next view, reset timers for all peers
    cView += 1
    ticksSinceMsg .= Map.fromList [(key, 0) | key <- peers]
    sendSingle myPid (getLeader peers (1+ cViewOld)) (NewViewMsg {newViewQC= qcHigh, newViewId = cViewOld, newViewSign = staticSignature}) 

onReceiveNewView :: Int -> QC -> Signature -> ServerAction ()
onReceiveNewView view qc sign = do 
    ServerState _ _ _ _ _ _ _ voteListOld ticksSinceMsg _ _ _ _ <- get
    let quorum = 2 * div (Map.size ticksSinceMsg) 3 + 1 
        votes = voteListOld
        votesT = fromMaybe [] (Map.lookup (TimeoutView view) votes)
    let actionAddToList | sign `elem` votesT = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (TimeoutView view) [sign] voteListOld
    actionAddToList
    updateQCHigh qc

-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState _ cView _ _ bLeaf _ _ voteList ticksSinceMsgOld _ _ _ _<- get
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
    serverTickCount += 1


-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive commands from client
msgHandler (Message sender recipient (CommandMsg cmd)) = do
    ServerState _ _ _ _ _ _ _ _ _ mempoolOld _ _ _ <- get
    mempool .= cmd:mempoolOld
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg bNew pView)) = do 
    --handle proposal
    onReceiveProposal bNew pView
msgHandler (Message sender recipient (VoteMsg b sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _<- ask
    onReceiveVote b sign
msgHandler (Message sender recipient (NewViewMsg qc view sign)) = do
    --handle new view message
    onReceiveNewView view qc sign

--Client behavior
--continuously send commands from client to all servers
tickClientHandler :: Tick -> ClientAction ()
tickClientHandler Tick = do
    ServerConfig myPid peers _ _ _ <- ask
    ClientState _ _ lastDeliveredOld lastHeight _ cmdRate tick <- get
    -- let n = 1
    -- sendNCommands n tick peers
    -- sentCount += n
    tickCount += 1
    if V.length lastDeliveredOld > cmdRate
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate) lastDeliveredOld
        else return ()

sendNCommands :: Int -> Int -> [ProcessId] -> ClientAction ()
sendNCommands 0 _ _ = return ()
sendNCommands n tick peers = do sendSingleCommand peers tick
                                sendNCommands (n-1) tick peers

sendSingleCommand :: [ProcessId] -> Int -> ClientAction ()
sendSingleCommand peers tick = do 
    let bound1 :: Int
        bound1 = maxBound
    command <- randomWithinClient (0, bound1)
    let commandString = show command
    broadcastAllClient peers (CommandMsg (Command {cmdId = commandString, proposeTime = tick, deliverTime = 0}))
    sentCount += 1

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient delivered) = do
    ClientState _ _ lastDeliveredOld lastHeight _ _ _<- get
    let deliverCmds = V.fromList $ deliverCommands delivered
    let action
            -- | lastHeight < deliverHeight delivered = do rHeight += 1
            --                                             deliveredCount += length (deliverCommands delivered)
            --                                             lastDelivered .= deliverCommands delivered
            -- | otherwise = return ()
            | not $ isSubset deliverCmds lastDeliveredOld = do deliveredCount += V.length deliverCmds
                                                               lastDelivered .= lastDeliveredOld V.++ deliverCmds
            | otherwise = return ()
    action

isSubset :: (Eq a) => V.Vector a -> V.Vector a -> Bool
isSubset smaller larger =
    V.all (\x -> isJust $ V.find (== x) larger) smaller




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

sendWithDelay :: (Serializable a) => Int -> ProcessId -> a -> Process ()
sendWithDelay delay recipient msg = do
    liftIO $ threadDelay delay
    send recipient msg

-- network stack (impure)
spawnServer :: Int -> Process ProcessId
spawnServer batchSize = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers " ++ show otherPids
    clientPids <- expect
    say $ "received clients " ++ show clientPids
    let tickTime = 10^5
        timeoutMicroSeconds = 10*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 0 genesisBlock genesisBlock genesisBlock [genesisBlock] genesisQCHigh Map.empty (Map.fromList [(key, 0) | key <- otherPids]) [] batchSize randomGen 0)

spawnClient :: Int -> Process ProcessId
spawnClient cmdRate = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers at client" ++ show otherPids
    clientPids <- expect
    let tickTime = 10^5
        timeoutMicroSeconds = 2*10^6
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 (V.fromList []) 0 randomGen cmdRate 0)


spawnAll :: Int -> Int -> Int -> Int -> Int -> Process ()
spawnAll count crashCount clientCount cmdRate batchSize = do
    pids <- replicateM count (spawnServer batchSize)
    
    clientPids <- replicateM clientCount (spawnClient cmdRate)
    let allPids = pids ++ clientPids
    mapM_ (`send` pids) allPids
    say $ "sent servers " ++ show pids
    mapM_ (`send` clientPids) allPids
    say $ "sent clients " ++ show clientPids
    mapM_ (`kill` "crash node") (take crashCount pids)

runServer :: ServerConfig -> ServerState -> Process ()
runServer config state = do
    let run handler msg = return $ execRWS (runAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandler,
            match $ run tickServerHandler]
    
    let prints -- | False = return () --null outputMessages = return ()
               | null outputMessages = return ()
               | otherwise = do --say $ "Current state: " ++ show state' ++ "\n"
                                say $ "Sending Messages : " -- ++ show outputMessages ++ "\n"
    --prints
    let latency = 0*10^5
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages
    runServer config state'

-- Function to take the last x elements from a vector
lastXElements :: Int -> V.Vector a -> V.Vector a
lastXElements x vec = V.take x (V.drop (V.length vec - x) vec)


meanTickDifference :: V.Vector Command -> Int -> Double
meanTickDifference commands tick =
    let differences = map (\cmd -> fromIntegral (tick - proposeTime cmd)) (V.toList commands)
    -- let differences = map (\cmd -> fromIntegral (deliverTime cmd - proposeTime cmd)) (V.toList commands)
        total = sum differences
        count = length differences
    in if count == 0 then 0 else total / fromIntegral count

runClient :: ServerConfig -> ClientState -> Process ()
runClient config state = do
    let run handler msg = return $ execRWS (runClientAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandlerCli,
            match $ run tickClientHandler]
    let prints 
            | True = say $ "Current state: " ++ show state'++ "\n"
            | otherwise = return ()
    -- prints
    let throughput = fromIntegral (_deliveredCount state') / fromIntegral (_tickCount state') 
        meanLatency = meanTickDifference (lastXElements (_msgRate state') (_lastDelivered state')) (_tickCount state')
    let throughputPrint 
            -- | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty) = say $ "Current throughput: " ++ show throughput ++ "\n" ++ "deliveredCount: " ++ show (_deliveredCount state') ++ "\n" ++ "tickCount: " ++ show (_tickCount state') ++ "\n" ++ "lastDelivered: " ++ show (V.toList $ _lastDelivered state') ++ "\n"
            | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty)= say $ "Delivered commands " ++ show (_deliveredCount state')
            | otherwise = return ()
    let latencyPrint 
            | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty) = say $ "Current mean latency: " ++ show meanLatency ++ "\n"
            | otherwise = return ()
    let prints 
            | state' /= state = say $ "Current state: " ++ show state'++ "\n"
            | otherwise = return ()
    throughputPrint
    latencyPrint
    
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    runClient config state'

main = do
    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll 4 0 1 2 2) -- number of replicas, number of crashes, number of clients, cmdRate
    putStrLn "Push enter to exit"
    getLine