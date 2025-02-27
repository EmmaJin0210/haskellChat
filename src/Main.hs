{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.Map.Strict as Map
import Network.Socket
import Network.WebSockets (runServer)
import System.Environment (getArgs)
import Control.Monad (when, forever, forM_)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (newTVarIO, readTVarIO)
import ChatServer (AckTracker, udpListener, startRetransmissionThread, serverApp, loadServerConfigsWithProxy)
import Utils (extractPort)


main :: IO ()
main = do
    args <- getArgs
    when (length args < 3) $ do
        putStrLn "Usage: chatserver <port> <useProxy: true|false> <serverListFile>"
        error "Not enough arguments."

    let portStr = head args
    let port = read portStr :: Int
    let useProxy = read (args !! 1) :: Bool
    let serverListFile = args !! 2

    putStrLn $ "Use Proxy: " ++ show useProxy

    serverPairs <- loadServerConfigsWithProxy serverListFile
    putStrLn $ "Server Pairs: " ++ show serverPairs

    -- Extract stable addresses (proxyAddr and bindAddr mappings)
    let addressPairs = if useProxy
                       then serverPairs
                       else map (\(_, sAddr) -> (sAddr, sAddr)) serverPairs

    let otherServerAddrs = map fst addressPairs

    putStrLn $ "Address Pairs: " ++ show addressPairs

    let currentServer = filter (\(_, bindAddr) -> extractPort bindAddr == Just (fromIntegral port)) addressPairs

    putStrLn $ "Current Server (filtered): " ++ show currentServer

    case currentServer of
        [(proxyAddr, bindAddr)] -> do
            putStrLn $ "Chat server listening on port " ++ portStr
            putStrLn $ "Proxy Addr: " ++ show proxyAddr
            putStrLn $ "Bind Addr: " ++ show bindAddr

            clientsVar <- newTVarIO Map.empty
            roomsVar <- newTVarIO Map.empty
            s_fifoVar <- newTVarIO Map.empty
            r_fifoVar <- newTVarIO Map.empty
            holdbackQueueVar <- newTVarIO Map.empty
            ackTrackerVar <- newTVarIO Map.empty

            let anyHostAddress = tupleToHostAddress (0, 0, 0, 0)
            udpSock <- socket AF_INET Datagram defaultProtocol
            bind udpSock (SockAddrInet (fromIntegral port) anyHostAddress)

            -- Start AckTracker state logging
            _ <- forkIO $ printAckTracker ackTrackerVar

            -- Start UDP listener
            _ <- forkIO $ udpListener udpSock clientsVar roomsVar r_fifoVar holdbackQueueVar ackTrackerVar proxyAddr

            -- Start retransmission thread
            _ <- forkIO $ startRetransmissionThread udpSock ackTrackerVar

            let serverUrl = "127.0.0.1:" ++ portStr
            -- Start WebSocket server
            runServer "0.0.0.0" port $ serverApp clientsVar roomsVar s_fifoVar r_fifoVar holdbackQueueVar udpSock otherServerAddrs proxyAddr ackTrackerVar serverUrl
        _ -> error $ "No matching server found for port " ++ portStr



-- Print the current state of AckTracker
printAckTracker :: AckTracker -> IO ()
printAckTracker ackTrackerVar = forever $ do
    ackMap <- readTVarIO ackTrackerVar
    putStrLn "Current AckTracker: "
    forM_ (Map.toList ackMap) $ \(mid, (msg, serverMap, originalProxy)) -> do
        putStrLn $ "  MessageID: " ++ show mid ++
                   ", Message: " ++ msg ++
                   ", AckMap: " ++ show serverMap ++
                   ", Original Proxy: " ++ show originalProxy
    threadDelay 5000000 -- 5 seconds