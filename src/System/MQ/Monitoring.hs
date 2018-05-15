{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module System.MQ.Monitoring
  ( monitoringAction
  , monitoringColl
  ) where

import           Control.Concurrent           (forkIO)
import           Control.Monad                (when)
import           Control.Monad.Except         (catchError, liftIO)
import           Data.String                  (fromString)
import           Data.Text                    (Text)
import           Database.MongoDB             (insert_)
import           Database.MongoDB.WrapperNew  (MongoPool, encode, loadMongoPool,
                                               withMongoPool)
import           System.MQ.Component          (Env (..), TwoChannels (..),
                                               loadTechChannels, runTech)
import           System.MQ.Monad              (MQMonad, errorHandler,
                                               foreverSafe, runMQMonad)
import           System.MQ.Protocol           (Condition (..), Message (..),
                                               MessageLike (..), MessageTag,
                                               Props (..), matches, messageSpec,
                                               messageType)
import           System.MQ.Protocol.Technical (MonitoringData)
import           System.MQ.Transport          (sub)

-- | Name of collection where monitoring data is stored
--
monitoringColl :: Text
monitoringColl = "monitoring"

-- | Action for techincal level that performs monitoring of Monique
--
monitoringAction :: Env -> MQMonad ()
monitoringAction env@Env{..} = do
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
      (tag, Message{..}) <- sub fromScheduler

      when (filterTag tag) $ do
        mData <- unpackM msgData
        storeDataInDB pool mData

  where
    Props{..} = props :: Props MonitoringData

    filterTag :: MessageTag -> Bool
    filterTag = (`matches` (messageType :== mtype :&& messageSpec :== fromString spec))

storeDataInDB :: MongoPool -> MonitoringData -> MQMonad ()
storeDataInDB pool = liftIO . withMongoPool pool . insert_ monitoringColl . encode

