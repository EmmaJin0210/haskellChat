{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Data.ByteString.Char8 as BS
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Monad (forever, when, void, forM_)
import Data.Int (Int64)
import Data.Word (Word8)
import Data.Maybe (fromJust)
import Data.List (elemIndex)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendTo)
import System.Environment (getArgs)
import System.Random (randomRIO)

-- Config constants
type ServerId = Int
type Microseconds = Int

data Server = Server
    { proxySocket    :: Socket
    , proxyAddress   :: SockAddr
    , serverBindAddr :: SockAddr
    }

instance Eq Server where
    s1 == s2 = serverBindAddr s1 == serverBindAddr s2

data QueuedMessage = QueuedMessage
    { srcServerId :: ServerId
    , dstServerId :: ServerId
    , xmitTime    :: Int64
    , message     :: BS.ByteString
    }

type HoldbackQueue = MVar [QueuedMessage]

maxQueueLen :: Int
maxQueueLen = 1000

main :: IO ()
main = do
    args <- getArgs
    when (length args < 1) $ error "Usage: proxy <serverListFile> [-d maxDelayMicroseconds] [-l lossProbability]"
    
    let serverListFile = head args
    let maxDelay = readOption (tail args) "-d" 5000
    let lossProbability = readOption (tail args) "-l" 0.0

    -- Load servers from file
    serverConfigs <- loadServerConfigs serverListFile
    servers <- mapM openServerSocket serverConfigs

    -- Create a shared holdback queue
    holdbackQueue <- newMVar []

    -- Start the main loop
    putStrLn "Proxy is running..."
    mapM_ (startServerListener holdbackQueue servers (round maxDelay) lossProbability) servers
    holdbackQueueProcessor holdbackQueue servers (round maxDelay)

-- Parse optional args with default values
readOption :: [String] -> String -> Double -> Double
readOption args opt defaultValue =
    case lookup opt (pairs args) of
        Just v  -> read v
        Nothing -> defaultValue
  where
    pairs (x:y:xs) = (x, y) : pairs xs
    pairs _        = []

-- Load server configs
loadServerConfigs :: FilePath -> IO [(SockAddr, SockAddr)]
loadServerConfigs path = do
    contents <- lines <$> readFile path
    return $ map parseServerLine contents
  where
    parseServerLine line =
        case splitOn ',' line of
            [pAddr, sAddr] -> (parseSockAddr pAddr, parseSockAddr sAddr)
            _              -> error $ "Invalid server list line: " ++ line

    splitOn :: Char -> String -> [String]
    splitOn c s = case break (== c) s of
        (a, _ : b) -> a : splitOn c b
        (a, _)     -> [a]

    parseSockAddr :: String -> SockAddr
    parseSockAddr addr =
        case splitOn ':' addr of
            [host, port] -> SockAddrInet (fromIntegral (read port :: Int)) (tupleToHostAddress $ toTuple host)
            _            -> error $ "Invalid address: " ++ addr

    toTuple :: String -> (Word8, Word8, Word8, Word8)
    toTuple s =
        case map (fromIntegral . (read :: String -> Int)) (splitOn '.' s) of
            [a, b, c, d] -> (a, b, c, d)
            _            -> error $ "Invalid IP address: " ++ s

-- Open a UDP socket for the server
openServerSocket :: (SockAddr, SockAddr) -> IO Server
openServerSocket (pAddr, sAddr) = do
    sock <- socket AF_INET Datagram defaultProtocol
    bind sock pAddr
    return $ Server sock pAddr sAddr

-- Start a listener for a server
startServerListener :: HoldbackQueue -> [Server] -> Microseconds -> Double -> Server -> IO ()
startServerListener queue servers maxDelay lossProbability server = void $ forkIO $
    forever $ do
        (msg, senderAddr) <- recvFrom (proxySocket server) 65535
        putStrLn $ "Proxy received: " ++ BS.unpack msg ++ " from " ++ show senderAddr

        let sourceServerId = findServerByBindAddr servers senderAddr
        let destinationServerId = findServerByProxyAddr servers (proxyAddress server)

        -- Debug prints
        putStrLn $ "SenderAddr: " ++ show senderAddr
        putStrLn $ "Server Addresses: " ++ show (map (\s -> (proxyAddress s, serverBindAddr s)) servers)
        putStrLn $ "Resolved sourceServerId: " ++ show sourceServerId
        putStrLn $ "Resolved destinationServerId: " ++ show destinationServerId
        when (sourceServerId /= -1 && destinationServerId /= -1) $ do
            lost <- shouldDropPacket lossProbability
            if lost
                then putStrLn $ "Dropping packet: " ++ BS.unpack msg
                else do
                    delay <- randomRIO (0, maxDelay)
                    putStrLn $ "Inserting delay of " ++ show delay ++ " microseconds for message: " ++ BS.unpack msg
                    now <- getCurrentTimeMicros
                    modifyMVar_ queue $ \q -> do
                        if length q >= maxQueueLen
                            then error "Queue overflow!"
                            else return $ q ++ [QueuedMessage sourceServerId destinationServerId (now + fromIntegral delay) msg]


-- Process the holdback queue and deliver messages
holdbackQueueProcessor :: HoldbackQueue -> [Server] -> Microseconds -> IO ()
holdbackQueueProcessor queue servers _ = forever $ do
    now <- getCurrentTimeMicros
    toDeliver <- modifyMVar queue $ \q ->
        let (ready, notReady) = span (\m -> xmitTime m <= now) q
        in return (notReady, ready)

    forM_ toDeliver $ \msg -> do
        let dstSock = proxySocket (servers !! dstServerId msg)
        _ <- sendTo dstSock (message msg) (serverBindAddr (servers !! dstServerId msg))
        putStrLn $ "Proxy forwarding: " ++ BS.unpack (message msg)
            ++ " to server at " ++ show (serverBindAddr (servers !! dstServerId msg))
        putStrLn $ "Delivered message: " ++ BS.unpack (message msg)

    threadDelay 1000

-- | Finds the server by its bind address. Returns the server's ID or -1 if not found
findServerByBindAddr :: [Server] -> SockAddr -> ServerId
findServerByBindAddr servers addr =
    case filter (\s -> serverBindAddr s == addr) servers of
        (s:_) -> fromJust $ elemIndex s servers
        []    -> -1

-- | Finds the server by its proxy address. Returns the server's ID or -1 if not found
findServerByProxyAddr :: [Server] -> SockAddr -> ServerId
findServerByProxyAddr servers addr =
    case filter (\s -> proxyAddress s == addr) servers of
        (s:_) -> fromJust $ elemIndex s servers
        []    -> -1

-- Check if a packet should be dropped
shouldDropPacket :: Double -> IO Bool
shouldDropPacket lossProbability = do
    r <- randomRIO (0, 1 :: Double)
    return (r < lossProbability)

-- | Gets the current time in microseconds since the Unix epoch
getCurrentTimeMicros :: IO Int64
getCurrentTimeMicros = do
  t <- getPOSIXTime
  return (floor (t * 1000000))
