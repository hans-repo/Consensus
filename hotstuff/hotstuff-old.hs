{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
{-# LANGUAGE BangPatterns #-}
import qualified Data.Map as Map
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)

import Data.Maybe
import Data.Binary (Binary) -- Objects have to be binary to send over the network
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BS

import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization

import Control.Monad.RWS.Strict (
    RWS, MonadReader, MonadWriter, MonadState, ask, tell, get, execRWS, liftIO)
import Control.Monad (replicateM, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))
import Control.Lens.Getter ( view, Getting )

import System.Random (StdGen, Random, randomR, newStdGen, randomRIO)
import Data.Foldable (find)
import qualified Data.Vector as V

import ParseOptions (Options(..), parseOptions)
import ConsensusLogic
import ConsensusDataTypes

-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState _ cView _ _ bLeaf _ _ voteList ticksSinceMsgOld _ _ _<- get
    --increment ticks for every peer
    ticksSinceMsg .= Map.map (+1) ticksSinceMsgOld
    serverTickCount += 1

    let leader = getLeader peers cView
        quorum = 2 * div (length peers) 3 + 1
        votesB = fromMaybe [] (Map.lookup (blockHashS bLeaf) voteList)
        votesT = fromMaybe [] (Map.lookup (TimeoutView (cView-1)) voteList)
    let actionLead
    -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
            | leader == myPid && (length votesB >= quorum || length votesT >= quorum || bLeaf == genesisBlockSingle) = onPropose
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
-- msgHandler (Message sender recipient (CommandMsg cmd)) = do
--     ServerState _ _ _ _ _ _ _ _ _ mempoolOld _  <- get
--     mempool .= cmd:mempoolOld
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
    --sendIndividualCommands cmdRate tick peers
    -- sendNCommands n tick peers
    -- sentCount += n
    tickCount += 1
    if V.length lastDeliveredOld > cmdRate
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate) lastDeliveredOld
        else return ()

-- sendNCommands :: Int -> Int -> [ProcessId] -> ClientAction ()
-- sendNCommands 0 _ _ = return ()
-- sendNCommands n tick peers = do sendSingleCommand peers tick
--                                 sendNCommands (n-1) tick peers

-- sendSingleCommand :: [ProcessId] -> Int -> ClientAction ()
-- sendSingleCommand peers tick = do 
--     let bound1 :: Int
--         bound1 = maxBound
--     command <- randomWithinClient (0, bound1)
--     let commandString = show command
--     broadcastAllClient peers (CommandMsg (Command {cmdId = commandString, sentTime = tick}))
--     sentCount += 1

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient (DeliverMsg deliverH deliverCmds)) = do
    ClientState _ _ lastDeliveredOld lastHeight _ _ _<- get
    let action
            -- | lastHeight < deliverH = do rHeight += 1
            --                              deliveredCount += V.length deliverCmds
            --                              lastDelivered .= deliverCmds
            -- | lastHeight == deliverH && lastDeliveredOld /= deliverCmds = do 
            --                                                                 deliveredCount += V.length deliverCmds
            --                                                                 lastDelivered .= deliverCmds
            -- | otherwise = return ()
            | not $ isSubset deliverCmds lastDeliveredOld = do deliveredCount += V.length deliverCmds
                                                               lastDelivered .= lastDeliveredOld V.++ deliverCmds
            | otherwise = return ()
    action

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
    let tickTime = 10^4
        timeoutMicroSeconds = 10*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    say $ "synchronous delta timers set to " ++ show timeoutTicks ++ " ticks"
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        send myPid Tick
    randomGen <- liftIO newStdGen
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 0 genesisBlockSingle genesisBlockSingle genesisBlockSingle [genesisBlockSingle] genesisQC Map.empty (Map.fromList [(key, 0) | key <- otherPids]) batchSize 0 randomGen)

spawnClient :: Int -> Process ProcessId
spawnClient batchSize = spawnLocal $ do
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
    runClient (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ClientState 0 0 (V.fromList []) 0 randomGen batchSize 0)


spawnAll :: Int -> Int -> Int -> Int -> Process ()
spawnAll count crashCount clientCount batchSize = do
    pids <- replicateM count (spawnServer batchSize)
    
    clientPids <- replicateM clientCount (spawnClient batchSize)
    let allPids = pids ++ clientPids
    mapM_ (`send` pids) allPids
    say $ "sent servers " ++ show pids
    mapM_ (`send` clientPids) allPids
    say $ "sent clients " ++ show clientPids
    -- mapM_ (`kill` "crash node") (take crashCount pids)
    toCrashNodes <- liftIO $ selectRandomElements crashCount pids
    mapM_ (`kill` "crash node") toCrashNodes

-- Function to select x random elements from a list
selectRandomElements :: Int -> [a] -> IO [a]
selectRandomElements x xs = do
    let n = length xs
    if n == 0 || x <= 0 then return []  -- Return empty list if input is invalid
    else do
        indices <- randomIndices x n
        return [xs !! i | i <- indices]  -- Select elements using the random indices

-- Helper function to generate unique random indices
randomIndices :: Int -> Int -> IO [Int]
randomIndices x n = go x []
  where
    go 0 acc = return acc
    go m acc = do
        idx <- randomRIO (0, n - 1)
        if idx `elem` acc then go m acc  -- Ensure uniqueness
        else go (m - 1) (idx : acc)


runServer :: ServerConfig -> ServerState -> Process ()
runServer config state = do
    let run handler msg = return $ execRWS (runAction $ handler msg) config state
    (state', outputMessages) <- receiveWait [
            match $ run msgHandler,
            match $ run tickServerHandler]
    let !state'' = state'
    let prints -- | False = return () --null outputMessages = return ()
               | null outputMessages = return ()
               | otherwise = do say $ "Current state: " ++ show state' ++ "\n"
                                say $ "Sending Messages : "  ++ show outputMessages ++ "\n"
    -- prints
    let latency = 0*10^5
    let memoryPrints = do --say $ "Length of bRecent : " ++ show (length $ _bRecent state' ) ++ "\n"
                        --   say $ "Size of bRecent : " ++ show (getSizeInBytes $ _bRecent state' ) ++ "\n"
                          say $ show (getSizeInBytes $ outputMessages) ++ "\n"
                          --say $ "Size of mempool : " ++ show (getSizeInBytes $ _mempool state' ) ++ "\n"
                          --say $ "Length of mempool : " ++ show (length $ _mempool state' ) ++ "\n"
                          
    --memoryPrints
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages

    runServer config state''

getSizeInBytes :: Binary a => a -> Int
getSizeInBytes = fromIntegral . BS.length . encode

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
    let throughput = fromIntegral (_deliveredCount state') / fromIntegral (_tickCount state') 
        meanLatency = meanTickDifference (lastXElements (_clientBatchSize state') (_lastDelivered state')) (_tickCount state')
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
    --prints
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    let !state'' = state'
    runClient config state''

main = do
    -- cmdRate just serves as an upper limit on lastDelivered for the client, set to the same as batchSize for now.
    Options replicas crashes time batchSize <- parseOptions

    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll replicas crashes 1 batchSize) -- number of replicas, number of crashes, number of clients
    putStrLn $ "Running for " ++ show time ++ " seconds before exiting..."
    threadDelay (time*1000000)  -- seconds in microseconds
    putStrLn "Exiting now."