{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell            #-} -- Allows automatic creation of Lenses for ServerState
{-# LANGUAGE BangPatterns #-}
import qualified Data.Map as Map
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Distributed.Process (Process, ProcessId, NodeId, kill,
    send, say, expect, getSelfPid, spawnLocal, spawn, match, receiveWait, terminate)
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)
import Control.Distributed.Process.Closure

import Text.Printf

import Data.Maybe
import Data.Binary (Binary) -- Objects have to be binary to send over the network
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BS

import GHC.Generics (Generic) -- For auto-derivation of serialization
import Data.Typeable (Typeable) -- For safe serialization

import Control.Monad.RWS.Strict (
    RWS, MonadReader, MonadWriter, MonadState, ask, tell, get, execRWS, liftIO)
import Control.Monad (replicateM, forever, forM)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay)
import Control.Lens --(makeLenses, (+=), (%%=), use, view, (.=), (^.))
import Control.Lens.Getter ( view, Getting )
-- import Control.Distributed.Process hiding (Message, match)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Static hiding (initRemoteTable)

import System.Environment
import System.IO (hFlush, stdout)
import Data.Time.Clock.POSIX (getPOSIXTime, POSIXTime)

import Network.Socket (shutdown)

import Language.Haskell.TH hiding (match)

import System.Random (StdGen, Random, randomR, newStdGen, randomRIO)
import Data.Foldable (find)
import qualified Data.Vector as V

import ParseOptions (Options(..), parseOptions)
import ConsensusLogic
import ConsensusDataTypes

-- onBeat equivalent
tickServerHandler :: ServerTick -> ServerAction ()
tickServerHandler (ServerTick tickTime) = do
    ServerConfig myPid peers _ timeout timePerTick _ <- ask
    ServerState _ cView _ _ bLeaf _ _ voteList ticksSinceMsgOld _ timerOld tickOld _<- get
    --increment ticks
    -- timerPosix .= tickTime
    let elapsedTime = (tickTime - timerOld) *10^6
        elapsedTicks = round (elapsedTime / fromIntegral timePerTick)
        elapsedTicksSinceSend = elapsedTicks- tickOld
    ticksSinceMsg .= Map.map (+elapsedTicksSinceSend) ticksSinceMsgOld
    serverTickCount .= elapsedTicks

    let leader = getLeader peers cView
        quorum = 2 * div (length peers) 3 + 1
        votesB = fromMaybe [] (Map.lookup (blockHashS bLeaf) voteList)
        votesT = fromMaybe [] (Map.lookup (BlockHash $ show (cView-1)) voteList)
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
--receive proposal, onReceiveProposal
msgHandler (Message sender recipient (ProposeMsg bNew pView)) = do 
    --handle proposal
    onReceiveProposal bNew pView
msgHandler (Message sender recipient (VoteMsg b sign)) = do
    --handle vote
    ServerConfig myPid peers _ _ _ _<- ask
    onReceiveVote b sign
msgHandler (Message sender recipient (NewViewMsg qc view sign)) = do
    --handle new view message
    onReceiveNewView view qc sign

--Client behavior
tickClientHandler :: ClientTick -> ClientAction ()
tickClientHandler (ClientTick tickTime) = do
    ServerConfig myPid peers _ _ timePerTick _ <- ask
    ClientState _ _ lastDeliveredOld currLatencyOld _ cmdRate timeOld tick <- get
    -- timerPosixCli .= tickTime
    let elapsedTime = (tickTime - timeOld) *10^6
        elapsedTicks = elapsedTime / fromIntegral timePerTick
    tickCount .= round elapsedTicks

    -- if lastDeliveredOld /= V.fromList []
    --     then do
    --         currLatency .= meanTickDifference lastDeliveredOld tick
    --         -- currLatency .= elapsedTicks
    --         -- lastDelivered .= V.fromList []
    --     else return ()
    if V.length lastDeliveredOld > cmdRate
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate*(length peers)) lastDeliveredOld
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
    ClientState _ _ lastDeliveredOld lastHeight _ _ _ _<- get
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
            | otherwise = lastDelivered .= lastDeliveredOld V.++ deliverCmds
    action

isSubset :: V.Vector Command -> V.Vector Command -> Bool
isSubset smaller larger = V.all (`V.elem` largerIds) smallerIds
    where smallerIds = V.map cmdId smaller
          largerIds = V.map cmdId larger



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
    let !state'' = state'
    let leader = getLeader (peers config) (_cView state)
        quorum = 2 * div (length $ peers config) 3 + 1
        votesB = fromMaybe [] (Map.lookup (blockHashS $ _bLeaf state') (_voteList state'))
        votesT = fromMaybe [] (Map.lookup (BlockHash $ show ((_cView state')-1)) (_voteList state'))

    let prints | null outputMessages = return ()
               | otherwise = do --say $ "Vote List length for hash " ++ show (blockHashS $ _bLeaf state') ++ " is : " ++ show (length votesB) ++ "\n" ++ "newview list length for view " ++ show ((_cView state')-1) ++ " : " ++ show (length votesT) ++ "\n"
                                -- say $ "state: " ++ show state ++ "\n"
                                say $ "Sending Messages : "  ++ show outputMessages ++ "\n"
                                -- say $ "vote list increase: " ++ show (_voteList state') ++ "\n"
                                -- say $ "Current leader: " ++ show leader ++ " current view: " ++ show (_cView state) ++ "\n"
    -- prints
    let votesPrints | (_voteList state') /= (_voteList state) = do say $ "vote list increase: " ++ show (_voteList state') ++ "\n"
                    | otherwise = return ()
    -- votesPrints
    let latency = 0*10^5
    let memoryPrints = do --say $ "Length of bRecent : " ++ show (length $ _bRecent state' ) ++ "\n"
                        --   say $ "Size of bRecent : " ++ show (getSizeInBytes $ _bRecent state' ) ++ "\n"
                          say $ show (getSizeInBytes $ outputMessages) ++ "\n"
                          --say $ "Size of mempool : " ++ show (getSizeInBytes $ _mempool state' ) ++ "\n"
                          --say $ "Length of mempool : " ++ show (length $ _mempool state' ) ++ "\n"
                          
    -- memoryPrints
    -- liftIO $ threadDelay (1000)
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages

    runServer config state''

getSizeInBytes :: Binary a => a -> Int
getSizeInBytes = fromIntegral . BS.length . encode

-- Function to take the last x elements from a vector
lastXElements :: Int -> V.Vector a -> V.Vector a
lastXElements x vec = V.take x (V.drop (V.length vec - x) vec)


meanTickDifference :: V.Vector Command -> Int -> Double
meanTickDifference commands tick =
    -- let differences = map (\cmd -> fromIntegral (tick - proposeTime cmd)) (V.toList commands)
    let differences = map (\cmd -> fromIntegral (deliverTime cmd - proposeTime cmd)) (V.toList commands)
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
        meanLatency = meanTickDifference (lastXElements ((_clientBatchSize state')*(length $ peers config)) (_lastDelivered state')) (_tickCount state')
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
    let !state'' = state'
    runClient config state''


spawnServer :: Int -> ProcessId -> Process ProcessId
spawnServer batchSize clientPid = spawnLocal $ do
    myPid <- getSelfPid
    mapM_ (`send` myPid) [clientPid]
    say $ "sent servers" ++ show myPid ++ " to " ++ show [clientPid]

    serverPids <- expect
    say $ "received servers " ++ show serverPids
    let tickTime = 1*10^4
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
    runServer (ServerConfig myPid serverPids (Signature (show randomGen)) timeoutTicks tickTime [clientPid]) (ServerState 0 0 genesisBlockSingle genesisBlockSingle genesisBlockSingle [genesisBlockSingle] genesisQC Map.empty (Map.fromList [(key, 0) | key <- serverPids]) batchSize timeInit 0 randomGen)


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
  
    let tickTime = 1*10^4
    spawnLocal $ forever $ do
        liftIO $ threadDelay tickTime
        currentTime <- liftIO getPOSIXTime
        let timeDouble = realToFrac currentTime
        send clientPid (ClientTick timeDouble)
    randomGen <- liftIO newStdGen
    timeInitPOSIX <- liftIO getPOSIXTime
    let timeInit = realToFrac timeInitPOSIX
    runClient (ServerConfig clientPid otherPids (Signature (show randomGen)) 0 tickTime [clientPid]) (ClientState 0 0 (V.fromList []) 0 randomGen batchSize timeInit 0)


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
--   terminateAllSlaves backend
  terminate

main :: IO ()
main = do
  let rtable = Main.__remoteTable initRemoteTable
  hFlush stdout -- Ensure the output is flushed
  Options host port masterorslave replicas crashes time batchSize <- parseOptions
  backend <- initializeBackend host port rtable
  case masterorslave of
    "master" -> do
      startMaster backend $ master backend replicas crashes time batchSize
    "slave" -> do
      startSlave backend
