{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
import qualified Data.Map as Map
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)
import Control.Distributed.Process.Serializable
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
data Command = Command {cmdId :: String, sentTime :: Int}
    deriving (Show, Generic, Typeable, Eq)

--hash of a block
data BlockHash = BlockHash String | TimeoutView Int
    deriving (Show, Generic, Typeable, Eq, Ord)

--placeholder cryptographic signature
data Signature = Signature String
    deriving (Show, Generic, Typeable, Eq)

--block datatype, contains list of commands, justifying quorum certificate qc, height, block hash, and parent block.
--Note that it references the entire blockchain through the parent block link
data Block = Block {content :: [Command], height :: Int, blockHash :: BlockHash, parent :: [Block]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlock :: Block 
genesisBlock = Block {content = [], height = 0, blockHash = BlockHash "genesis", parent = []}


--block datatype linking to the hash of the parent instead of the entire blockchain as in Block.
data SingleBlock = SingleBlock {contentS :: [Command], heightS :: Int, blockHashS :: BlockHash, parentS :: BlockHash}
    deriving (Show, Generic, Typeable, Eq)

--message types between nodes. CommandMsg for client commands, DeliverCmd to share confirmed commands and the block height. VoteMsg for votes in chained hotstuff. ProposeMsg for leader proposals. NewViewMsg is the new view sent by replicas upon timeout.
data MessageType = CommandMsg Command | DeliverMsg {deliverHeight :: Int, deliverCommands :: [Command]} | ProposeMsg {proposal :: SingleBlock, pView :: Int} | EchoMsg {echoBlock :: BlockHash, sign :: Signature}  | TallyMsg {tallyBlock :: BlockHash, tallyNumber :: Int, sign :: Signature} | VoteMsg {voteBlock :: BlockHash, sign :: Signature}
    deriving (Show, Generic, Typeable)

--generic message for networking between processes.
data Message = Message {senderOf :: ProcessId, recipientOf :: ProcessId, msg :: MessageType}
               deriving (Show, Generic, Typeable)

data Tick = Tick deriving (Show, Generic, Typeable, Eq)

instance Binary Signature
instance Binary BlockHash
instance Binary Command
instance Binary Block
instance Binary SingleBlock
instance Binary MessageType
instance Binary Message
instance Binary Tick

data ClientState = ClientState {
    _sentCount :: Int, --number of sent commands
    _deliveredCount :: Int, --number of delivered commands
    _lastDelivered :: [Command], --last batch of delivered commands
    _rHeight :: Int, --height of last received confirmed block
    _randomGenCli :: StdGen, --last random number generation
    _tickCount :: Int --tick counter
} deriving (Show)
makeLenses ''ClientState

data ServerState = ServerState {
    _cView :: Int, --current view
    _bLock :: Block, --Locked block
    _bExec :: Block, --Last executed block
    _bLeaf :: Block, --recent leaf
    _bRecent :: [Block], --list of received blocks
    _echoList :: Map.Map BlockHash [Signature], --list of received echoes
    _tallyList :: Map.Map BlockHash [Int], --list of received tallies
    _voteList :: Map.Map BlockHash [Signature], --list of received votes
    _phase :: String, --phase of protocol, echo, tally, vote, decide
    _ticksSinceSend :: Int, --time ticks since last broadcast, used as timer
    _mempool :: [Command], --list of unconfirmed commands
    _randomGen :: StdGen --last random number generation
} deriving (Show)
makeLenses ''ServerState

data ServerConfig = ServerConfig {
    myId  :: ProcessId, --id of server
    peers :: [ProcessId], --list of server peers
    staticSignature :: Signature, --placeholder cryptographic signature
    timeout :: Int, --number of ticks for next communication step
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
                   in Block {content = contentS sb, height = heightS sb, blockHash = blockHashS sb, parent = [parentBlock]}

appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list




onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNewSingle pView = do 
    ServerState cViewOld bLock _ _ bRecentOld _ _ _ _ _ mempoolOld _ <- get
    ServerConfig myPid peers staticSignature _ _<- ask
    let bNew = singleToFull bNewSingle bRecentOld 
    bRecent .= appendIfNotExists bNew bRecentOld
    bLeaf .= bNew
    mempool .= filter (`notElem` content bNew) mempoolOld
    phase .= "echo"


onReceiveVote :: BlockHash -> Signature -> ServerAction ()
onReceiveVote bNewHash sign = do 
    ServerState _ _ _ _ bRecent _ _ voteListOld _ _ _ _ <- get
    let bNew = findBlock bNewHash bRecent
        votesB = fromMaybe [] (Map.lookup (blockHash bNew) voteListOld)
    let actionAddToList | sign `elem` votesB = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (blockHash bNew) [sign] voteListOld                              
    actionAddToList
    phase .= "decide"

onReceiveEcho :: BlockHash -> Signature -> ServerAction ()
onReceiveEcho bNewHash sign = do 
    ServerState _ _ _ _ bRecent echoListOld _ _ _ _ _ _ <- get
    let bNew = findBlock bNewHash bRecent
        echosB = fromMaybe [] (Map.lookup (blockHash bNew) echoListOld)
    let actionAddToList | sign `elem` echosB = return ()
                        | otherwise = do echoList .= Map.insertWith (++) (blockHash bNew) [sign] echoListOld                              
    actionAddToList
    phase .= "tally"

onReceiveTally :: BlockHash -> Int -> ServerAction ()
onReceiveTally bNewHash tally = do 
    ServerState _ _ _ _ bRecent _ tallyListOld _ _ _ _ _ <- get
    let bNew = findBlock bNewHash bRecent
        tallysB = fromMaybe [] (Map.lookup (blockHash bNew) tallyListOld)
    do tallyList .= Map.insertWith (++) (blockHash bNew) [tally] tallyListOld                              
    phase .= "vote"

 -- confirm delivery to all clients and servers
execute :: Int -> [Command] -> ServerAction ()
execute height cmds = do 
    ServerConfig _ _ _ _ clients<- ask
    ServerState _ _ _ _ _ _ _ _ _ _ mempoolOld _ <- get
    mempool .= filter (`notElem` cmds) mempoolOld
    echoList .= Map.empty
    tallyList .= Map.empty
    voteList .= Map.empty
    broadcastAll clients (DeliverMsg {deliverCommands = cmds, deliverHeight = height})
    

getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)

onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState cView bLock _ bLeafOld bRecentOld _ _ _ _ _ mempool _ <- get
    let mempoolBlock = take 100 mempoolOld
    let block = Block {content = mempoolBlock, height = cView + 1, blockHash = BlockHash (show hash), parent = [bLeafOld]}
    bLeaf .= block
    bRecent .= appendIfNotExists block bRecentOld
    let singleBlock = SingleBlock {contentS = mempoolBlock, heightS = cView + 1, blockHashS = BlockHash (show hash), parentS = blockHash bLeafOld}
    broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cView})

onEcho :: ServerAction ()
onEcho = do 
    ServerState _ _ _ bLeaf _ _ _ _ _ _ _ _ <- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (EchoMsg {echoBlock = blockHash bLeaf, sign = staticSignature})

onTally :: ServerAction ()
onTally = do 
    ServerState _ _ _ bLeaf _ echoList _ _ _ ticksSinceSendOld _ _ <- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (TallyMsg {tallyBlock = blockHash bLeaf, tallyNumber = length echoList, sign = staticSignature})

onVote :: ServerAction ()
onVote = do 
    ServerState _ _ _ bLeaf _ echoList tallyList _ _ ticksSinceSendOld _ _ <- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (VoteMsg {voteBlock = blockHash bLeaf, sign = staticSignature})

onDecide :: ServerAction ()
onDecide = do 
    ServerState _ _ bExecOld bLeaf _ echoList tallyList voteList _ ticksSinceSendOld _ _ <- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    execute (height bExecOld) (content bLeaf)
    cView += 1
    phase .= "propose"
    bExec .= bLeaf

-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState cView _ _ bLeaf _ _ _ _ phase ticksSinceSendOld _ _ <- get
    --increment ticks
    ticksSinceSend += 1
    let leader = getLeader peers cView
    let actionLead
    -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
            | (ticksSinceSendOld > timeout) && (leader == myPid) && (phase == "propose")= onPropose
            | otherwise = return ()
    actionLead
    let actionNextStep
            | (ticksSinceSendOld > timeout) && (phase == "echo") = onEcho
            | (ticksSinceSendOld > timeout) && (phase == "tally") = onTally
            | (ticksSinceSendOld > timeout) && (phase == "vote") = onVote
            | (ticksSinceSendOld > timeout) && (phase == "decide") = onDecide
            | otherwise = return ()
    actionNextStep


-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive commands from client
msgHandler (Message sender recipient (CommandMsg cmd)) = do
    ServerState _ _ _ _ _ _ _ _ _ _ mempoolOld _  <- get
    mempool .= cmd:mempoolOld
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg bNew pView)) = do 
    --handle proposal
    onReceiveProposal bNew pView
msgHandler (Message sender recipient (EchoMsg b sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _<- ask
    onReceiveEcho b sign
msgHandler (Message sender recipient (TallyMsg b tally sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _<- ask
    onReceiveTally b tally
msgHandler (Message sender recipient (VoteMsg b sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _<- ask
    onReceiveVote b sign


--Client behavior
--continuously send commands from client to all servers
tickClientHandler :: Tick -> ClientAction ()
tickClientHandler Tick = do
    ServerConfig myPid peers _ _ _ <- ask
    ClientState _ _ _ lastHeight _ tick <- get
    let n = 1
    sendNCommands n tick peers
    sentCount += n
    tickCount += 1

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
    broadcastAllClient peers (CommandMsg (Command {cmdId = commandString, sentTime = tick}))
    sentCount += 1

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient delivered) = do
    ClientState _ _ _ lastHeight _ _<- get
    let action
            | lastHeight < deliverHeight delivered = do rHeight += 1
                                                        deliveredCount += length (deliverCommands delivered)
                                                        lastDelivered .= deliverCommands delivered
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


sendWithDelay :: (Serializable a) => Int -> ProcessId -> a -> Process ()
sendWithDelay delay recipient msg = do
    liftIO $ threadDelay delay
    send recipient msg

-- network stack (impure)
spawnServer :: Process ProcessId
spawnServer = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers " ++ show otherPids
    clientPids <- expect
    say $ "received clients " ++ show clientPids
    let tickTime = 10^4
        timeoutMicroSeconds = 2*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    say $ "synchronous delta timers set to " ++ show timeoutTicks ++ " ticks"
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 genesisBlock genesisBlock genesisBlock [genesisBlock] Map.empty Map.empty Map.empty "propose" 0 [] randomGen)

spawnClient :: Process ProcessId
spawnClient = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers at client" ++ show otherPids
    clientPids <- expect
    let tickTime = 1*10^4
        timeoutMicroSeconds = 2*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 [] 0 randomGen 0)


spawnAll :: Int -> Int -> Int -> Process ()
spawnAll count crashCount clientCount = do
    pids <- replicateM count spawnServer
    
    clientPids <- replicateM clientCount spawnClient
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
                                say $ "Sending Messages : "  ++ show outputMessages ++ "\n"
    --prints
    let latency = 10^5
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages

    runServer config state'

runClient :: ServerConfig -> ClientState -> Process ()
runClient config state = do
    let run handler msg = return $ execRWS (runClientAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandlerCli,
            match $ run tickClientHandler]
    let prints 
            | True = say $ "Current state: " ++ show state'++ "\n"
            | otherwise = return ()
    prints
    
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    runClient config state'

main = do
    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll 3 0 1) -- number of replicas, number of crashes, number of clients
    putStrLn "Push enter to exit"
    getLine