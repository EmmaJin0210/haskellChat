{-# LANGUAGE OverloadedStrings #-}

module LoadBalancer
  ( Server
  , Load
  , ServerLoad
  , parseServers
  , assignServer
  , decrementServerLoad
  , logServerLoad
  , corsMiddleware
  , app
  ) where

import Data.List (minimumBy)
import Data.Ord (comparing)
import Network.Wai
import Network.Wai.Middleware.Cors (cors, simpleCorsResourcePolicy, CorsResourcePolicy(..))
import Network.HTTP.Types (status200, status400, status404)
import Control.Concurrent.STM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map

type Server = Text
type Load = Int
type ServerLoad = TVar (Map.Map Server Load)

-- | Parses a string of server configurations into a list of server addresses
parseServers :: String -> [Text]
parseServers content =
    map (T.pack . extractSecondAddress . splitLine) $ lines content
  where
    splitLine line = T.splitOn "," (T.pack line)
    extractSecondAddress parts = case parts of
        (_:second:_) -> T.unpack second
        _ -> error "Invalid file format"

-- | Configures CORS to allow all origins and GET DELETE methods 
corsMiddleware :: Middleware
corsMiddleware = cors $ const $ Just simpleCorsResourcePolicy
    { corsOrigins = Nothing
    , corsMethods = ["GET", "DELETE"]
    }

-- | HTTP server application
app :: ServerLoad -> Application
app serverLoad req respond = do
    case (requestMethod req, pathInfo req) of
        ("GET", []) -> do
            server <- assignServer serverLoad
            logServerLoad serverLoad
            let response = TE.encodeUtf8 server
            respond $ responseLBS status200 [("Content-Type", "text/plain")] (BL.fromStrict response)

        -- This endpoint is for stress testing purposes
        ("GET", ["load"]) -> do
            loads <- getServerLoads serverLoad
            let response = BL.fromStrict (TE.encodeUtf8 $ T.pack $ show loads)
            respond $ responseLBS status200 [("Content-Type", "application/json")] response

        ("DELETE", [server]) -> do
            let serverText = server
            putStrLn $ "DELETE request received for server: " ++ T.unpack serverText
            result <- decrementServerLoad serverLoad serverText
            logServerLoad serverLoad
            case result of
                Just _  -> respond $ responseLBS status200 [("Content-Type", "text/plain")] "Server load decremented"
                Nothing -> respond $ responseLBS status404 [("Content-Type", "text/plain")] "Server not found"

        _ -> respond $ responseLBS status400 [("Content-Type", "text/plain")] "Invalid request"

-- Helper functions

-- | Assigns a server with the lowest load and increments its load counter
assignServer :: ServerLoad -> IO Text
assignServer serverLoad = atomically $ do
    loads <- readTVar serverLoad
    let (server, _) = minimumBy (comparing snd) (Map.toList loads)
    modifyTVar' serverLoad (Map.adjust (+1) server)
    return server

-- | Decreases the load counter for a specified server, ensuring it doesn’t go below zero
decrementServerLoad :: ServerLoad -> Text -> IO (Maybe ())
decrementServerLoad serverLoad server = atomically $ do
    loads <- readTVar serverLoad
    if Map.member server loads
        then do
            modifyTVar' serverLoad (Map.adjust (\n -> max 0 (n - 1)) server)
            return (Just ())
        else return Nothing

-- | Logs the current load on each server to the console
logServerLoad :: ServerLoad -> IO ()
logServerLoad serverLoad = do
    loads <- readTVarIO serverLoad
    putStrLn "Current Server Load:"
    mapM_ (\(server, load) -> putStrLn $ T.unpack server ++ ": " ++ show load) (Map.toList loads)

-- | Retrieves the list of load values from the server load tracker
getServerLoads :: ServerLoad -> IO [Load]
getServerLoads serverLoad = atomically $ do
    loads <- readTVar serverLoad
    return (Map.elems loads)