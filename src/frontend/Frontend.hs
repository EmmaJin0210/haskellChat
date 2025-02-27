-- Disclaminer: This file is adapted from the official example from Miso framework: https://github.com/dmjio/miso/blob/master/examples/websocket/Main.hs
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ExtendedDefaultRules       #-}
{-# LANGUAGE CPP                        #-}

module Main where

import qualified Miso.String as S
import qualified Data.Map as M
import           Control.Lens ((^.))
import           Data.Aeson
import           Data.Bool (bool)
import           GHC.Generics
import           Miso
import           Miso.String (MisoString)

#ifdef IOS
import           Language.Javascript.JSaddle.WKWebView as JSaddle
runApp :: JSM () -> IO ()
runApp = JSaddle.run
#else
import           Language.Javascript.JSaddle.Warp as JSaddle
import           Language.Javascript.JSaddle (JSM, jsg, js, call, fromJSVal, fun, JSVal, toJSVal, jsNull)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import           Control.Monad.IO.Class (liftIO)

runApp :: JSM () -> IO ()
runApp = JSaddle.run 8081
#endif

main :: IO ()
main = runApp $ do
    hostPort <- fetchHostPort "http://localhost:8080"
    let wsUri = URL $ "ws://" <> hostPort
    startApp App
        { initialAction = Id
        , model = Model 
            { inRoom = False
            , currentRoom = Nothing
            , msg = Message "1"  -- Default room number
            , received = []
            }
        , events = defaultEvents
        , subs = [websocketSub wsUri (Protocols []) HandleWebSocket]
        , update = updateModel
        , view = appView
        , mountPoint = Nothing
        , logLevel = Off
        }

-- Model and Actions
data Model = Model
    { inRoom     :: Bool
    , currentRoom :: Maybe MisoString
    , msg        :: Message
    , received   :: [MisoString]
    } deriving (Show, Eq)

data Action
    = HandleWebSocket (WebSocket Message)
    | SendMessage Message
    | UpdateMessage MisoString
    | Id

-- | Updates the model based on the given action
updateModel :: Action -> Model -> Effect Action Model
updateModel (HandleWebSocket (WebSocketMessage (Message m))) model
    -- Check if we just joined successfully:
    | "+OK" `S.isPrefixOf` m =
        noEff model { inRoom = True }  -- Transition to "in room" state
    | otherwise = noEff model { received = received model ++ [m] }

updateModel (SendMessage (Message m)) model
    | inRoom model = 
        -- In room, send the typed message directly and clear the input
        model { msg = Message "" } <# do
            send (Message m)
            pure Id
    | otherwise = 
        -- Not in room, treat the input as a room number and join
        let roomNumber = m  -- Use the message directly as the room number
            joinCmd = "/join " <> roomNumber
        in model { currentRoom = Just roomNumber, msg = Message "" } <# do
            send (Message joinCmd)
            pure Id

updateModel (UpdateMessage m) model = noEff model { msg = Message m }
updateModel _ model = noEff model

-- | Defines the application's view, rendering the UI based on the current model
appView :: Model -> View Action
appView Model{..} =
  div_
    [ style_ $ M.fromList 
        [ ("display", "flex")
        , ("flex-direction", "column")
        , ("align-items", "center")
        , ("justify-content", "center")
        , ("height", "100vh")
        , ("font-family", "Arial, sans-serif")
        , ("background-color", "#f4f4f9")
        , ("color", "#333")
        ] 
    ]
    ( if not inRoom
        then 
          -- Not in a room yet: show join UI
          [ h1_ [ style_ $ M.fromList [("color", "#0078d7")] ] [ text "HaskChat" ]
          , p_ [ style_ $ M.fromList [("margin-bottom", "20px")] ] [ text "Please join a room first." ]
          , div_
              [ style_ $ M.fromList [("display", "flex"), ("gap", "10px"), ("margin-bottom", "20px")] ]
              [ input_
                  [ type_ "text"
                  , value_ (case msg of Message txt -> txt)
                  , onInput UpdateMessage
                  , onEnter (SendMessage msg)
                  , style_ $ M.fromList
                      [ ("padding", "10px")
                      , ("flex-grow", "1")
                      , ("border", "1px solid #ccc")
                      , ("border-radius", "5px")
                      ]
                  ]
              , button_
                  [ onClick (SendMessage msg)
                  , style_ $ M.fromList
                      [ ("background-color", "#0078d7")
                      , ("color", "white")
                      , ("border", "none")
                      , ("padding", "10px 20px")
                      , ("border-radius", "5px")
                      , ("cursor", "pointer")
                      ]
                  ]
                  [ text "Join" ]
              ]
          , div_ [ style_ $ M.fromList [("margin-top", "20px")] ] 
              (map (\r -> p_ [ style_ $ M.fromList [("margin", "5px 0")] ] [text r]) received)
          ]
        else
          -- In a room: show normal chat UI with room number
          [ h1_ [ style_ $ M.fromList [("color", "#0078d7")] ] [ text "HaskChat" ]
          , p_ [ style_ $ M.fromList [("margin-bottom", "20px")] ] [ text $ "You are in room: " <> maybe "Unknown" id currentRoom ]
          , div_
              [ style_ $ M.fromList 
                  [ ("width", "100%")
                  , ("max-width", "400px")
                  , ("background-color", "white")
                  , ("border", "1px solid #ccc")
                  , ("border-radius", "5px")
                  , ("padding", "10px")
                  , ("overflow-y", "auto")
                  , ("height", "300px")
                  , ("margin-bottom", "10px")
                  ]
              ]
              (map (\r -> p_ [ style_ $ M.fromList [("margin", "5px 0"), ("padding", "5px"), ("background-color", "#f1f1f1"), ("border-radius", "5px")] ] [text r]) received)
          , div_
              [ style_ $ M.fromList [("display", "flex"), ("gap", "10px"), ("width", "100%"), ("max-width", "400px")] ]
              [ input_
                  [ type_ "text"
                  , value_ (case msg of Message txt -> txt)
                  , onInput UpdateMessage
                  , onEnter (SendMessage msg)
                  , style_ $ M.fromList
                      [ ("padding", "10px")
                      , ("flex-grow", "1")
                      , ("border", "1px solid #ccc")
                      , ("border-radius", "5px")
                      ]
                  ]
              , button_
                  [ onClick (SendMessage msg)
                  , style_ $ M.fromList
                      [ ("background-color", "#0078d7")
                      , ("color", "white")
                      , ("border", "none")
                      , ("padding", "10px 20px")
                      , ("border-radius", "5px")
                      , ("cursor", "pointer")
                      ]
                  ]
                  [ text "Send" ]
              ]
          ]
    )

-- | Handles the Enter key to trigger an action
onEnter :: Action -> Attribute Action
onEnter action = onKeyDown $ bool Id action . (== KeyCode 13)

-- Fetch the host:port string from the given URL using JavaScript fetch
fetchHostPort :: MisoString -> JSM MisoString
fetchHostPort url = do
    fetchFn <- jsg "fetch"                   
    urlVal <- toJSVal url
    fetchPromise <- call fetchFn jsNull [urlVal]
    response <- waitForPromise fetchPromise

    let textFn = response ^. js "text"
    textPromise <- call textFn response ([] :: [JSVal])
    textVal <- waitForPromise textPromise

    Just result <- fromJSVal textVal
    pure (S.pack result)

-- Wait for a JS Promise to resolve
waitForPromise :: JSVal -> JSM JSVal
waitForPromise promise = do
    var <- liftIO newEmptyMVar
    let thenFn = promise ^. js "then"
    _ <- call thenFn promise [fun $ \_ _ [result] -> liftIO $ putMVar var result]
    liftIO $ takeMVar var

-- JSON serialization
newtype Message = Message MisoString deriving (Eq, Show, Generic)
instance ToJSON Message
instance FromJSON Message
