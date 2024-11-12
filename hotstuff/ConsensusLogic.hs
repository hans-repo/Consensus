{-# LANGUAGE BangPatterns #-}


module ConsensusLogic (
    onReceiveProposal, onReceiveVote, onReceiveNewView, getLeader, onPropose, randomWithin, randomWithinClient, findBlock, appendIfNotExists, onNextSyncView, ask, tell, get
) where

import ConsensusDataTypes
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import Data.List (union)
import Control.Monad.RWS.Strict (ask, tell, get, execRWS, liftIO)


randomWithinClient :: Random r => (r,r) -> ClientAction r
randomWithinClient bounds = randomGenCli %%= randomR bounds

randomWithin :: Random r => (r,r) -> ServerAction r
randomWithin bounds = randomGen %%= randomR bounds




findBlock :: BlockHash -> [SingleBlock] -> SingleBlock 
findBlock h [b] = b
findBlock h (b:bs) | h == blockHashS b = b 
                   | otherwise = findBlock h bs 
                
-- findBlockDepth :: BlockHash -> SingleBlock -> [SingleBlock] -> SingleBlock
-- findBlockDepth h b blockSet | h == blockHashS b = b 
--                             | b == genesisBlockSingle = genesisBlockSingle
--                             | otherwise = findBlockDepth h (head $ parentS b) blockSet



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


sendSingle :: ProcessId -> ProcessId -> MessageType -> ServerAction ()
sendSingle myId single content = do
    tell [Message myId single content]


-- Event driven Hotstuff
onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ _<- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState _ cView bLock _ bLeafOld bRecentOld qcHigh _ _ batchSize _ serverTickCount _ <- get
    mempoolBlock <- createBatch serverTickCount batchSize
    let singleBlock = SingleBlock {contentS = mempoolBlock, qcS = qcHigh, heightS = cView + 1, blockHashS = BlockHash (show hash), parentS = [blockHashS bLeafOld]}
    bLeaf .= singleBlock
    bRecent .= appendIfNotExists singleBlock bRecentOld
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
onReceiveProposal bNew pView = do 
    ServerState vHeightOld cViewOld bLock _ _ bRecentOld _ _ _ _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ _<- ask
    let action | (heightS bNew > vHeightOld) && ( hash (qcS bNew) == blockHashS bLock || heightS bNew > heightS bLock) = do
                                -- next view, reset timers for all peers
                                cView += 1
                                ticksSinceMsg .= Map.fromList [(key, 0) | key <- peers]
                                vHeight .= heightS bNew
                                sendSingle myPid (getLeader peers (1+ cViewOld)) (VoteMsg {votedBlock = blockHashS bNew, sign = staticSignature})
               | otherwise = return ()
    action
    bRecent .= appendIfNotExists bNew bRecentOld
    updateChain bNew


onReceiveVote :: BlockHash -> Signature -> ServerAction ()
onReceiveVote bNewHash sign = do 
    ServerState _ _ _ _ _ bRecent _ voteListOld _ _ _ _ _<- get
    let bNew = findBlock bNewHash bRecent
        votesB = fromMaybe [] (Map.lookup (blockHashS bNew) voteListOld)
    let actionAddToList | sign `elem` votesB = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (blockHashS bNew) [sign] voteListOld                              
    actionAddToList
    -- get state again for the new voteList
    ServerState _ _ _ _ _ _ _ voteListNew ticksSinceMsg _ _ _ _<- get
    let votesBNew = fromMaybe [] (Map.lookup (blockHashS bNew) voteListNew)
        quorum = 2 * div (Map.size ticksSinceMsg) 3 + 1
    let action  | length votesBNew >= quorum = do updateQCHigh $ QC {signatures = votesBNew, hash = bNewHash}
                | otherwise = return ()
    action

onCommit :: SingleBlock -> SingleBlock -> ServerAction ()
onCommit bExec b = do 
    let action | heightS bExec < heightS b = do -- onCommit bExec (head (parentS b))
                                                execute (heightS bExec) (contentS b)
               | otherwise = return ()
    action

 -- confirm delivery to all clients and servers
execute :: Int -> V.Vector Command -> ServerAction ()
execute height cmds = do 
    ServerState _ _ _ _ _ _ _ _ _ _ _ tick _ <- get
    ServerConfig _ _ _ _ _ clients<- ask
    let toDeliverCmds = V.fromList $ map (setDeliverTime tick) (V.toList cmds)
    broadcastAll clients (DeliverMsg {deliverCommands = toDeliverCmds, deliverHeight = height})

setDeliverTime :: Int -> Command -> Command
setDeliverTime tickCount cmd = Command {cmdId = cmdId cmd, deliverTime = tickCount, proposeTime = proposeTime cmd}


--Need to input the latest block so that findBlock doesn't search from bLeaf which isn't updated yet
updateQCHigh :: QC -> ServerAction ()
updateQCHigh qc = do
    ServerState _ _ _ _ _ bRecent qcHighOld _ _ _ _ _ _<- get
    let qcNode = findBlock (hash qc) bRecent
        qcNodeOld = findBlock (hash qcHighOld) bRecent
        action  | heightS qcNode > heightS qcNodeOld = do qcHigh .= qc
                                                          bLeaf .= qcNode
                | otherwise = return ()
    action

updateChain :: SingleBlock -> ServerAction ()
updateChain bStar = do 
    ServerState _ _ bLockOld bExecOld _ bRecent qcHigh _ _ _ _ _ _<- get
    updateQCHigh $ qcS bStar
    let b'' = findBlock (hash $ qcS bStar) bRecent
        b'  = findBlock (hash $ qcS b'') bRecent
        b   = findBlock (hash $ qcS b') bRecent
        -- b'  = findBlockDepth (hash $ qcS b'') b'' bRecent
        -- b   = findBlockDepth (hash $ qcS b') b' bRecent
        actionL | heightS b' > heightS bLockOld = do bLock .= b'
                | otherwise = return ()
        actionC | (parentS b'' == map blockHashS [b']) && (parentS b' == map blockHashS [b]) = do onCommit bExecOld b 
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
    ServerConfig myPid peers staticSignature _ _ _<- ask
    -- next view, reset timers for all peers
    cView += 1
    ticksSinceMsg .= Map.fromList [(key, 0) | key <- peers]
    sendSingle myPid (getLeader peers (1+ cViewOld)) (NewViewMsg {newViewQC= qcHigh, newViewId = cViewOld, newViewSign = staticSignature}) 

onReceiveNewView :: Int -> QC -> Signature -> ServerAction ()
onReceiveNewView view qc sign = do 
    ServerState _ _ _ _ _ _ _ voteListOld ticksSinceMsg _ _ _ _<- get
    let votes = voteListOld
        votesT = fromMaybe [] (Map.lookup (BlockHash $ show view) votes)
    let actionAddToList | sign `elem` votesT = return ()
                        | otherwise = do voteList .= Map.insertWith (++) (BlockHash $ show view) [sign] voteListOld
    actionAddToList
    updateQCHigh qc 
