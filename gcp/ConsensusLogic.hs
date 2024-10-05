{-# LANGUAGE BangPatterns #-}

module ConsensusLogic (
    onPropose, onVote, onDecide, onReceiveProposal, onReceiveVote, randomWithin,
    ask, tell, get
) where

import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomRIO)
import ConsensusDataTypes
import qualified Data.Map as Map
import Data.Foldable (find)
import Data.List (intersect, nub)
import qualified Data.Vector as V
import Data.List (union)
import Control.Monad.RWS.Strict (ask, tell, get, execRWS, liftIO)

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
commonSubset :: [[String]] -> [String]
commonSubset [] = []  -- Return an empty list if the input is empty
commonSubset (x:xs) = foldl1 intersect (x:xs)

onPropose :: ServerAction ()
onPropose = do
    ServerConfig myPid peers _ _ _ <- ask
    ServerState _ proposeListOld _ _ tick <- get
    let myList = map show [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    x <- randomWithin (8, 9)  -- Randomly select between a and b elements
    dag <- selectRandomElements x myList
    let proposal = DagInput {dag = dag, proposeTime = tick}
    broadcastAll peers (ProposeMsg {proposal = proposal})
    phase .= "vote"

onVote :: ServerAction ()
onVote = do 
    ServerConfig myPid peers _ _ _ <- ask
    ServerState _ proposeListOld _ _ _ <- get
    let voteDag = commonSubset $ map dag proposeListOld
        vote = DagInput {dag = voteDag, proposeTime = proposeTime (head proposeListOld)}
    broadcastAll peers (VoteMsg {vote = vote, proposes = proposeListOld})
    proposeList .= []
    phase .= "decide"

onDecide :: ServerAction ()
onDecide = do 
    ServerState _ _ voteListOld _ _<- get
    ServerConfig myPid _ _ _ clients <- ask
    let decideDag = commonSubset $ map dag voteListOld
        decide = DagInput {dag = decideDag, proposeTime = proposeTime (head voteListOld)}
    broadcastAll clients (DeliverMsg {deliverCommands = decide, tickLatency = proposeTime (head voteListOld)})
    voteList .= []
    phase .= "propose"
    -- serverTickCount .= 0

onReceiveProposal :: DagInput -> ServerAction ()
onReceiveProposal dag = do 
    ServerState _ proposeListOld _ _ _ <- get
    proposeList .= dag:proposeListOld

onReceiveVote :: DagInput -> ServerAction ()
onReceiveVote dag = do
    ServerState _ _ voteListOld _ _ <- get
    voteList .= dag:voteListOld
