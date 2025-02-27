{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.QuickCheck
import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import LoadBalancer (assignServer, decrementServerLoad, logServerLoad)

type Server = Text
type Load = Int
type ServerLoad = TVar (Map.Map Server Load)

-- Property 1: Assigning a server always picks one with the lowest load
prop_assignLowestLoad :: Property
prop_assignLowestLoad = property $ \servers ->
    not (null servers) && all (not . null) servers ==> ioProperty $ do
        let serverList = map T.pack servers
        serverLoad <- atomically $ newTVar (Map.fromList [(s, 0) | s <- serverList])
        server <- assignServer serverLoad
        loads <- atomically $ readTVar serverLoad
        -- Ensure the selected server exists and its load has incremented
        pure (Map.lookup server loads == Just 1)

-- Property 2: Decreasing load never results in negative values
prop_noNegativeLoad :: Property
prop_noNegativeLoad = property $ \servers ->
    not (null servers) ==> ioProperty $ do
        let serverList = map T.pack servers
        serverLoad <- atomically $ newTVar (Map.fromList [(s, 1) | s <- serverList])
        _ <- decrementServerLoad serverLoad (head serverList)
        loads <- atomically $ readTVar serverLoad
        pure (all (>= 0) (Map.elems loads))

-- Property 3: Decrementing non-existing server does not alter state
prop_decrementInvalidServer :: Property
prop_decrementInvalidServer = property $ \servers ->
    not (null servers) ==> ioProperty $ do
        let serverList = map T.pack servers
        serverLoad <- atomically $ newTVar (Map.fromList [(s, 1) | s <- serverList])
        result <- decrementServerLoad serverLoad "invalid-server"
        loadsAfter <- atomically $ readTVar serverLoad
        let loadsBefore = Map.fromList [(s, 1) | s <- serverList]
        pure (loadsBefore == loadsAfter && result == Nothing)

main :: IO ()
main = do
    quickCheck prop_assignLowestLoad
    quickCheck prop_noNegativeLoad
    quickCheck prop_decrementInvalidServer
