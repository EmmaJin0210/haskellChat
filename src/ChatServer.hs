{-# LANGUAGE OverloadedStrings #-}
module ChatServer (
    SFifo,
    RFifo,
    HoldbackQueue,
    Message,
    AckTracker,
    handleClient,
    fifoMulticast,
    fifoReceive,
    deliverFIFO,
    processAck,
    startRetransmissionThread,
    checkForResend,
    udpListener,
    serverApp,
    loadServerConfigsWithProxy,
    loadServerConfigs
) where

import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BS
import Data.Text (Text)
import Data.List (isPrefixOf, intercalate)
import Text.Read (readMaybe)
import Control.Concurrent.STM
import Control.Monad (forever, unless, forM_, void)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (finally)
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendTo)
import Network.WebSockets (ServerApp, acceptRequest, receiveData, sendTextData, Connection)
import Utils
import FrontendHandler


-- Type Definitions
-- main server
type Message = String
type SequenceNumber = Int
type SFifo = TVar (Map.Map ClientID (Map.Map RoomID SequenceNumber))
type RFifo = TVar (Map.Map ClientID (Map.Map RoomID SequenceNumber))
type HoldbackQueue = TVar (Map.Map ClientID (Map.Map RoomID (Map.Map SequenceNumber Message)))

-- fault tolerance
type MessageID = (RoomID, ClientID, SequenceNumber)
type AckTracker = TVar (Map.Map MessageID (Message, Map.Map ServerAddress Bool, ServerAddress))

---------------------------------------
-- Server Application
---------------------------------------
serverApp :: Clients -> Rooms -> SFifo -> RFifo -> HoldbackQueue -> Socket -> [ServerAddress] -> ServerAddress -> AckTracker -> String -> ServerApp
serverApp clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock otherServerAddrs proxyAddr ackTrackerVar serverUrl pending = do
    conn <- acceptRequest pending
    clientID' <- makeClientID pending
    atomically $ modifyTVar' clientsVar (Map.insert clientID' (Client { clientConn = conn, clientID = clientID' }))
    putStrLn $ clientID' ++ " connected and ready."

    finally (handleClient conn clientID' clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock otherServerAddrs proxyAddr ackTrackerVar)
            (cleanupClient clientID' clientsVar roomsVar serverUrl)

---------------------------------------
-- Loading Config
---------------------------------------
loadServerConfigsWithProxy :: FilePath -> IO [(ServerAddress, ServerAddress)]
loadServerConfigsWithProxy path = do
    contents <- lines <$> readFile path
    return $ map parseServerLine contents
  where
    parseServerLine line =
        case splitOn ',' line of
            [proxy, bindAddr] -> (parseSockAddr proxy, parseSockAddr bindAddr)
            _                 -> error $ "Invalid line in server list: " ++ line

loadServerConfigs :: FilePath -> IO [ServerAddress]
loadServerConfigs path = do
    contents <- lines <$> readFile path
    return $ map (snd . parseServerLine) contents
  where
    parseServerLine line =
        case splitOn ',' line of
            [proxy, bindAddr] -> (parseSockAddr proxy, parseSockAddr bindAddr)
            _                 -> error $ "Invalid line in server list: " ++ line

---------------------------------------
-- Client Handling
---------------------------------------
-- | Handle WebSocket client connection.
handleClient :: Connection -> ClientID -> Clients -> Rooms -> SFifo -> RFifo -> HoldbackQueue -> Socket -> [ServerAddress] -> ServerAddress -> AckTracker -> IO ()
handleClient conn cid clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock addressPairs proxyAddr ackTrackerVar = forever $ do
    msgText <- receiveData conn :: IO Text
    let rawMsg = T.unpack msgText
        msg = if head rawMsg == '"' && last rawMsg == '"'
              then init (tail rawMsg) -- Remove surrounding quotation marks
              else rawMsg
    putStrLn $ "Received from " ++ cid ++ ": " ++ msg
    if "/join" `isPrefixOf` msg
        then joinRoom conn cid (drop 6 msg) roomsVar
        else fifoMulticast conn cid msg clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock addressPairs proxyAddr ackTrackerVar

---------------------------------------
-- FIFO Multicast and Delivery
---------------------------------------
-- | Sends a message to all proxies and initiates FIFO ordering for delivery
fifoMulticast :: Connection -> ClientID -> Message -> Clients -> Rooms -> SFifo -> RFifo -> HoldbackQueue -> Socket -> [ServerAddress] -> ServerAddress -> AckTracker -> IO ()
fifoMulticast conn cid msg clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock addressPairs proxyAddr ackTrackerVar = do
    rooms <- readTVarIO roomsVar
    let maybeRoomID = findClientRoom cid rooms
    case maybeRoomID of
        Nothing -> sendTextData conn $ T.pack "\"-ERR You are not in a room. Please join a room first.\""
        Just roomID -> do
            seqNum <- atomically $ do
                s_fifo <- readTVar s_fifoVar
                let sCount = Map.findWithDefault Map.empty cid s_fifo
                let nextS = Map.findWithDefault 0 roomID sCount + 1
                let sCount' = Map.insert roomID nextS sCount
                writeTVar s_fifoVar (Map.insert cid sCount' s_fifo)
                return nextS
            let mid = (roomID, cid, seqNum)
            let msgClean = normalizeMessage msg
            let originPort = maybe "UnknownPort" (\port -> show (fromIntegral port :: Integer)) (extractPort proxyAddr)

            let msgToSend = BS.pack $ intercalate "|" [show roomID, cid, show seqNum, originPort, originPort, msgClean]

            -- Send to proxy addresses only
            unless (null addressPairs) $ do
                let ackMaps = Map.fromList [(addr, False) | addr <- addressPairs]
                putStrLn $ "Multicasting to proxy addresses: " ++ show addressPairs
                putStrLn $ "Message ID: " ++ show mid
                putStrLn $ "Message: " ++ msgClean
                putStrLn $ "AckTracker Map (pre-insert): " ++ show ackMaps
                atomically $ do
                    ackMap <- readTVar ackTrackerVar
                    let ackMap' = Map.insert mid (msgClean, ackMaps, proxyAddr) ackMap
                    writeTVar ackTrackerVar ackMap'
                putStrLn $ "Inserted into AckTracker: " ++ show mid
                forM_ addressPairs $ \addr -> do
                    _ <- sendTo udpSock msgToSend addr
                    putStrLn $ "Sent UDP message to proxy address: " ++ show addr ++ ": " ++ BS.unpack msgToSend
            fifoReceive cid roomID seqNum msgClean clientsVar roomsVar r_fifoVar holdbackQueueVar

-- | Handles the reception of a message from a client; stores  message in  holdback queue and triggers delivery if possible
fifoReceive :: ClientID -> RoomID -> SequenceNumber -> Message -> Clients -> Rooms -> RFifo -> HoldbackQueue -> IO ()
fifoReceive cid roomID seqNum msg clientsVar roomsVar r_fifoVar holdbackQueueVar = do
    atomically $ do
        holdbackQueue <- readTVar holdbackQueueVar
        let hbqClient = Map.findWithDefault Map.empty cid holdbackQueue
        let hbqRoom = Map.findWithDefault Map.empty roomID hbqClient
        let hbqRoom' = Map.insert seqNum msg hbqRoom
        let hbqClient' = Map.insert roomID hbqRoom' hbqClient
        writeTVar holdbackQueueVar (Map.insert cid hbqClient' holdbackQueue)
    deliverFIFO roomID clientsVar roomsVar r_fifoVar holdbackQueueVar

-- | Check the holdback queue and update the receive state for each client in the room
deliverFIFO :: RoomID -> Clients -> Rooms -> RFifo -> HoldbackQueue -> IO ()
deliverFIFO roomID clientsVar roomsVar r_fifoVar holdbackQueueVar = do
    rooms <- readTVarIO roomsVar
    let clientsInRoom = Map.findWithDefault [] roomID rooms
    messagesToDeliver <- atomically $ do
        r_fifo <- readTVar r_fifoVar
        holdbackQueue <- readTVar holdbackQueueVar
        let senders = Map.keys holdbackQueue
        deliverMessages senders r_fifo holdbackQueue []

    -- Perform the IO actions outside the atomically block
    forM_ messagesToDeliver $ \(senderID, msg) -> forM_ clientsInRoom $ \client -> do
        sendTextData (clientConn client) $ T.pack $ "\"<" ++ senderID ++ "> " ++ msg ++ "\""

    -- If messages were delivered, attempt to deliver more
    unless (null messagesToDeliver) $ deliverFIFO roomID clientsVar roomsVar r_fifoVar holdbackQueueVar
  where
    deliverMessages :: [ClientID]
                    -> Map.Map ClientID (Map.Map RoomID SequenceNumber)
                    -> Map.Map ClientID (Map.Map RoomID (Map.Map SequenceNumber Message))
                    -> [(ClientID, Message)] -> STM [(ClientID, Message)]
    deliverMessages [] _ _ acc = return acc
    deliverMessages (senderID:rest) r_fifo holdbackQueue acc = do
        let rCount = Map.findWithDefault Map.empty senderID r_fifo
        let nextR = Map.findWithDefault 0 roomID rCount + 1
        let hbqClient = Map.findWithDefault Map.empty senderID holdbackQueue
        let hbqRoom = Map.findWithDefault Map.empty roomID hbqClient
        case Map.lookup nextR hbqRoom of
            Just msg -> do
                let rCount' = Map.insert roomID nextR rCount
                let r_fifo' = Map.insert senderID rCount' r_fifo
                writeTVar r_fifoVar r_fifo'
                let hbqRoom' = Map.delete nextR hbqRoom
                let hbqClient' = Map.insert roomID hbqRoom' hbqClient
                let holdbackQueue' = Map.insert senderID hbqClient' holdbackQueue
                writeTVar holdbackQueueVar holdbackQueue'
                deliverMessages (senderID:rest) r_fifo' holdbackQueue' ((senderID, msg):acc)
            Nothing -> deliverMessages rest r_fifo holdbackQueue acc

---------------------------------------
-- ACK Handling
---------------------------------------
-- Function to process ACK messages (only called if entry found in ackTracker)
processAck :: RoomID -> ClientID -> SequenceNumber -> SockAddr -> AckTracker -> IO ()
processAck roomID senderID seqNum senderAddr ackTrackerVar = do
    let mid = (roomID, senderID, seqNum)
    putStrLn $ "Processing ACK for MessageID: " ++ show mid
    logMsg <- atomically $ do
        ackMap <- readTVar ackTrackerVar
        case Map.lookup mid ackMap of
            Just (originalMsg, serverMap, originalProxy) -> do
                let updatedServerMap = Map.adjust (const True) senderAddr serverMap
                let updatedAckTracker = Map.insert mid (originalMsg, updatedServerMap, originalProxy) ackMap
                writeTVar ackTrackerVar updatedAckTracker
                return $ Just $ "Marked ACK from " ++ show senderAddr ++ " for MessageID " ++ show mid ++ ". Original proxy: " ++ show originalProxy
            Nothing -> return Nothing
    case logMsg of
        Just m -> putStrLn m
        Nothing -> return ()

---------------------------------------
-- Retransmission Handling
---------------------------------------
-- | Periodically checks for unacknowledged messages and retransmits them
startRetransmissionThread :: Socket -> AckTracker -> IO ()
startRetransmissionThread udpSock ackTrackerVar = void $ forkIO $ forever $ do
    threadDelay 2000000 -- 2 seconds
    toResend <- atomically $ do
        ackMap <- readTVar ackTrackerVar
        let (resendList, ackMap') = checkForResend ackMap
        writeTVar ackTrackerVar ackMap'
        return resendList
    forM_ toResend $ \(mid, addrs, originalMsg, originalProxy) -> do
        putStrLn $ "Retransmitting " ++ show mid ++ " to " ++ show addrs
        let (roomID, cid, seqNum) = mid
        let originPort = maybe "UnknownPort" show (extractPort originalProxy)
        let msgToSend = BS.pack $ intercalate "|" [show roomID, cid, show seqNum, originPort, originPort, originalMsg]
        forM_ addrs $ \addr -> do
            _ <- sendTo udpSock msgToSend addr
            putStrLn $ "Retransmitted UDP message to proxy address: " ++ show addr ++ ": " ++ BS.unpack msgToSend

-- | Identifies messages that need retransmission due to missing acknowledgments
checkForResend :: Map.Map MessageID (Message, Map.Map ServerAddress Bool, ServerAddress)
               -> ([(MessageID, [ServerAddress], Message, ServerAddress)], Map.Map MessageID (Message, Map.Map ServerAddress Bool, ServerAddress))
checkForResend ackMap =
    let fullyAcked = Map.filter (\(_, m, _) -> and (Map.elems m)) ackMap
        ackMap' = ackMap `Map.difference` fullyAcked
        toRetransmit = Map.filter (\(_, m, _) -> any not (Map.elems m)) ackMap'
        resendList = [ (mid, Map.keys (Map.filter not m), origMsg, originalProxy)
                     | (mid, (origMsg, m, originalProxy)) <- Map.toList toRetransmit
                     ]
    in (resendList, ackMap')


---------------------------------------
-- UDP Listener
---------------------------------------
-- Function to listen for incoming UDP messages
udpListener :: Socket -> Clients -> Rooms -> RFifo -> HoldbackQueue -> AckTracker -> ServerAddress -> IO ()
udpListener udpSock clientsVar roomsVar r_fifoVar holdbackQueueVar ackTrackerVar proxyAddr = forever $ do
    (msg, addr) <- recvFrom udpSock 65535
    let rawMsg = BS.unpack msg
    putStrLn $ "Received UDP message from " ++ show addr ++ ": " ++ rawMsg
    let parts = BS.split '|' msg
    if length parts >=5 then do
        let roomIDStr = BS.unpack (head parts)
        let senderID  = BS.unpack (parts !! 1)
        let seqNumStr = BS.unpack (parts !! 2)
        let originPort = BS.unpack (parts !! 3)
        let senderPort = BS.unpack (parts !! 4)
        let originAddrStr = "127.0.0.1:" ++ originPort
        let senderAddrStr = "127.0.0.1:" ++ senderPort
        let payload = BS.unpack (BS.intercalate "|" (drop 5 parts))
        let payloadClean = normalizeMessage payload
        case (readMaybe roomIDStr :: Maybe Int, readMaybe seqNumStr :: Maybe Int) of
            (Just roomID, Just seqNum) -> do
                let originAddr = parseSockAddr originAddrStr
                let senderAddr = parseSockAddr senderAddrStr
                if isAck payloadClean
                    then do
                        -- Process ACK
                        processAck roomID senderID seqNum senderAddr ackTrackerVar
                    else do
                        -- Process normal message
                        processMessageFromUDP roomID senderID seqNum payload clientsVar roomsVar r_fifoVar holdbackQueueVar udpSock originAddr proxyAddr
            _ -> putStrLn $ "Error parsing roomID, seqNum, or originAddr from message: " ++ rawMsg
    else
        putStrLn $ "Invalid message format: " ++ rawMsg
  where
    isAck :: String -> Bool
    isAck = isPrefixOf "ACK"

-- Function to process normal (non-ACK) messages received via UDP
processMessageFromUDP :: RoomID -> ClientID -> SequenceNumber -> String -> Clients -> Rooms -> RFifo -> HoldbackQueue -> Socket -> SockAddr -> ServerAddress -> IO ()
processMessageFromUDP roomID cID seqNum payloadClean clientsVar roomsVar r_fifoVar holdbackQueueVar udpSock originAddr proxyAddr = do
    putStrLn $ "Processing normal message from " ++ cID ++ " in room " ++ show roomID
    atomically $ do
        holdbackQueue <- readTVar holdbackQueueVar
        let hbqClient = Map.findWithDefault Map.empty cID holdbackQueue
        let hbqRoom = Map.findWithDefault Map.empty roomID hbqClient
        let hbqRoom' = Map.insert seqNum payloadClean hbqRoom
        let hbqClient' = Map.insert roomID hbqRoom' hbqClient
        writeTVar holdbackQueueVar (Map.insert cID hbqClient' holdbackQueue)
    deliverFIFO roomID clientsVar roomsVar r_fifoVar holdbackQueueVar
    let originPort = maybe "UnknownPort" (\port -> show (fromIntegral port :: Integer)) (extractPort originAddr)
    let senderPort = maybe "UnknownPort" (\port -> show (fromIntegral port :: Integer)) (extractPort proxyAddr)
    let ackMsg = BS.pack $ intercalate "|" [show roomID, cID, show seqNum, originPort, senderPort, "ACK"]
    _ <- sendTo udpSock ackMsg originAddr
    putStrLn $ "Sent ACK to " ++ show originAddr ++ " for MessageID: (" ++ show roomID ++ ", " ++ cID ++ ", " ++ show seqNum ++ ")"