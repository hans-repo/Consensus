{-# LANGUAGE BangPatterns #-}

import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as Map
import qualified Data.Vector as V

import ParseOptions (Options(..), parseOptions)
import ConsensusLogic (onReceiveProposal, onVote, onEcho, onReceiveVote, onReceiveEcho, getLeader, onReceiveTally, onTally, onPropose, onDecide, execute, randomWithinClient,
    ask, tell, get)
import ConsensusDataTypes
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Monad.RWS.Strict (execRWS, liftIO)
import Data.Maybe (isJust)


import Control.Monad (replicateM, forever)


import Control.Distributed.Process (kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)


-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState cView _ _ bLeaf _ _ _ phase ticksSinceSendOld _ _ _ _<- get
    --increment ticks
    ticksSinceSend += 1
    serverTickCount += 1
    -- let leader = getLeader peers cView
    -- let actionLead
    -- -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
    --         | (ticksSinceSendOld > timeout) && (leader == myPid) && (phase == "propose")= onPropose
    --         | otherwise = return ()
    -- actionLead
    let actionNextStep
            | (ticksSinceSendOld > timeout) && (phase == "propose")= onPropose
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
    ServerState _ _ _ _ _ _ _ _ _ _ mempoolOld  _ _ <- get
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
    ClientState _ _ lastDeliveredOld lastHeight _ cmdRate tick <- get
    -- let n = 1
    --sendIndividualCommands cmdRate tick peers
    -- sendNCommands n tick peers
    -- sentCount += n
    tickCount += 1
    if V.length lastDeliveredOld > cmdRate
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate) lastDeliveredOld
        else return ()

--Send n commands individually per node
-- sendIndividualCommands :: Int -> Int -> [ProcessId] -> ClientAction ()
-- sendIndividualCommands _ _ [] = return ()
-- sendIndividualCommands n tick peers = do sendNCommands n tick [head peers]
--                                          sendIndividualCommands n tick $ tail peers

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
--     broadcastAllClient peers (CommandMsg (Command {cmdId = commandString, deliverTime = tick, proposeTime = 0}))
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
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 genesisBlockSingle genesisBlockSingle genesisBlockSingle Map.empty Map.empty Map.empty "propose" 0 batchSize [] randomGen 0)

spawnClient :: Int -> Process ProcessId
spawnClient cmdRate = spawnLocal $ do
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
    --prints
    --say $ "Sending Messages : " ++ show outputMessages++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    let !state'' = state'
    runClient config state''

main = do
    -- cmdRate just serves as an upper limit on lastDelivered for the client, set to the same as batchSize for now.
    Options replicas crashes cmdRate time batchSize <- parseOptions

    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll replicas crashes 1 batchSize batchSize) -- number of replicas, number of crashes, number of clients
    putStrLn $ "Running for " ++ show time ++ " seconds before exiting..."
    threadDelay (time*1000000)  -- seconds in microseconds
    putStrLn "Exiting now."