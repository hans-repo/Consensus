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

import ParseOptions (Options(..), parseOptions)


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
data SingleBlock = SingleBlock {contentS :: [Command], heightS :: Int, blockHashS :: BlockHash, parentS :: [BlockHash]}
    deriving (Show, Generic, Typeable, Eq)

genesisBlockSingle :: SingleBlock
genesisBlockSingle = SingleBlock {contentS = [], heightS = 0, blockHashS = BlockHash "genesis", parentS = []}

--message types between nodes. CommandMsg for client commands, DeliverCmd to share confirmed commands and the block height. VoteMsg for votes in chained hotstuff. ProposeMsg for leader proposals. NewViewMsg is the new view sent by replicas upon timeout.
data MessageType = CommandMsg Command | DeliverMsg {deliverHeight :: Int, deliverCommands :: [Command]} | ProposeMsg {proposal :: SingleBlock, pView :: Int}
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
    _msgRate :: Int, --number of commands sent to each node per tick
    _tickCount :: Int --tick counter
} deriving (Show)
makeLenses ''ClientState

data ServerState = ServerState {
    _cHeight :: Int, --current height
    _finHeight :: Int, --last confirmed height
    _dagFin :: [Block], -- final DAG, executed. List of highest height confirmed blocks only
    _dagRecent :: [Block], -- unconfirmed DAG. List of  highest height received blocks only
    --_heightsMap :: Map.Map Int [SingleBlock], --mapping heights to blocks. SingleBlock to avoid containing whole DAG.
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


-- findBlock :: BlockHash -> [Block] -> Block 
-- findBlock h [b,_] = findBlockDepth h b
-- findBlock h (b:bs) | h == blockHash b = b 
--                    | otherwise = findBlock h bs 

findBlock :: BlockHash -> [Block] -> Block 
findBlock h [b] = genesisBlock
findBlock h (b:bs) | h == blockHash b = b 
                   | otherwise = findBlock h bs 

findBlocksHeight :: Int -> [Block] -> [Block] -> [Block]
findBlocksHeight h out [] = out
findBlocksHeight h out (b:bs) | h == height b = findBlocksHeight h (b:out) bs
                              | otherwise = findBlocksHeight h out bs

findBlockDepth :: BlockHash -> Block -> Block
findBlockDepth h b | h == blockHash b = b 
                   | b == genesisBlock = genesisBlock
                   | otherwise = findBlockDepth h (head $ parent b)

singleToFull :: SingleBlock -> [Block] -> Block
singleToFull sb bList = let parentBlocks = map (\x -> findBlock x bList) (parentS sb) --obtain list of parent as Block type from the list of parent hashes in sb
                   in Block {content = contentS sb, height = heightS sb, blockHash = blockHashS sb, parent = parentBlocks}


getBlocksFromHeight :: Map.Map Int [SingleBlock] -> Int -> [SingleBlock]
getBlocksFromHeight heightsMap height = fromMaybe [] (Map.lookup height heightsMap)

appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list


onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNewSingle pView = do 
    ServerState _ _ _ dagRecentOld _ mempoolOld _ <- get
    ServerConfig myPid peers staticSignature _ _<- ask
    let parentsBlocks = map (\x -> findBlock x dagRecentOld) $ parentS bNewSingle
        bNew = Block {content = contentS bNewSingle, height = heightS bNewSingle, blockHash = blockHashS bNewSingle, parent = parentsBlocks}
        dagRecentNew = appendIfNotExists bNew dagRecentOld
        sameHeight = findBlocksHeight (heightS bNewSingle) [] dagRecentOld
        --sameHeight = fromMaybe [] (Map.lookup (heightS bNewSingle) heightsMapOld)
        -- actionAddToMap  | bNewSingle `elem` sameHeight = return ()
        --                 | otherwise = do heightsMap .= Map.insertWith (++) (heightS bNewSingle) [bNewSingle] heightsMapOld                             
    dagRecent .= dagRecentNew
    --actionAddToMap

    mempool .= filter (`notElem` content bNew) mempoolOld
 -- confirm delivery to all clients and servers
execute :: [Block] -> ServerAction ()
execute [] = do return ()
execute (b:bs) = do 
    ServerConfig _ _ _ _ clients<- ask
    ServerState _ _ dagFinOld _ _ mempoolOld _ <- get
    let cmds = content b
    mempool .= filter (`notElem` cmds) mempoolOld
    dagFin .= appendIfNotExists b dagFinOld
    broadcastAll clients (DeliverMsg {deliverCommands = cmds, deliverHeight = height b})
    execute bs


getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)

onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState cHeightOld _ _ dagRecentOld _ mempool _ <- get
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    let --parentsSingle = getBlocksFromHeight heightsMap cHeightOld
        --parentsHash = map blockHashS parentsSingle
        --parentsBlocks = map (\x -> findBlock x dagRecentOld) parentsHash
        mempoolBlock = take 100 mempool
        parentsBlocks = findBlocksHeight cHeightOld [] dagRecentOld
        parentsHash = map blockHash parentsBlocks
        block = Block {content = mempoolBlock, height = cHeightOld + 1, blockHash = BlockHash (show hash), parent = parentsBlocks}
    --dagRecent .= appendIfNotExists block dagRecentOld
    
    let singleBlock = SingleBlock {contentS = mempoolBlock, heightS = cHeightOld + 1, blockHashS = BlockHash (show hash), parentS = parentsHash}
    broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cHeightOld + 1})
    cHeight += 1


onDecide :: ServerAction ()
onDecide = do 
    ServerState cHeightOld _ _ dagRecentOld _ _ _ <- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- let finBlocksSingle = getBlocksFromHeight heightsMap $ abs (cHeightOld - 2)
    -- let finBlocks = map (\x -> singleToFull x dagRecentOld) finBlocksSingle
    let heightToFin = abs $ cHeightOld - 2
        finBlocks = findBlocksHeight heightToFin [] dagRecentOld
    execute finBlocks
    finHeight .= heightToFin
    
    
-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState  _ _ _ _ ticksSinceSendOld _ _ <- get
    --increment ticks
    ticksSinceSend += 1
    let leader = myPid
    let actionNextView
            | (ticksSinceSendOld > timeout) = onDecide
            | otherwise = return ()
    actionNextView
    let actionLead
    -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
            | (ticksSinceSendOld > timeout) && (leader == myPid) = onPropose
            | otherwise = return ()
    actionLead



-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive commands from client
msgHandler (Message sender recipient (CommandMsg cmd)) = do
    ServerState _ _ _ _ _ mempoolOld _  <- get
    mempool .= cmd:mempoolOld
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg bNew pView)) = do 
    --handle proposal
    onReceiveProposal bNew pView


--Client behavior
--continuously send commands from client to all servers
tickClientHandler :: Tick -> ClientAction ()
tickClientHandler Tick = do
    ServerConfig myPid peers _ _ _ <- ask
    ClientState _ _ _ lastHeight _ cmdRate tick <- get
    sendIndividualCommands cmdRate tick peers
    --sendNCommands n tick peers
    tickCount += 1

--Send n commands individually per node
sendIndividualCommands :: Int -> Int -> [ProcessId] -> ClientAction ()
sendIndividualCommands _ _ [] = return ()
sendIndividualCommands n tick peers = do sendNCommands n tick [head peers]
                                         sendIndividualCommands n tick $ tail peers

--Send N commands to all nodes
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
msgHandlerCli (Message sender recipient (DeliverMsg deliverH deliverCmds)) = do
    ClientState _ _ _ lastHeight _ _ _<- get
    let action
            | lastHeight < deliverH = do rHeight += 1
                                         deliveredCount += length deliverCmds
                                         lastDelivered .= deliverCmds
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
        timeoutMicroSeconds = 5*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    say $ "synchronous delta timers set to " ++ show timeoutTicks ++ " ticks"
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 0 [genesisBlock] [genesisBlock] 0 [] randomGen)

spawnClient :: Int -> Process ProcessId
spawnClient cmdRate = spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers at client" ++ show otherPids
    clientPids <- expect
    let tickTime = 1*10^5
        timeoutMicroSeconds = 2*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 [] 0 randomGen cmdRate 0)


spawnAll :: Int -> Int -> Int -> Int -> Process ()
spawnAll count crashCount clientCount cmdRate = do
    pids <- replicateM count spawnServer
    
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
                                say $ "Sending Messages : "  ++ show outputMessages ++ "\n"
    --prints
    let latency = 0*10^5
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
    -- get options from command line
    Options replicas crashes cmdRate time <- parseOptions

    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll replicas crashes 1 cmdRate) -- number of replicas, number of crashes, number of clients
    -- putStrLn "Push enter to exit"
    -- getLine
    putStrLn "Waiting for 10 seconds before exiting..."
    threadDelay (time * 1000000)  -- 10 seconds in microseconds
    putStrLn "Exiting now."