{-# LANGUAGE OverloadedStrings #-}
module Utils (
    ServerAddress,
    trim,
    normalizeMessage,
    splitOn,
    parseSockAddr,
    toTuple,
    extractPort,
    findStableAddrByIP,
    selectAddr
) where

import Data.Char (isSpace)
import Data.Word (Word8)

import Network.Socket (SockAddr(..), PortNumber, tupleToHostAddress)

type ServerAddress = SockAddr

-- | Selects proxy or stable server addresses based on a Boolean flag
selectAddr :: Bool -> [(ServerAddress, ServerAddress)] -> [ServerAddress]
selectAddr useProxy serverAddrs =
    if useProxy then map fst serverAddrs else map snd serverAddrs

-- | Removes leading and trailing whitespace from a string
trim :: String -> String
trim = f . f
   where f = reverse . dropWhile isSpace

-- | Normalize payload for comparison and remove trailing newline (without changing case)
normalizeMessage :: String -> String
normalizeMessage = trim

-- | Checks if an incoming address exists in a list of known addresses and returns it if found
findStableAddrByIP :: [ServerAddress] -> ServerAddress -> Maybe ServerAddress
findStableAddrByIP knownAddrs incomingAddr =
    if incomingAddr `elem` knownAddrs
        then Just incomingAddr
        else Nothing

-- | Extract port from SockAddr
extractPort :: ServerAddress -> Maybe PortNumber
extractPort (SockAddrInet port _) = Just port
extractPort (SockAddrInet6 port _ _ _) = Just port
extractPort _ = Nothing

-- | Splits a string into parts based on a specified delimiter
splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
    (a, _ : b) -> a : splitOn c b
    (a, _)     -> [a]

-- | Parses a string into a SockAddr, format <host>:<port>
parseSockAddr :: String -> ServerAddress
parseSockAddr addr =
    let (host, port) = break (== ':') addr
    in SockAddrInet (fromIntegral (read (tail port) :: Int)) (tupleToHostAddress $ toTuple host)

-- | Converts dotted IP address string into a tuple of four Word8 values
toTuple :: String -> (Word8, Word8, Word8, Word8)
toTuple s =
    case map (fromIntegral . (read :: String -> Int)) (splitOn '.' s) of
        [a, b, c, d] -> (a, b, c, d)
        _            -> error $ "Invalid IP address format: " ++ s