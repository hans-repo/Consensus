{-# LANGUAGE BangPatterns #-}
import Data.Binary (encode)
import qualified Data.ByteString.Lazy as BS

import ParseOptions (Options(..), parseOptions)
import ConsensusLogic (onPropose, onDecide, onReceiveProposal, execute, randomWithinClient, ask, tell, get)
import ConsensusDataTypes
import Network.Transport.TCP (createTransport, defaultTCPAddr, defaultTCPParameters)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Monad.RWS.Strict (execRWS, liftIO)
import qualified Data.Vector as V
import Data.Maybe (isJust)


import Control.Monad (replicateM, forever)


import Control.Distributed.Process (kill,
    send, say, expect, getSelfPid, spawnLocal, match, receiveWait)


-- onBeat equivalent
tickServerHandler :: Tick -> ServerAction ()
tickServerHandler Tick = do
    ServerConfig myPid peers _ timeout _ <- ask
    ServerState  _ _ _ _ ticksSinceSendOld _ _ _ _<- get
    --increment ticks
    ticksSinceSend += 1
    serverTickCount += 1
    let leader = myPid
    let actionLead
    -- propose if a quorum for the previous block is reached, or a quorum of new view messages, or if it is the first proposal (no previous quorum)
            | (ticksSinceSendOld > timeout) && (leader == myPid) = onPropose
            | otherwise = return ()
    actionLead
    let actionNextView
            | (ticksSinceSendOld > timeout) = onDecide
            | otherwise = return ()
    actionNextView




-- Handle all types of messages
-- CommandMsg from client, ProposeMsg from leader, VoteMsg
-- TODO New View message, 
msgHandler :: Message -> ServerAction ()
--receive commands from client
msgHandler (Message sender recipient (CommandMsg cmd)) = do
    ServerState _ _ _ _ _ mempoolOld _ _ _<- get
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
    ClientState _ _ lastDeliveredOld lastHeight _ cmdRate tick <- get
    --sendIndividualCommands cmdRate tick peers
    --sendNCommands n tick peers
    --lastDelivered .= []
    tickCount += 1
    if V.length lastDeliveredOld > cmdRate
        then lastDelivered .= V.drop ((V.length lastDeliveredOld) - cmdRate) lastDeliveredOld
        else return ()

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
    broadcastAllClient peers (CommandMsg (Command {cmdId = commandString, deliverTime = tick, proposeTime = tick}))
    sentCount += 1

msgHandlerCli :: Message -> ClientAction ()
--record delivered commands
msgHandlerCli (Message sender recipient (DeliverMsg deliverH deliverCmds)) = do
    ClientState _ _ lastDeliveredOld lastHeight _ _ _<- get
    let action
            -- | lastHeight < deliverH = do rHeight += 1
            --                              deliveredCount += length deliverCmds
            --                              lastDelivered .= deliverCmds
            -- | lastHeight == deliverH && lastDeliveredOld /= deliverCmds = do 
            --                                                                 deliveredCount += length deliverCmds
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
    runServer (ServerConfig myPid otherPids (Signature (show randomGen)) timeoutTicks clientPids) (ServerState 0 0 [genesisBlockSingle] [genesisBlockSingle] 0 [] batchSize randomGen 0)

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
    
    clientPids <- replicateM clientCount (spawnClient (batchSize*count))
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
    let memoryPrints = do say $ "Length of dagRecent : " ++ show (length $ _dagRecent state' ) ++ "\n"
                          say $ "Size of dagRecent : " ++ show (getSizeInBytes $ _dagRecent state' ) ++ "\n"
                          say $ "Size of dagFin : " ++ show (getSizeInBytes $ _dagFin state' ) ++ "\n"
                        --   say $ "Size of mempool : " ++ show (getSizeInBytes $ _mempool state' ) ++ "\n"
                        --   say $ "Length of mempool : " ++ show (length $ _mempool state' ) ++ "\n"
    --memoryPrints
    mapM (\msg -> sendWithDelay latency (recipientOf msg) msg) outputMessages
    let !state'' = state'
    runServer config state''

meanTickDifference :: V.Vector Command -> Int -> Double
meanTickDifference commands tick =
    let differences = map (\cmd -> fromIntegral (tick - proposeTime cmd)) (V.toList commands)
    -- let differences = map (\cmd -> fromIntegral (deliverTime cmd - proposeTime cmd)) (V.toList commands)
        total = sum differences
        count = length differences
    in if count == 0 then 0 else total / fromIntegral count


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
        meanLatency = meanTickDifference (lastXElements (_msgRate state') (_lastDelivered state')) (_tickCount state')
    let throughputPrint 
            -- | (_lastDelivered state') /= (_lastDelivered state) = say $ "Current throughput: " ++ show throughput ++ "\n" ++ "deliveredCount: " ++ show (_deliveredCount state') ++ "\n" ++ "tickCount: " ++ show (_tickCount state') ++ "\n" ++ "lastDelivered: " ++ show (V.toList $ _lastDelivered state') ++ "\n"
            | ((_lastDelivered state') /= (_lastDelivered state)) && ((_lastDelivered state') /= V.empty) = say $ "Delivered commands " ++ show (_deliveredCount state') ++ "\n" 
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
    --say $ "Size of lastDelivered : " ++ show (getSizeInBytes (V.toList $ _lastDelivered state')) ++ "\n"
    mapM (\msg -> send (recipientOf msg) msg) outputMessages
    let !state'' = state'
    runClient config state''

getSizeInBytes :: Binary a => a -> Int
getSizeInBytes = fromIntegral . BS.length . encode


main = do
    -- get options from command line
    -- cmdRate just serves as an upper limit on lastDelivered for the client, set to the same as batchSize for now.
    Options replicas crashes cmdRate time batchSize<- parseOptions

    Right transport <- createTransport (defaultTCPAddr "localhost" "0") defaultTCPParameters
    backendNode <- newLocalNode transport initRemoteTable
    runProcess backendNode (spawnAll replicas crashes 1 batchSize batchSize) -- number of replicas, number of crashes, number of clients
    putStrLn $ "Running for " ++ show time ++ " seconds before exiting..."
    threadDelay (time*1000000)  -- 10 seconds in microseconds
    putStrLn "Exiting now."