module Main (main) where

import LoadBalancer
import Network.Wai.Handler.Warp (run)
import System.Environment (getArgs)
import System.IO (readFile)
import Control.Concurrent.STM
import qualified Data.Map.Strict as Map

main :: IO ()
main = do
    args <- getArgs
    if length args /= 1
        then error "Usage: loadbalancer <file-path>"
        else do
            let filePath = head args
            fileContent <- readFile filePath
            let servers = parseServers fileContent
            if null servers
                then error "No valid servers found in the file"
                else do
                    serverLoad <- atomically $ newTVar (Map.fromList [(s, 0) | s <- servers])
                    putStrLn "Load Balancer started on port 8080"
                    run 8080 $ corsMiddleware (app serverLoad)
