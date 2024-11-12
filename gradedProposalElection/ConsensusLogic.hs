{-# LANGUAGE BangPatterns #-}

module ConsensusLogic (
    onReceiveProposal, onVote, onEcho, onReceiveVote, onReceiveEcho, getLeader, onReceiveTally, onTally, onPropose, onDecide, execute, randomWithinClient,
    ask, tell, get
) where

import ConsensusDataTypes
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import Data.List (union)
import Control.Monad.RWS.Strict (ask, tell, get, execRWS, liftIO)

randomWithinClient :: Random r => (r,r) -> ClientAction r
randomWithinClient bounds = randomGenCli %%= randomR bounds

-- randomWithin :: Random r => (r,r) -> ServerAction r
-- randomWithin bounds = randomGen %%= randomR bounds

randomWithin :: (Int, Int) -> ServerAction Int
randomWithin bounds = do
    gen <- use randomGen
    let (value, newGen) = randomR bounds gen
    randomGen .= newGen
    return value

-- findBlock :: BlockHash -> [Block] -> Block 
-- findBlock h [b,_] = findBlockDepth h b
-- findBlock h (b:bs) | h == blockHash b = b 
--                    | otherwise = findBlock h bs 

-- findBlock :: BlockHash -> [SingleBlock] -> SingleBlock 
-- findBlock h [b,_] = findBlockDepth h b
-- findBlock h (b:bs) | h == blockHashS b = b 
--                    | otherwise = findBlock h bs 
                
-- findBlockDepth :: BlockHash -> SingleBlock -> SingleBlock
-- findBlockDepth h b | h == blockHashS b = b 
--                    | b == genesisBlock = genesisBlock
--                    | otherwise = findBlockDepth h (parentS b)

-- singleToFull :: SingleBlock -> [Block] -> Block
-- singleToFull sb bRecent = let parentBlock = findBlock (parentS sb) bRecent
--                    in Block {content = contentS sb, height = heightS sb, blockHash = blockHashS sb, parent = [parentBlock]}

appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list

-- Broadcasting
broadcastAll :: [ProcessId] -> MessageType -> ServerAction ()
broadcastAll [single] content = do
    ServerConfig myId _ _ _ _ _<- ask
    tell [Message myId single content]
broadcastAll (single:recipients) content = do
    ServerConfig myId _ _ _ _ _<- ask
    tell [Message myId single content]
    broadcastAll recipients content


onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNew pView = do 
    ServerState cViewOld bLock _ _ _ _ _ _ _ _ mempoolOld _ _<- get
    ServerConfig myPid peers staticSignature _ _ _<- ask
    --let bNew = singleToFull bNewSingle bRecentOld 
    -- bRecent .= appendIfNotExists bNew bRecentOld
    bLeaf .= bNew
    -- mempool .= filter (`notElem` contentS bNew) mempoolOld
    -- phase .= "echo"

onReceiveEcho :: BlockHash -> Signature -> ServerAction ()
onReceiveEcho bNewHash sign = do 
    ServerState _ _ _ _ echoListOld _ _ _ _ _ _ _ _<- get
    --let bNew = findBlock bNewHash bRecent
    let echosB = fromMaybe [] (Map.lookup bNewHash echoListOld)
    let actionAddToList | sign `elem` echosB = return ()
                        | otherwise = do echoList .= Map.insertWith (++) bNewHash [sign] echoListOld                              
    actionAddToList
    -- phase .= "tally"

onReceiveTally :: BlockHash -> Int -> ServerAction ()
onReceiveTally bNewHash tally = do 
    ServerState _ _ _ _ _ tallyListOld _ _ _ _ _ _ _<- get
    -- let bNew = findBlock bNewHash bRecent
    let tallysB = fromMaybe [] (Map.lookup bNewHash tallyListOld)
    do tallyList .= Map.insertWith (++) bNewHash [tally] tallyListOld                              
    -- phase .= "vote"


onReceiveVote :: BlockHash -> Signature -> ServerAction ()
onReceiveVote bNewHash sign = do 
    ServerState _ _ _ _ _ _ voteListOld _ _ _ _ _ _<- get
    -- let bNew = findBlock bNewHash bRecent
    let votesB = fromMaybe [] (Map.lookup bNewHash voteListOld)
    let actionAddToList | sign `elem` votesB = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (bNewHash) [sign] voteListOld                              
    actionAddToList
    -- phase .= "decide"





getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)

onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ _ <- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState cView bLock _ bLeafOld _ _ _ _ _ batchSize _ _ serverTickCount<- get
    let leader = getLeader peers cView
    if leader == myPid then do
        --addNMempool batchSize
        ServerState _ _ _ _ _ _ _ _ _ _ mempool _ _<- get
        --let mempoolBlock = map (setProposeTime serverTickCount) (take batchSize mempool)
        mempoolBlock <- createBatch serverTickCount batchSize
        --let block = Block {content = mempoolBlock, height = cView + 1, blockHash = BlockHash (show hash), parent = [bLeafOld]}
        let singleBlock = SingleBlock {contentS = mempoolBlock, heightS = cView + 1, blockHashS = BlockHash (show hash), parentS = [blockHashS bLeafOld]}
        -- bLeaf .= singleBlock
        broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cView})
    else do
        return ()
    ticksSinceSend .= 0
    phase .= "echo"

setDeliverTime :: Int -> Command -> Command
setDeliverTime tickCount cmd = Command {cmdId = cmdId cmd, deliverTime = tickCount, proposeTime = proposeTime cmd}

-- createBatch :: Int -> Int -> V.Vector Command -> ServerAction (V.Vector Command)
-- createBatch _ 0 batch = return batch
-- createBatch serverTickCount n batch = do
--     let bound1 :: Int
--         bound1 = maxBound
--     commandInt <- randomWithin (0, bound1)
--     let commandString = show commandInt
--         newCmd = Command {cmdId = commandString, deliverTime = serverTickCount, proposeTime = serverTickCount}
--     createBatch serverTickCount (n-1) (V.cons newCmd batch)


createBatch :: Int -> Int -> ServerAction (V.Vector Command)
createBatch serverTickCount size = do
    let go i !acc | i >= size = return acc
                    | otherwise = do
                        commandInt <- randomWithin (0, maxBound :: Int)
                        let commandString = show commandInt
                            newCmd = Command {cmdId = commandString, deliverTime = 0, proposeTime = serverTickCount}
                        go (i + 1) $! (acc `V.snoc` newCmd)
    go 0 V.empty

onEcho :: ServerAction ()
onEcho = do 
    ServerState _ _ _ bLeaf _ _ _ _ _ _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (EchoMsg {echoBlock = blockHashS bLeaf, sign = staticSignature})
    phase .= "tally"

onTally :: ServerAction ()
onTally = do 
    ServerState _ _ _ bLeaf echoList _ _ _ ticksSinceSendOld _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (TallyMsg {tallyBlock = blockHashS bLeaf, tallyNumber = length echoList, sign = staticSignature})
    phase .= "vote"

onVote :: ServerAction ()
onVote = do 
    ServerState _ _ _ bLeaf _ _ _ _ ticksSinceSendOld _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    broadcastAll peers (VoteMsg {voteBlock = blockHashS bLeaf, sign = staticSignature})
    phase .= "decide"

onDecide :: ServerAction ()
onDecide = do 
    ServerState _ _ bExecOld bLeaf _ _ _ _ ticksSinceSendOld _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ _ <- ask
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    execute bLeaf
    cView += 1
    bExec .= bLeaf
    --bRecent .= filter (`notElem` [bLeaf]) bRecentOld
    phase .= "propose"

 -- confirm delivery to all clients and servers
execute :: SingleBlock -> ServerAction ()
execute b = do 
    ServerConfig _ _ _ _ _ clients<- ask
    ServerState _ _ _ _ _ _ _ _ _ _ mempoolOld _ tick<- get
    let cmds = V.fromList $ map (setDeliverTime tick) (V.toList $ contentS b)
    --mempool .= filter (`notElem` cmds) mempoolOld
    echoList .= Map.empty
    tallyList .= Map.empty
    voteList .= Map.empty
    broadcastAll clients (DeliverMsg {deliverCommands = cmds, deliverHeight = heightS b})
    


-- addNMempool :: Int -> ServerAction ()
-- addNMempool 0 = return ()
-- addNMempool n = do
--     ServerState _ _ _ _ _ _ _ _ _ _ mempoolOld _ serverTickCount <- get
--     let bound1 :: Int
--         bound1 = maxBound
--     command <- randomWithin (0, bound1)
--     let commandString = show command
--         newCmd = Command {cmdId = commandString, deliverTime = serverTickCount, proposeTime = 0}
--     mempool .= newCmd:mempoolOld
--     addNMempool (n-1)