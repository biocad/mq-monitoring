{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module System.MQ.Monitoring
  ( ErrorDBUnit (..)
  , MoniUserData (..)
  , errorsColl
  , monitoringActionComm
  , monitoringActionTech
  , monitoringColl
  , toUser
  ) where

import           Control.Concurrent                  (forkIO)
import           Control.Monad                       (when)
import           Control.Monad.Except                (catchError, liftIO)
import           Data.Aeson                          (ToJSON)
import           Data.String                         (fromString)
import           Data.Text                           (Text)
import           Database.MongoDB                    (insert_)
import           Database.MongoDB.WrapperNew         (MongoPool, encode,
                                                      loadMongoPool,
                                                      withMongoPool)
import           System.MQ.Component                 (Env (..),
                                                      TwoChannels (..),
                                                      load2Channels,
                                                      loadTechChannels, runTech)
import           System.MQ.Error                     (MQError (..))
import           System.MQ.Monad                     (MQMonad, errorHandler,
                                                      foreverSafe, runMQMonad)
import           System.MQ.Monitoring.Internal.Types (ErrorDBUnit (..),
                                                      MoniUserData (..), toUser)
import           System.MQ.Protocol                  (Condition (..), Creator,
                                                      Message (..),
                                                      MessageLike (..),
                                                      MessageTag,
                                                      MessageType (..),
                                                      Props (..), matches,
                                                      messageCreator,
                                                      messageSpec, messageType)
import           System.MQ.Protocol.Technical        (MonitoringData)
import           System.MQ.Transport                 (sub)

-- | Name of collection where monitoring data is stored
--
monitoringColl :: Text
monitoringColl = "monitoring"

-- | Name of collection where error data is stored
--
errorsColl :: Text
errorsColl = "errors"

-- | Action for communication level that performs monitoring of Monique
--
monitoringActionComm :: Env -> MQMonad ()
monitoringActionComm Env{..} = do
    TwoChannels{..} <- load2Channels
    pool <- liftIO $ loadMongoPool "mq-monitoring"

    foreverSafe name $ do
      (tag, msg) <- sub fromScheduler

      when (filterTag tag) $ processErrorData pool (messageCreator tag) msg

  where
    Props{..} = props :: Props MQError

    filterTag :: MessageTag -> Bool
    filterTag = (`matches` (messageType :== mtype :&& messageSpec :== fromString spec))

    processErrorData :: MongoPool -> Creator -> Message -> MQMonad ()
    processErrorData pool mCreator Message{..} = do
        MQError{..} <- unpackM msgData
        storeDataInDB pool errorsColl $ ErrorDBUnit errorCode errorMessage msgCreatedAt mCreator

-- | Action for techincal level that performs monitoring of Monique
--
monitoringActionTech :: Env -> MQMonad ()
monitoringActionTech env@Env{..} = do
    _ <- liftIO $ forkIO $ catchMQ $ listenerTech env
    runTech env
  where
    catchMQ :: MQMonad () -> IO ()
    catchMQ = runMQMonad . (`catchError` errorHandler name)

listenerTech :: Env -> MQMonad ()
listenerTech Env{..} = do
    TwoChannels{..} <- loadTechChannels
    pool <- liftIO $ loadMongoPool "mq-monitoring"

    foreverSafe name $ do
      (tag, msg) <- sub fromScheduler

      when (filterTag tag) $ processMoniData pool msg

  where
    Props{..} = props :: Props MonitoringData

    filterTag :: MessageTag -> Bool
    filterTag = (`matches` ((messageType :== mtype :&& messageSpec :== fromString spec) :|| messageType :== Error))

    processMoniData :: MongoPool -> Message -> MQMonad ()
    processMoniData pool Message{..} = (unpackM msgData :: MQMonad MonitoringData) >>= storeDataInDB pool monitoringColl

storeDataInDB :: ToJSON a => MongoPool -> Text -> a -> MQMonad ()
storeDataInDB pool collName = liftIO . withMongoPool pool . insert_ collName . encode
