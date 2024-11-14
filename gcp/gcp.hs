{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
import qualified Data.Map as Map
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, NodeId, kill,
    send, say, expect, getSelfPid, spawnLocal, spawn, match, receiveWait, terminate)
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)
import Control.Distributed.Process.Closure

import Text.Printf

import Data.Maybe
import Data.Binary (Binary) -- Objects have to be binary to send over the network
import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization

import Control.Monad.RWS.Strict (
    RWS, MonadReader, MonadWriter, MonadState, ask, tell, get, execRWS, liftIO)
import Control.Monad (replicateM, forever, forM)
import Control.Concurrent (threadDelay)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))
import Control.Lens.Getter ( view, Getting )
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Static hiding (initRemoteTable)

import System.Environment
import System.IO (hFlush, stdout) -- Add this import
import Data.Time.Clock.POSIX (getPOSIXTime, POSIXTime)


import Network.Socket (shutdown)

import Language.Haskell.TH hiding (match)

import System.Random (StdGen, Random, randomR, newStdGen, randomRIO)


import qualified Data.Vector as V

import ParseOptions (Options(..), parseOptions)
import ConsensusLogic
import ConsensusDataTypes


-- onBeat equivalent
tickServerHandler :: ServerTick -> ServerAction ()
tickServerHandler (ServerTick tickTime) = do
    ServerConfig myPid peers _ _ timePerTick _ <- ask
    ServerState phase proposeList voteList timerOld _ _<- get
    --increment ticks
    timerPosix .= tickTime
    let elapsedTime = (tickTime - timerOld) *10^6
        elapsedTicks = elapsedTime / fromIntegral timePerTick
    serverTickCount += round elapsedTicks

    let quorum = 2 * div (length peers) 3 + 1
    let actionNextStep
            | (phase == "propose") = onPropose
            | length proposeList >= quorum = onVote
            | length voteList >= quorum = onDecide
            | otherwise = return ()
    actionNextStep



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
tickClientHandler :: ClientTick -> ClientAction ()
tickClientHandler (ClientTick tickTime) = do
    ServerConfig myPid peers _ _ timePerTick _<- ask
    ClientState _ _ lastDeliveredOld lastHeight _ cmdRate timerOld tick <- get

    -- timerPosixCli .= tickTime
    let elapsedTime = (tickTime - timerOld) *10^6
        elapsedTicks = elapsedTime / fromIntegral timePerTick
    tickCount .= round elapsedTicks
    if V.length lastDeliveredOld > 1
        then do 
            let truncLastDelivered = V.singleton $ V.last lastDeliveredOld
            lastDelivered .= truncLastDelivered
            currLatency .= (meanTickDifference truncLastDelivered (round $ tickTime*10^6)) / 10^3
        else do
            return ()


msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient (DeliverMsg deliverTick deliverCmd)) = do
    ClientState _ _ lastDeliveredOld lastHeight _ _ _ ticks<- get
    let deliverCmds = V.singleton deliverCmd
    -- let newDelivered = elementsNotInLarger deliverCmds lastDeliveredOld
    let newDelivered = deliverCmds
    let action
            -- | isSubset deliverCmds lastDeliveredOld = do lastDelivered .= lastDeliveredOld V.++ deliverCmds
            -- | otherwise = do deliveredCount += V.length deliverCmds
            --                  lastDelivered .= lastDeliveredOld V.++ deliverCmds
            | length newDelivered > 0 = do lastDelivered .= lastDeliveredOld V.++ deliverCmds
                                           deliveredCount += V.length newDelivered
            -- | otherwise = do lastDelivered .= lastDeliveredOld V.++ deliverCmds
            | otherwise = return ()
    action

-- Function to get the elements in 'smaller' that are not in 'larger'
elementsNotInLarger :: V.Vector DagInput -> V.Vector DagInput -> V.Vector DagInput
elementsNotInLarger smaller larger = V.filter notInLargerFn smaller
    where
        largerIds = V.map dag larger  -- Extract dag from the larger vector
        notInLargerFn cmd = dag cmd `V.notElem` largerIds  -- Check if dag is not in largerIds


isSubset :: V.Vector DagInput -> V.Vector DagInput -> Bool
isSubset smaller larger = V.all (`V.elem` largerIds) smallerIds
    where smallerIds = V.map dag smaller
          largerIds = V.map dag larger



sendWithDelay :: (Serializable a) => Int -> ProcessId -> a -> Process ()
sendWithDelay delay recipient msg = do
    liftIO $ threadDelay delay
    send recipient msg

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

meanTickDifference :: V.Vector DagInput -> Int -> Double
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
            match $ run tickClientHandler,
            match $ run msgHandlerCli]
    let throughput = fromIntegral (_deliveredCount state') / fromIntegral (_tickCount state') 
        -- meanLatency = meanTickDifference (lastXElements ((_clientBatchSize state')*(length $ peers config)) (_lastDelivered state')) (_tickCount state')
    let throughputPrint 
            -- | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty) = say $ "Current throughput: " ++ show throughput ++ "\n" ++ "deliveredCount: " ++ show (_deliveredCount state') ++ "\n" ++ "tickCount: " ++ show (_tickCount state') ++ "\n" ++ "lastDelivered: " ++ show (V.toList $ _lastDelivered state') ++ "\n"
            | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty)= say $ "Delivered commands " ++ show (_deliveredCount state')
            | otherwise = return ()
    let latencyPrint 
            | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty) = say $ "Current mean latency: " ++ show (_currLatency state') ++ "\n"
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

spawnServer :: Int -> ProcessId -> Process ProcessId
spawnServer batchSize clientPid = spawnLocal $ do
    myPid <- getSelfPid
    mapM_ (`send` myPid) [clientPid]
    say $ "sent servers" ++ show myPid ++ " to " ++ show [clientPid]

    serverPids <- expect
    say $ "received servers " ++ show serverPids
    let tickTime = 1*10^3
        timeoutMicroSeconds = 10*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    say $ "synchronous delta timers set to " ++ show timeoutTicks ++ " ticks"
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        currentTime <- liftIO getPOSIXTime
        let timeDouble = realToFrac currentTime
        send myPid (ServerTick timeDouble)
    randomGen <- liftIO newStdGen
    timeInitPOSIX <- liftIO getPOSIXTime
    let timeInit = realToFrac timeInitPOSIX
    runServer (ServerConfig myPid serverPids (Signature (show randomGen)) timeoutTicks tickTime [clientPid]) (ServerState "propose" [] [] timeInit randomGen 0)


spawnClient :: Int -> Int -> Int -> Int -> Process ProcessId
spawnClient batchSize nSlaves replicas crashCount = spawnLocal $ do
    clientPid <- getSelfPid
    say $ "client Pid is: " ++ show clientPid
    otherPids <- replicateM (nSlaves*replicas) $ do
        say $ "Expecting next server PID... "
        pid <- expect  -- Match any message and return it
        say $ "Received PID: " ++ show pid  -- Print the received message
        return pid  -- Return the received PID
    say $ "received servers at client" ++ show otherPids
    mapM_ (`send` otherPids) otherPids
    say $ "sent server list to " ++ show otherPids

    --crash randomly selected nodes
    toCrashNodes <- liftIO $ selectRandomElements crashCount otherPids
    mapM_ (`kill` "crash node") toCrashNodes
    say $ "sent crash command to " ++ show toCrashNodes
  
    let tickTime = 1*10^3
        timeoutMicroSeconds = 10*10^5
        timeoutTicks = timeoutMicroSeconds `div` tickTime
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        currentTime <- liftIO getPOSIXTime
        let timeDouble = realToFrac currentTime
        send clientPid (ClientTick timeDouble)
    randomGen <- liftIO newStdGen
    timeInitPOSIX <- liftIO getPOSIXTime
    let timeInit = realToFrac timeInitPOSIX
    runClient (ServerConfig clientPid otherPids (Signature (show randomGen)) timeoutTicks tickTime [clientPid]) (ClientState 0 0 (V.fromList []) 0 randomGen batchSize timeInit 0 )


spawnAll :: (ProcessId, Int, Int) -> Process ()
spawnAll (clientPid, replicas, batchSize) = do
    pids <- replicateM replicas (spawnServer batchSize clientPid)
    return ()
    -- let allPids = pids ++ [clientPid]
    -- mapM_ (`send` pids) [clientPid]
    -- say $ "sent servers" ++ show pids ++ " to " ++ show [clientPid]

remotable ['spawnAll]

master :: Backend -> Int -> Int -> Int -> Int -> [NodeId] -> Process ()                     -- <1>
master backend replicas crashCount time batchSize peers= do
--   terminateAllSlaves backend
  clientPid <- spawnClient batchSize (length peers) replicas crashCount
  liftIO $ threadDelay (100)
  let spawnCmd = ($(mkClosure 'spawnAll) (clientPid, replicas, batchSize))
  pids <- forM peers $ \nid -> do  
        say $ "sent spawn command" ++ show spawnCmd ++ " to: " ++ show nid
        spawn nid spawnCmd
  
  -- Terminate the slaves when the master terminates (this is optional)
  liftIO $ threadDelay (time*1000000)  -- seconds in microseconds
  terminateAllSlaves backend
  terminate

main :: IO ()
main = do
  let rtable = Main.__remoteTable initRemoteTable
  Options host port masterorslave replicas crashes time batchSize <- parseOptions
  backend <- initializeBackend host port rtable
  case masterorslave of
    "master" -> do
      startMaster backend $ master backend replicas crashes time batchSize
    "slave" -> do
      startSlave backend