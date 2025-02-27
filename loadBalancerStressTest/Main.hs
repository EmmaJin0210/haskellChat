{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Network.HTTP.Client
import Network.HTTP.Types.Status (statusCode)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Lazy.Char8 as BL

-- | Function to perform GET request for server assignment
makeGetRequest :: Manager -> String -> IO (Text, Int)
makeGetRequest manager url = do
    request <- parseRequest url
    response <- httpLbs request manager
    let body = responseBody response
        server = T.strip (T.pack $ BL.unpack body)
    return (server, statusCode (responseStatus response))

-- | Function to perform DELETE request to decrement server load
makeDeleteRequest :: Manager -> String -> Text -> IO Int
makeDeleteRequest manager url server = do
    request <- parseRequest (url ++ T.unpack server)
    let deleteRequest = request { method = "DELETE" }
    response <- httpLbs deleteRequest manager
    return (statusCode (responseStatus response))

-- | Function to fetch loads from /load endpoint
getLoadFromServer :: Manager -> String -> IO [Int]
getLoadFromServer manager url = do
    request <- parseRequest url
    response <- httpLbs request manager
    let body = responseBody response
        loads = read (BL.unpack body) :: [Int]
    return loads

-- | Stress test function
stressTest :: String -> IO ()
stressTest baseUrl = do
    manager <- newManager defaultManagerSettings
    let getUrl = baseUrl ++ "/"
    let deleteUrl = baseUrl ++ "/"
    let loadUrl = baseUrl ++ "/load"

    -- TVar to manage the number of active GET requests
    activeGets <- atomically $ newTVar Map.empty

    -- Concurrently send 100 GET requests
    putStrLn "Starting 100 GET requests..."
    getResults <- forConcurrently [1..100] $ \_ -> do
        (server, status) <- makeGetRequest manager getUrl
        atomically $ modifyTVar' activeGets (Map.insertWith (+) server 1)
        return (server, status)

    -- Concurrently send corresponding DELETE requests
    putStrLn "Starting 100 DELETE requests..."
    forConcurrently_ getResults $ \(server, _) -> do
        atomically $ do
            loads <- readTVar activeGets
            let currentLoad = Map.findWithDefault 0 server loads
            check (currentLoad > 0) -- Wait until a GET request has incremented this server's load
            modifyTVar' activeGets (Map.adjust (subtract 1) server)
        _ <- makeDeleteRequest manager deleteUrl server
        return ()

    -- Verify all server loads are zero using the /load endpoint
    putStrLn "Verifying all server loads are zero..."
    loads <- getLoadFromServer manager loadUrl
    if all (== 0) loads
        then putStrLn "All server loads are zero. Stress test passed!"
        else error $ "Test failed: Some server loads are not zero! " ++ show loads

main :: IO ()
main = do
    let baseUrl = "http://localhost:8080"
    stressTest baseUrl
