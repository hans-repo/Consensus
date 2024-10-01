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
import Data.List (intersect, nub)
import qualified Data.Vector as V

import ParseOptions (Options(..), parseOptions)
-- import ConsensusLogic
import ConsensusDataTypes

appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list

broadcastAll :: [ProcessId] -> MessageType -> ServerAction ()
broadcastAll [single] content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
broadcastAll (single:recipients) content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
    broadcastAll recipients content

-- Helper function to remove an element at a specific index
removeAt :: Int -> [a] -> (a, [a])
removeAt idx xs = (xs !! idx, take idx xs ++ drop (idx + 1) xs)

-- Function to select x random elements without repetition
selectRandomElements :: Int -> [a] -> ServerAction [a]
selectRandomElements 0 _ = return []
selectRandomElements _ [] = return []
selectRandomElements n xs = do
  -- Generate a random index within the range of the list
  randomIdx <- randomWithin (0, length xs - 1)
  -- Remove the element at the random index from the list
  let (selectedElem, remainingElems) = removeAt randomIdx xs
  -- Recursively select the remaining elements
  rest <- selectRandomElements (n - 1) remainingElems
  -- Return the selected element along with the rest of the selected elements
  return (selectedElem : rest)

randomWithin :: Random r => (r,r) -> ServerAction r
randomWithin bounds = randomGen %%= randomR bounds

-- Function to obtain the common subset of a list of lists
commonSubset :: Eq a => [[a]] -> [a]
commonSubset [] = []  -- Return an empty list if the input is empty
commonSubset (x:xs) = foldl1 intersect (x:xs)


onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    let myList = map show [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    x <- randomWithin (8, 8)  -- Randomly select between 1 and 5 elements
    dag <- selectRandomElements x myList
    broadcastAll peers (ProposeMsg {proposal = dag})
    phase .= "vote"

onVote :: ServerAction ()
onVote = do 
    ServerConfig myPid peers _ _ _ <- ask
    ServerState _ proposeListOld _ _ _ <- get
    let voteDag = commonSubset proposeListOld
    broadcastAll peers (VoteMsg {vote = voteDag, proposes = proposeListOld})
    proposeList .= []
    phase .= "decide"

onDecide :: ServerAction ()
onDecide = do 
    ServerState _ _ voteListOld _ ticksOld<- get
    ServerConfig myPid _ _ _ clients <- ask
    let decideDag = commonSubset voteListOld
    broadcastAll clients (DeliverMsg {deliverCommands = decideDag, tickLatency = ticksOld})
    voteList .= []
    phase .= "propose"
    -- serverTickCount .= 0

onReceiveProposal :: [String] -> ServerAction ()
onReceiveProposal dag = do 
    ServerState _ proposeListOld _ _ _ <- get
    proposeList .= dag:proposeListOld

onReceiveVote :: [String] -> ServerAction ()
onReceiveVote dag = do
    ServerState _ _ voteListOld _ _ <- get
    voteList .= dag:voteListOld

-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ _ _ <- ask
    ServerState phase proposeList voteList _ _<- get

    let quorum = 2 * div (length peers) 3 + 1
    let actionNextStep
            | (phase == "propose") = onPropose
            | length proposeList >= quorum = onVote
            | length voteList >= quorum = onDecide
            | otherwise = return ()
    actionNextStep
    serverTickCount += 1

-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg dag)) = do 
    --handle proposal
    onReceiveProposal dag
msgHandler (Message sender recipient (VoteMsg dag proposeList)) = do
    --handle vote
    onReceiveVote dag

--Client behavior
--continuously send commands from client to all servers
tickClientHandler :: Tick -> ClientAction ()
tickClientHandler Tick = do
    ServerConfig myPid peers _ _ _ <- ask
    ClientState _ _ lastDeliveredOld lastHeight _ cmdRate tick _ <- get
    tickCount += 1
    if V.length lastDeliveredOld > 1
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate) lastDeliveredOld
        else return ()

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient (DeliverMsg deliverTick deliverCmds)) = do
    ClientState _ _ lastDeliveredOld lastHeight _ _ ticks _<- get
    let action
            | not $ isSubset (V.fromList [deliverCmds]) lastDeliveredOld = do deliveredCount += 1
                                                                              lastDelivered .= lastDeliveredOld V.++ (V.fromList [deliverCmds])
                                                                              latencyTracker .= deliverTick
            | otherwise = return ()
    action
    -- let resetLatencyTracker
    --         | ((V.fromList [deliverCmds]) /= lastDeliveredOld) && (lastDeliveredOld /= V.empty) = do latencyTracker .= ticks
    --         | otherwise = return ()
    -- resetLatencyTracker

isSubset :: (Eq a) => V.Vector a -> V.Vector a -> Bool
isSubset smaller larger =
    V.all (\x -> isJust $ V.find (== x) larger) smaller




sendWithDelay :: (Serializable a) => Int -> ProcessId -> a -> Process ()
sendWithDelay delay recipient msg = do
    liftIO $ threadDelay delay
    send recipient msg

-- network stack (impure)
spawnServer :: Int -> Process ProcessId
spawnServer batchSize= spawnLocal $ do
    myPid <- getSelfPid
    otherPids <- expect
    say $ "received servers " ++ show otherPids
    clientPids <- expect
    say $ "received clients " ++ show clientPids
    let tickTime = 10^5
        timeoutMicroSeconds = 10*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    say $ "synchronous delta timers set to " ++ show timeoutTicks ++ " ticks"
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState "propose" [] [] randomGen 0)

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
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 (V.fromList []) 0 randomGen cmdRate 0 0)


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
               | otherwise = do -- say $ "Current state: " ++ show state' ++ "\n"
                                say $ "Sending Messages : "  ++ show outputMessages ++ "\n"
    -- prints
    let latency = 0*10^5
    -- let memoryPrints = do --say $ "Length of bRecent : " ++ show (length $ _bRecent state' ) ++ "\n"
    --                     --   say $ "Size of bRecent : " ++ show (getSizeInBytes $ _bRecent state' ) ++ "\n"
    --                       say $ show (getSizeInBytes $ outputMessages) ++ "\n"
    --                       --say $ "Size of mempool : " ++ show (getSizeInBytes $ _mempool state' ) ++ "\n"
    --                       --say $ "Length of mempool : " ++ show (length $ _mempool state' ) ++ "\n"
                          
    -- --memoryPrints
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages

    runServer config state'

-- getSizeInBytes :: Binary a => a -> Int
-- getSizeInBytes = fromIntegral . BS.length . encode

-- Function to take the last x elements from a vector
lastXElements :: Int -> V.Vector a -> V.Vector a
lastXElements x vec = V.take x (V.drop (V.length vec - x) vec)



runClient :: ServerConfig -> ClientState -> Process ()
runClient config state = do
    let run handler msg = return $ execRWS (runClientAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandlerCli,
            match $ run tickClientHandler]
    let throughput = fromIntegral (_deliveredCount state') / fromIntegral (_tickCount state') 
        meanLatency = (_tickCount state') - (_latencyTracker state')
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
    -- prints
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    runClient config state'

main = do
    -- cmdRate just serves as an upper limit on lastDelivered for the client, set to the same as batchSize for now.
    Options replicas crashes cmdRate time batchSize <- parseOptions

    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll replicas crashes 1 batchSize batchSize) -- number of replicas, number of crashes, number of clients
    putStrLn $ "Running for " ++ show time ++ " seconds before exiting..."
    threadDelay (time*1000000)  -- seconds in microseconds
    putStrLn "Exiting now."