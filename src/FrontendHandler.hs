module FrontendHandler (
    Client(..),
    Clients,
    Rooms,
    RoomID,
    ClientID,
    joinRoom,
    makeClientID,
    cleanupClient,
    sendDeleteRequest,
    findClientRoom
) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Text.Read (readMaybe)
import Control.Concurrent.STM
import Network.WebSockets (Connection, PendingConnection, sendTextData)
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import System.Random (randomIO)
import Utils (trim)


type RoomID = Int
type ClientID = String

data Client = Client
    { clientConn :: Connection
    , clientID   :: ClientID
    }

instance Eq Client where
    c1 == c2 = clientID c1 == clientID c2

type Clients = TVar (Map.Map ClientID Client)
type Rooms = TVar (Map.Map RoomID [Client])

-- | Construct the client ID
makeClientID :: PendingConnection -> IO ClientID
makeClientID _ = do
    uniqueID <- randomIO :: IO Int
    return $ "client--" ++ show uniqueID

-- | Handles removing the client and notifying the load balancer
cleanupClient :: ClientID -> Clients -> Rooms -> String -> IO ()
cleanupClient cid clientsVar roomsVar serverUrl = do
    -- Atomically remove the client from the server's state
    atomically $ do
        -- Remove the client from the list of active clients
        modifyTVar' clientsVar (Map.delete cid)
        -- Remove the client from any rooms they are in
        rooms <- readTVar roomsVar
        let updatedRooms = Map.map (filter (\c -> clientID c /= cid)) rooms
        writeTVar roomsVar updatedRooms

    -- Log the client disconnection
    putStrLn $ "Client disconnected: " ++ cid

    -- Send DELETE request to the load balancer
    sendDeleteRequest serverUrl

-- | Function to send the DELETE request to the load balancer
sendDeleteRequest :: String -> IO ()
sendDeleteRequest serverUrl = do
    -- Create an HTTP manager
    manager <- newManager tlsManagerSettings

    -- Encode the server URL to be used in the path
    let encodedPath = TE.encodeUtf8 $ T.pack $ "/" ++ serverUrl

    -- Construct the DELETE request
    let request = defaultRequest
            { method = BS.pack "DELETE"
            , host = BS.pack "localhost"
            , port = 8080
            , path = encodedPath
            }

    -- Log full request details
    putStrLn $ "Sending DELETE request to: http://localhost:8080" ++ T.unpack (TE.decodeUtf8 encodedPath)

    -- Send the request
    response <- httpLbs request manager

    -- Log response for debugging
    putStrLn $ "Response status: " ++ show (responseStatus response)
    putStrLn $ "Response body: " ++ LBS.unpack (responseBody response)

-- | Find which room a client belongs to
findClientRoom :: ClientID -> Map.Map RoomID [Client] -> Maybe RoomID
findClientRoom cid rooms =
    let roomsList = Map.toList rooms
    in foldr (\(rid, clients) acc -> if any (\c -> clientID c == cid) clients then Just rid else acc) Nothing roomsList


-- | Join a client to a room
joinRoom :: Connection -> ClientID -> String -> Rooms -> IO ()
joinRoom conn cid msg roomsVar = do
    let roomIDStr = trim msg
    case readMaybe roomIDStr :: Maybe Int of
        Just roomID -> do
            atomically $ do
                rooms <- readTVar roomsVar
                let updatedRooms = Map.insertWith (++) roomID [Client { clientConn = conn, clientID = cid }] rooms
                writeTVar roomsVar updatedRooms
            sendTextData conn $ T.pack $ "\"+OK You joined room " ++ show roomID ++ "\""
            putStrLn $ cid ++ " joined room " ++ show roomID
        Nothing -> sendTextData conn $ T.pack "\"-ERR Invalid room number.\""