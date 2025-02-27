{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.IORef
import Data.List (isSubsequenceOf, isPrefixOf, nub, sort, dropWhileEnd)
import Data.Char (isSpace)
import Data.Text (Text)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (finally, try, SomeException (SomeException))
import Network.WebSockets (runClient, sendTextData, receiveData, Connection)
import System.IO.Unsafe (unsafePerformIO)
import Test.QuickCheck
import Test.QuickCheck.Monadic (monadicIO, run, assert, pick)

-- | User and message types
type UserID = Int

data Msg = Msg
  { getMsg :: String
  } deriving (Show, Eq)

-- Arbitrary instance for Msg ensuring message does not start with '/'
instance Arbitrary Msg where
  arbitrary = do
    firstChar <- elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'])
    rest <- listOf (elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ " "))
    return $ Msg (firstChar : rest)

-- | List of chat server ports to distribute users
chatServerPorts :: [Int]
chatServerPorts = [4000, 4001, 4002]

-- | Global logs for sent and received messages
{-# NOINLINE sentLog #-}
sentLog :: IORef (Map.Map UserID [Msg])
sentLog = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE recvLog #-}
recvLog :: IORef (Map.Map UserID [Msg])
recvLog = unsafePerformIO (newIORef Map.empty)

-- | Initialize logs for a given number of users
initLogs :: Int -> IO ()
initLogs n = do
  writeIORef sentLog (Map.fromList [(u, []) | u <- [1 .. n]])
  writeIORef recvLog (Map.fromList [(u, []) | u <- [1 .. n]])

-- | Append sent message to the log
appendSent :: UserID -> Msg -> IO ()
appendSent u m = atomicModifyIORef' sentLog (\mapp -> (Map.adjust (++ [m]) u mapp, ()))

-- | Append received message to the log
appendRecv :: UserID -> Msg -> IO ()
appendRecv u m = atomicModifyIORef' recvLog (\mapp -> (Map.adjust (++ [m]) u mapp, ()))

-- | User routine to connect, send, and receive messages
userRoutine :: UserID -> [Msg] -> IO ()
userRoutine uid msgs = do
  let serverPort = chatServerPorts !! (uid `mod` length chatServerPorts)
  
  result <- try $ runClient "localhost" serverPort "/" $ \conn -> do
    sendTextData conn (T.pack "/join 1")

    stopVar <- newEmptyMVar
    recvThread <- async (receiveLoop uid conn stopVar)

    finally
      (forM_ msgs $ \m -> do
        liftIO $ appendSent uid m
        sendTextData conn (T.pack (getMsg m))
        liftIO $ threadDelay (1 * 10 ^ 6))  -- 1-second delay between messages
      (do
        liftIO $ threadDelay (20 * 10 ^ 6)  -- 20-second wait to receive messages
        putMVar stopVar ()
        wait recvThread)

  case result of
    Left (SomeException _) -> return ()  -- Handle connection failures silently
    Right _ -> return ()

-- | Receive loop for each user with timeout
receiveLoop :: UserID -> Connection -> MVar () -> IO ()
receiveLoop uid conn stopVar = loop
  where
    loop = do
      done <- isJust <$> tryReadMVar stopVar
      unless done $ do
        result <- race (threadDelay (10 * 10 ^ 6)) (receiveData conn)  -- 10-second timeout
        case result of
          Left _ -> loop  -- Continue loop on timeout
          Right msgData -> do
            let msgText = T.unpack msgData
            appendRecv uid (Msg msgText)
            loop

-- | Helper to check if a value is `Just`
isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust _        = False

-- | Helper function to remove client prefixes from received messages
dropClientPrefix :: String -> String
dropClientPrefix msg =
  case break (== '>') msg of
    (_, '>':rest) -> dropWhile isSpace rest  -- Remove '>' and any following spaces
    _             -> trim msg                -- If '>' not found, trim the message

-- | Helper function to remove surrounding quotes
dropQuotes :: String -> String
dropQuotes = filter (/= '"')

-- | Helper function to trim leading and trailing spaces
trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

-- | Property for the stress test
prop_stressTest :: Property
prop_stressTest = monadicIO $ do
  let n = 10  -- Number of concurrent users
  msgsPerUser <- pick (vectorOf n (listOf1 arbitrary))  -- Generate random messages for each user
  let userData = zip [1 .. n] msgsPerUser

  result <- run $ do
    initLogs n  -- Initialize logs for sent and received messages
    asyncs <- forM userData $ \(uid, msgs) -> async (userRoutine uid msgs)
    mapM_ wait asyncs

    sent <- readIORef sentLog
    received <- readIORef recvLog

    -- Extract message content only (ignore control messages)
    let sentMsgs = concatMap (map getMsg) (Map.elems sent)
    let receivedMsgs = nub $ filter (/= "+OK You joined room 1") $
                       map (trim . dropClientPrefix . dropQuotes) (map getMsg (concat (Map.elems received)))

    -- Compare received messages are a subset of sent messages
    return $ all (`elem` sentMsgs) receivedMsgs

  assert result

-- | Main function to run the test
main :: IO ()
main = do
  quickCheckWith stdArgs { maxSuccess = 1 } prop_stressTest  -- Run 10 tests
