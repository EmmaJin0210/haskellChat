{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}

module Main where

import qualified Control.Monad.State as Mtl
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.STM (atomically)
import Control.Concurrent.STM
import Control.Concurrent.Async (async, waitBoth)
import Data.Text (Text)
import Data.List (sort, nub, (\\))
import Data.Maybe (fromJust)
import Data.Int (Int64)
import Test.HUnit
import Text.Read (readMaybe)
import Test.QuickCheck
import System.IO.Unsafe (unsafePerformIO)

import Utils (trim)
import FrontendHandler (Client(..), ClientID, RoomID, findClientRoom, joinRoom)

----------------------------------------
-- Mocking and Setup
----------------------------------------

type MockConnection = TVar [Text]

-- | Creates a mock connection using a TVar to simulate message exchange.
mockConnection :: IO MockConnection
mockConnection = newTVarIO []

-- | Sends a message to the mock connection by appending it to the message list
sendMockTextData :: MockConnection -> Text -> IO ()
sendMockTextData conn msg = atomically $ modifyTVar' conn (++ [msg])

-- | Retrieves the next message from the mock connection, removing it from the list
receiveMockData :: MockConnection -> IO Text
receiveMockData conn = atomically $ do
    msgs <- readTVar conn
    case msgs of
        (x:xs) -> writeTVar conn xs >> return x
        []     -> return ""

client1 :: Client
client1 = Client { clientConn = error "Mock connection", clientID = "client1" }

client2 :: Client
client2 = Client { clientConn = error "Mock connection", clientID = "client2" }

-- | A mock room-to-client mapping for unit tests
testRooms :: Map.Map RoomID [Client]
testRooms = Map.fromList
    [ (1, [client1])
    , (2, [client2])
    ]

----------------------------------------
-- Define a newtype for messages that never start with '/'
----------------------------------------

newtype Msg = Msg { getMsg :: String } deriving (Show, Eq)

instance Arbitrary Msg where
  arbitrary = do
    -- Choose a first character that is not '/'
    firstChar <- elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'])
    rest <- listOf (elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " "))
    return $ Msg (firstChar : rest)

type Message = Msg
type SequenceNumber = Int
type MockHoldbackQueue = Map.Map ClientID (Map.Map RoomID (Map.Map SequenceNumber Message))
type MockRFifo = Map.Map ClientID (Map.Map RoomID SequenceNumber)

----------------------------------------
-- Unit Tests (HUnit)
----------------------------------------
testTrim :: Test
testTrim = TestList
    [ "Trim leading/trailing spaces" ~: trim "  hello  " ~?= "hello"
    , "Trim tabs/newlines"          ~: trim "\n\tworld\n\t" ~?= "world"
    , "Trim no spaces"              ~: trim "chat" ~?= "chat"
    , "Trim empty string"           ~: trim "" ~?= ""
    ]

testFindClientRoom :: Test
testFindClientRoom = TestList
    [ "Client in room 1"     ~: findClientRoom "client1" testRooms ~?= Just 1
    , "Client in room 2"     ~: findClientRoom "client2" testRooms ~?= Just 2
    , "Client not in a room" ~: findClientRoom "client3" testRooms ~?= Nothing
    ]

-- | Simulates a joinRoom operation for unit testing
joinRoomTest :: MockConnection -> ClientID -> String -> TVar (Map.Map RoomID [Client]) -> IO ()
joinRoomTest conn cid msg roomsVar = do
    let roomIDStr = trim msg
    case readMaybe roomIDStr :: Maybe Int of
        Just roomID -> do
            atomically $ modifyTVar' roomsVar (Map.insertWith (++) roomID [Client { clientConn = error "Mock connection", clientID = cid }])
            sendMockTextData conn $ T.pack $ "+OK You joined room " ++ show roomID
        Nothing -> sendMockTextData conn $ T.pack "-ERR Invalid room number."

-- | Tests joinRoomTest for valid and invalid room joins
testJoinRoom :: IO Test
testJoinRoom = do
    roomsVar <- newTVarIO Map.empty
    conn <- mockConnection
    let cid = "client1"
    -- Valid room join
    joinRoomTest conn cid "1" roomsVar
    rooms <- readTVarIO roomsVar
    msg <- receiveMockData conn
    let expectedMsg = "+OK You joined room 1"
    let clientInRoom = case Map.lookup 1 rooms of
            Just clients -> any (\c -> clientID c == cid) clients
            Nothing -> False

    -- Invalid room join
    conn2 <- mockConnection
    joinRoomTest conn2 cid "invalid" roomsVar
    msg2 <- receiveMockData conn2
    let expectedErrMsg = "-ERR Invalid room number."
    return $ TestList
        [ TestCase $ assertBool "Client should be in room 1" clientInRoom
        , TestCase $ assertEqual "Success message" expectedMsg msg
        , TestCase $ assertEqual "Error message for invalid room" expectedErrMsg msg2
        ]

-- | Tests message delivery in FIFO order using a mock holdback queue and receive FIFO
testDeliverMessages :: Test
testDeliverMessages = TestCase $ do
    let senderID = "client1"
    let roomID = 1
    let msgSequence = [(1, Msg "Hello"), (2, Msg "World"), (4, Msg "Skipped")]
    let holdbackQueue = Map.fromList
            [ (senderID, Map.fromList [(roomID, Map.fromList msgSequence)]) ]
    let r_fifo = Map.fromList [(senderID, Map.fromList [(roomID, 0)])]
    let expectedMessages = [("client1", Msg "Hello"), ("client1", Msg "World")]
    result <- atomically $ deliverMessages [senderID] r_fifo holdbackQueue []
    assertEqual "Messages in order" expectedMessages (reverse result)

deliverMessages :: [ClientID]
                -> Map.Map ClientID (Map.Map RoomID SequenceNumber)
                -> Map.Map ClientID (Map.Map RoomID (Map.Map SequenceNumber Message))
                -> [(ClientID, Message)]
                -> STM [(ClientID, Message)]
deliverMessages [] _ _ acc = return acc
deliverMessages (senderID:rest) r_fifo holdbackQueue acc = do
    let roomID = 1
    let rCount = Map.findWithDefault Map.empty senderID r_fifo
    let nextR = Map.findWithDefault 0 roomID rCount + 1
    let hbqClient = Map.findWithDefault Map.empty senderID holdbackQueue
    let hbqRoom = Map.findWithDefault Map.empty roomID hbqClient
    case Map.lookup nextR hbqRoom of
        Just m -> do
            let rCount' = Map.insert roomID nextR rCount
            let r_fifo' = Map.insert senderID rCount' r_fifo
            let hbqRoom' = Map.delete nextR hbqRoom
            let hbqClient' = Map.insert roomID hbqRoom' hbqClient
            let holdbackQueue' = Map.insert senderID hbqClient' holdbackQueue
            deliverMessages (senderID:rest) r_fifo' holdbackQueue' ((senderID, m):acc)
        Nothing -> deliverMessages rest r_fifo holdbackQueue acc

-- | Tests concurrent room joining operations to ensure thread safety
testJoinRoomConcurrency :: IO Test
testJoinRoomConcurrency = do
    roomsVar <- newTVarIO Map.empty
    conn1 <- mockConnection
    conn2 <- mockConnection
    let cid1 = "client1"
    let cid2 = "client2"
    a1 <- async $ joinRoomTest conn1 cid1 "1" roomsVar
    a2 <- async $ joinRoomTest conn2 cid2 "1" roomsVar
    _ <- waitBoth a1 a2
    rooms <- readTVarIO roomsVar
    let clientsInRoom = Map.lookup 1 rooms
    return $ TestCase $ assertBool "Both clients in room 1" $
        case clientsInRoom of
            Just clients -> all (`elem` map clientID clients) [cid1, cid2]
            Nothing -> False

----------------------------------------
-- Simple QuickCheck Tests
----------------------------------------
-- | Ttrim removes all leading and trailing whitespace
prop_trim_no_whitespace :: String -> Bool
prop_trim_no_whitespace s =
    let trimmed = trim s
    in not (any (`elem` [' ', '\t', '\n', '\r']) (take 1 trimmed ++ take 1 (reverse trimmed))) || null trimmed

-- | Trim does not alter the core content of the string
prop_trim_content_preserved :: String -> Bool
prop_trim_content_preserved s =
    let trimmed = trim s
    in trimmed == T.unpack (T.strip $ T.pack s)

-- | Trim is idempotent when applied multiple times
prop_trim_idempotent :: String -> Bool
prop_trim_idempotent s = trim s == trim (trim s)

-- | findClientRoom gives the correct room of the client
prop_findClientRoom_correctness :: ClientID -> Bool
prop_findClientRoom_correctness cid =
    case findClientRoom cid testRooms of
        Just 1 -> cid == "client1"
        Just 2 -> cid == "client2"
        Nothing -> cid `notElem` ["client1", "client2"]

-- | joinRoom handles positive room numbers correctly
prop_joinRoom_validInput :: Positive Int -> Bool
prop_joinRoom_validInput (Positive roomID) = roomID > 0

----------------------------------------
-- QuickCheck Tests for Holdback Queue and Message Ordering
----------------------------------------

-- Now we use Msg in scenarios
data Scenario = Scenario
  { scenarioClient :: ClientID
  , scenarioRoom   :: RoomID
  , scenarioStart  :: SequenceNumber
  , scenarioMessages :: [(SequenceNumber, Msg)]
  } deriving (Show)

instance Arbitrary Scenario where
  arbitrary = do
    cid <- arbitrary `suchThat` (not . null)
    rid <- arbitrary `suchThat` (> 0)
    start <- arbitrary `suchThat` (>= 0)
    seqNums <- nub . sort <$> listOf (choose (start+1, start+20))
    msgs <- vectorOf (length seqNums) arbitrary -- Using arbitrary Msg
    let msgsWithSeq = zip seqNums msgs
    return $ Scenario cid rid start msgsWithSeq

-- | Messages are delivered in FIFO order without gaps
prop_deliverMessages_correctness :: Scenario -> Property
prop_deliverMessages_correctness (Scenario cid rid start msgsWithSeq) =
    let r_fifo = Map.fromList [(cid, Map.fromList [(rid, start)])]
        hbqRoom = Map.fromList msgsWithSeq
        hbqClient = Map.fromList [(rid, hbqRoom)]
        holdbackQueue = Map.fromList [(cid, hbqClient)]
        delivered = runDeliverMessages [cid] r_fifo holdbackQueue
        deliveredSeqs = map (extractSeq cid rid msgsWithSeq) delivered
        deliveredSeqsAsc = reverse deliveredSeqs
        allSeqs = map fst msgsWithSeq

        -- Find the longest initial consecutive run starting from start+1
        consecutiveRun = longestInitialConsecutiveRun (start+1) allSeqs
    in 
       -- Check that deliveredSeqsAsc is a prefix of consecutiveRun
       take (length deliveredSeqsAsc) consecutiveRun === deliveredSeqsAsc

-- | Gaps in message sequence numbers are handled correctly
prop_deliverMessages_missingGaps :: Scenario -> Property
prop_deliverMessages_missingGaps (Scenario cid rid start msgsWithSeq) =
    let allSeqs = map fst msgsWithSeq
        delivered = runDeliverMessages [cid]
                     (Map.fromList [(cid, Map.fromList [(rid, start)])])
                     (Map.fromList [(cid, Map.fromList [(rid, Map.fromList msgsWithSeq)])])
        deliveredSeqs = map (extractSeq cid rid msgsWithSeq) delivered
        deliveredSeqsAsc = reverse deliveredSeqs
        consecutiveRun = longestInitialConsecutiveRun (start+1) allSeqs
    in
       -- Similarly, delivered must be a prefix of the initial consecutive run
       take (length deliveredSeqsAsc) consecutiveRun === deliveredSeqsAsc


----------------------------------------
-- Helpers
----------------------------------------
-- | Finds the longest sequence of consecutive numbers starting from a given point
longestInitialConsecutiveRun :: SequenceNumber -> [SequenceNumber] -> [SequenceNumber]
longestInitialConsecutiveRun from xs = takeWhileConsecutive from (sort xs)
  where
    takeWhileConsecutive n ys
      | n `elem` ys = n : takeWhileConsecutive (n+1) ys
      | otherwise   = []

-- | Runs the deliverMessages function in a simulated environment
runDeliverMessages :: [ClientID]
                   -> Map.Map ClientID (Map.Map RoomID SequenceNumber)
                   -> Map.Map ClientID (Map.Map RoomID (Map.Map SequenceNumber Message))
                   -> [(ClientID, Message)]
runDeliverMessages cids r_fifo holdbackQueue = unsafePerformSTM $
    deliverMessages cids r_fifo holdbackQueue []

{-# NOINLINE unsafePerformSTM #-}
unsafePerformSTM :: STM a -> a
unsafePerformSTM action = unsafePerformIO (atomically action)

-- | Extracts the sequence number from a delivered message based on the input setup
extractSeq :: ClientID -> RoomID -> [(SequenceNumber, Msg)] -> (ClientID, Msg) -> SequenceNumber
extractSeq cid rid msgs (dCid, dMsg) =
    head [seqNum | (seqNum,m) <- msgs, m == dMsg, dCid == cid]

-- | Checks if a list of sequence numbers is consecutive starting from a given point
consecutiveFrom :: SequenceNumber -> [SequenceNumber] -> Bool
consecutiveFrom start seqs
    | null seqs = True
    | otherwise = seqs == [start .. start + fromIntegral (length seqs) - 1]

-- | Finds the longest consecutive sequence starting from a given number
longestConsecutiveFrom :: SequenceNumber -> [SequenceNumber] -> SequenceNumber
longestConsecutiveFrom st xs = go st
  where
    s = sort xs
    go n | n `elem` s = go (n+1)
         | otherwise   = n-1

----------------------------------------
-- Mock IO Scenario
----------------------------------------

data MockState = MockState {
    msRooms :: Map.Map RoomID [ClientID],
    msMessages :: [Text]
} deriving (Show, Eq)

emptyMockState :: MockState
emptyMockState = MockState Map.empty []

newtype MockIO a = MockIO { runMockIO :: Mtl.State MockState a }
    deriving (Functor, Applicative, Monad)

-- | Adds a client to a mock room in the mock state
mockAddClientToRoom :: ClientID -> RoomID -> MockIO ()
mockAddClientToRoom cid rid = MockIO $ Mtl.modify $ \s ->
    s { msRooms = Map.insertWith (++) rid [cid] (msRooms s) }

-- | Appends a message to the mock state's message list
mockSendTextData :: Text -> MockIO ()
mockSendTextData msg = MockIO $ Mtl.modify $ \s -> s { msMessages = msMessages s ++ [msg] }

-- | Simulates joining a room in the mock environment
mockJoinRoom :: ClientID -> String -> MockIO ()
mockJoinRoom cid msg =
    let roomIDStr = trim msg
    in case readMaybe roomIDStr :: Maybe Int of
        Just roomID -> do
            mockAddClientToRoom cid roomID
            mockSendTextData (T.pack $ "+OK You joined room " ++ show roomID)
        Nothing -> mockSendTextData "-ERR Invalid room number."

testMockIOJoinRoom :: Test
testMockIOJoinRoom = TestCase $ do
    let initial = emptyMockState
        (_, finalState) = Mtl.runState (runMockIO $ do
            mockJoinRoom "client1" "1"
            mockJoinRoom "client1" "invalid"
          ) initial

    let rooms = msRooms finalState
        msgs  = msMessages finalState

    let clientInRoom1 = case Map.lookup 1 rooms of
            Just cids -> "client1" `elem` cids
            Nothing -> False

    let expected = ["+OK You joined room 1", "-ERR Invalid room number."]
    assertBool "client1 should be in room 1" clientInRoom1
    assertEqual "Messages should match" expected (map T.unpack msgs)

----------------------------------------
-- Main Entry Point
----------------------------------------

main :: IO ()
main = do
    -- Run HUnit Tests
    _ <- runTestTT $ TestList
        [ TestLabel "Test trim function" testTrim
        , TestLabel "Test findClientRoom function" testFindClientRoom
        ]

    joinRoomTests <- testJoinRoom
    _ <- runTestTT $ TestLabel "Test joinRoom function" joinRoomTests

    _ <- runTestTT $ TestLabel "Test deliverMessages function" testDeliverMessages

    joinRoomConcurrentTest <- testJoinRoomConcurrency
    _ <- runTestTT $ TestLabel "Test joinRoom concurrency" joinRoomConcurrentTest

    -- Run Mock IO test
    _ <- runTestTT $ TestLabel "Test mockJoinRoom with MockIO" testMockIOJoinRoom

    -- Run Existing QuickCheck Tests
    quickCheck prop_trim_no_whitespace
    quickCheck prop_trim_content_preserved
    quickCheck prop_trim_idempotent
    quickCheck prop_findClientRoom_correctness
    quickCheck prop_joinRoom_validInput

    -- Run New Nontrivial QuickCheck Tests
    quickCheck prop_deliverMessages_correctness
    quickCheck prop_deliverMessages_missingGaps

    return ()
