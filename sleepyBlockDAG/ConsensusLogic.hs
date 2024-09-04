{-# LANGUAGE BangPatterns #-}

module ConsensusLogic (
    onPropose, onDecide, onReceiveProposal, execute, randomWithinClient,
    ask, tell, get
) where

import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomRIO)
import ConsensusDataTypes
import qualified Data.Map as Map
import qualified Data.Vector as V
import Data.List (union)
import Control.Monad.RWS.Strict (ask, tell, get, execRWS, liftIO)

-- findBlock :: BlockHash -> [Block] -> Block 
-- findBlock h [b,_] = findBlockDepth h b
-- findBlock h (b:bs) | h == blockHash b = b 
--                    | otherwise = findBlock h bs 

randomWithinClient :: Random r => (r,r) -> ClientAction r
randomWithinClient bounds = randomGenCli %%= randomR bounds

randomWithin :: Random r => (r,r) -> ServerAction r
randomWithin bounds = randomGen %%= randomR bounds
    

findBlock :: BlockHash -> [Block] -> Block 
findBlock h [b] = genesisBlock
findBlock h (b:bs) | h == blockHash b = b 
                   | otherwise = findBlock h bs 

findBlocksHeight :: Int -> [Block] -> [Block] -> [Block]
findBlocksHeight h out [] = out
findBlocksHeight h out (b:bs) | h == height b = findBlocksHeight h (b:out) bs
                              | otherwise = findBlocksHeight h out bs

findBlocksHeightSingle :: Int -> [SingleBlock] -> [SingleBlock] -> [SingleBlock]
findBlocksHeightSingle h out [] = out
findBlocksHeightSingle h out (b:bs) | h == heightS b = findBlocksHeightSingle h (b:out) bs
                              | otherwise = findBlocksHeightSingle h out bs


findBlockDepth :: BlockHash -> Block -> Block
findBlockDepth h b | h == blockHash b = b 
                   | b == genesisBlock = genesisBlock
                   | otherwise = findBlockDepth h (head $ parent b)

-- Broadcasting
broadcastAll :: [ProcessId] -> MessageType -> ServerAction ()
broadcastAll [single] content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
broadcastAll (single:recipients) content = do
    ServerConfig myId _ _ _ _<- ask
    tell [Message myId single content]
    broadcastAll recipients content


-- singleToFull :: SingleBlock -> [Block] -> Block
-- singleToFull sb bList = let parentBlocks = map (\x -> findBlock x bList) (parentS sb) --obtain list of parent as Block type from the list of parent hashes in sb
--                    in Block {content = contentS sb, height = heightS sb, blockHash = blockHashS sb, parent = parentBlocks}



getBlocksFromHeight :: Map.Map Int [SingleBlock] -> Int -> [SingleBlock]
getBlocksFromHeight heightsMap height = fromMaybe [] (Map.lookup height heightsMap)


appendIfNotExists :: Eq a => a -> [a] -> [a]
appendIfNotExists x xs
  | x `elem` xs = xs  -- Element already exists, return the original list
  | otherwise   = x : xs  -- Append the element to the list

addNMempool :: Int -> ServerAction ()
addNMempool 0 = return ()
addNMempool n = do
    ServerState _ _ _ _ _ mempoolOld _ _ serverTickCount <- get
    let bound1 :: Int
        bound1 = maxBound
    command <- randomWithin (0, bound1)
    let commandString = show command
        newCmd = Command {cmdId = commandString, deliverTime = serverTickCount, proposeTime = 0}
    mempool .= newCmd:mempoolOld
    addNMempool (n-1)

{-# SCC onReceiveProposal #-}
onReceiveProposal :: SingleBlock -> Int -> ServerAction ()
onReceiveProposal bNewSingle pView = do 
    ServerState _ _ _ dagRecentOld _ mempoolOld _ _ _<- get
    ServerConfig myPid peers staticSignature _ _<- ask
 --   let parentsBlocks = map (\x -> findBlock x dagRecentOld) $ parentS bNewSingle
 --       bNew = Block {content = contentS bNewSingle, height = heightS bNewSingle, blockHash = blockHashS bNewSingle, parent = parentsBlocks}
    let dagRecentNew = appendIfNotExists bNewSingle dagRecentOld
        --sameHeight = findBlocksHeight (heightS bNewSingle) [] dagRecentOld                           
    dagRecent .= dagRecentNew
    mempool .= filter (`notElem` contentS bNewSingle) mempoolOld

getLeader :: [ProcessId] -> Int -> ProcessId
getLeader list v = list !! mod v (length list)

{-# SCC onPropose #-}
onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    -- dummy random hash 
    let bound1 :: Int
        bound1 = maxBound
    hash <- randomWithin (0, bound1)
    ServerState cHeightOld _ _ dagRecentOld _ _ batchSize _ serverTickCount <- get
    --addNMempool batchSize
    ServerState _ _ _ _ _ mempool _ _ _ <- get
    -- next view, reset timers for all peers
    ticksSinceSend .=0
    mempoolBlock <- createBatch serverTickCount batchSize
    let --parentsSingle = getBlocksFromHeight heightsMap cHeightOld
        --parentsHash = map blockHashS parentsSingle
        --parentsBlocks = map (\x -> findBlock x dagRecentOld) parentsHash
        --mempoolBlock = map (setProposeTime serverTickCount) (take batchSize mempool)
        
        --parentsBlocks = findBlocksHeight cHeightOld [] dagRecentOld
        parentsBlocks = findBlocksHeightSingle cHeightOld [] dagRecentOld
        parentsHash = map blockHashS parentsBlocks
        --block = Block {content = mempoolBlock, height = cHeightOld + 1, blockHash = BlockHash (show hash), parent = parentsBlocks}
    --dagRecent .= appendIfNotExists block dagRecentOld
    
    let singleBlock = SingleBlock {contentS = mempoolBlock, heightS = cHeightOld + 1, blockHashS = BlockHash (show hash), parentS = parentsHash}
    broadcastAll peers (ProposeMsg {proposal = singleBlock, pView = cHeightOld + 1})
    cHeight += 1

setDeliverTime :: Int -> Command -> Command
setDeliverTime tickCount cmd = Command {cmdId = cmdId cmd, deliverTime = tickCount, proposeTime = proposeTime cmd}


-- createBatch :: Int -> Int -> [Command] -> ServerAction [Command]
-- createBatch _ 0 batch = return batch
-- createBatch serverTickCount n batch = do
--     let bound1 :: Int
--         bound1 = maxBound
--     commandInt <- randomWithin (0, bound1)
--     let commandString = show commandInt
--         newCmd = Command {cmdId = commandString, deliverTime = serverTickCount, proposeTime = serverTickCount}
--     createBatch serverTickCount (n-1) (newCmd:batch)
{-# SCC createBatch #-}
createBatch :: Int -> Int -> ServerAction (V.Vector Command)
createBatch serverTickCount size = do
    let go i !acc | i >= size = return acc
                    | otherwise = do
                        commandInt <- randomWithin (0, maxBound :: Int)
                        let commandString = show commandInt
                            newCmd = Command {cmdId = commandString, deliverTime = 0, proposeTime = serverTickCount}
                        go (i + 1) $! (acc `V.snoc` newCmd)
    go 0 V.empty
-- createBatch :: Int -> Int -> V.Vector Command -> ServerAction (V.Vector Command)
-- createBatch _ 0 batch = return batch
-- createBatch serverTickCount n batch = do
--     let bound1 :: Int
--         bound1 = maxBound
--     commandInt <- randomWithin (0, bound1)
--     let commandString = show commandInt
--         newCmd = Command {cmdId = commandString, deliverTime = serverTickCount, proposeTime = serverTickCount}
--     createBatch serverTickCount (n-1) (V.cons newCmd batch)

{-# SCC onDecide #-}
onDecide :: ServerAction ()
onDecide = do 
    ServerState cHeightOld _ dagFinOld dagRecentOld _ _ _ _ _<- get
    ServerConfig myPid peers staticSignature _ _ <- ask
    -- let finBlocksSingle = getBlocksFromHeight heightsMap $ abs (cHeightOld - 2)
    -- let finBlocks = map (\x -> singleToFull x dagRecentOld) finBlocksSingle
    let heightToFin = max 0  (cHeightOld - 3)
        finBlocks = findBlocksHeightSingle heightToFin [] dagRecentOld
    execute finBlocks
    dagRecent .= filter (`notElem` finBlocks) dagRecentOld
    --dagFin .= union finBlocks dagFinOld 
    dagFin .= finBlocks
    finHeight .= heightToFin

 -- confirm delivery to all clients and servers
execute :: [SingleBlock] -> ServerAction ()
execute [] = do return ()
execute (b:bs) = do 
    ServerConfig _ _ _ _ clients<- ask
    ServerState _ _ _ _ _ mempoolOld _ _ tick<- get
    let cmds = V.fromList $ map (setDeliverTime tick) (V.toList $ contentS b)
    mempool .= filter (`notElem` cmds) mempoolOld
    -- dagFin .= appendIfNotExists b dagFinOld
    broadcastAll clients (DeliverMsg {deliverCommands = cmds, deliverHeight = heightS b})
    execute bs