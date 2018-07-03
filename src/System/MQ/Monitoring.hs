{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module System.MQ.Monitoring
  ( MoniUserData (..)
  , monitoringActionComm
  , toUser
  ) where

import           Control.Concurrent                  (forkIO)
import           Control.Concurrent.MVar             (MVar, modifyMVar_,
                                                      newMVar, tryReadMVar)
import           Control.Monad                       (when)
import           Control.Monad.IO.Class              (liftIO)
import           Data.Aeson.Picker                   ((|-?))
import           Data.Map.Strict                     (Map)
import qualified Data.Map.Strict                     as M (elems, insert)
import           Data.Maybe                          (fromMaybe)
import           Data.String                         (fromString)
import           System.BCD.Config                   (getConfigText)
import           System.MQ.Component                 (Env (..),
                                                      TwoChannels (..),
                                                      loadTechChannels)
import           System.MQ.Monad                     (MQMonad, foreverSafe)
import           System.MQ.Monitoring.Internal.Types (MoniUserData (..), toUser)
import           System.MQ.Protocol                  (Condition (..),
                                                      Message (..),
                                                      MessageLike (..),
                                                      MessageTag, Props (..),
                                                      matches, messageSpec,
                                                      messageType)
import           System.MQ.Protocol.Technical        (MonitoringData)
import           System.MQ.Transport                 (sub)
import           Web.Scotty.Trans                    (get, json, params)
import           Web.Template                        (CustomWebServer (..),
                                                      Process (..), Route (..),
                                                      runWebServer)

-- | Alias for 'Map' from name of component to most recent montitoring
-- message from that component.
--
type MonitoringCache = Map String MoniUserData

-- | Action that listens to monitoring messages, stores them in cache and launches
-- its own server to process GET requests for these monitoring messages.
--
monitoringActionComm :: Env -> MQMonad ()
monitoringActionComm Env{..} = do
    TwoChannels{..} <- loadTechChannels
    cache <- liftIO $ newMVar mempty

    _ <- liftIO $ forkIO $ runServer cache

    foreverSafe name $ do
      (tag, msg) <- sub fromScheduler
      when (filterTag tag) $ processMoniData cache msg

  where
    Props{..} = props :: Props MonitoringData

    filterTag :: MessageTag -> Bool
    filterTag = (`matches` (messageType :== mtype :&& messageSpec :== fromString spec))

    processMoniData :: MVar MonitoringCache -> Message -> MQMonad ()
    processMoniData cache Message{..} = (unpackM msgData :: MQMonad MonitoringData) >>= storeDataInCache cache

storeDataInCache :: MVar MonitoringCache -> MonitoringData -> MQMonad ()
storeDataInCache cache = liftIO . modifyMVar_ cache . updateCache
  where
    updateCache :: MonitoringData -> MonitoringCache -> IO MonitoringCache
    updateCache (toUser -> muData@MoniUserData{..}) = return . M.insert muName muData

-- | Server that receives commands with flag 'last' and sends list of most recent
-- monitoring messages in response.
--
runServer :: MVar MonitoringCache -> IO ()
runServer cache = do
    port <- portIO
    runWebServer port monitoringServer

  where
    monitoringServer = CustomWebServer () [Route get 1 "/monitoring" $ runHandler cache]

    portIO :: IO Int
    portIO = do
        config <- getConfigText
        return $ fromMaybe 3000 $ config |-? ["params", "mq_monitoring_handler", "port"]

    runHandler :: MVar MonitoringCache -> Process ()
    runHandler cache = Process $ do
        params' <- params
        when ("last" `elem` fmap fst params') $ do
            messages <- liftIO $ maybe [] M.elems <$> tryReadMVar cache
            json messages




