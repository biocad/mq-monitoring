{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module System.MQ.Monitoring.Internal.Types
  ( ErrorDBUnit (..)
  , MoniUserData (..)
  , toUser
  ) where

import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               genericParseJSON, genericToJSON,
                                               object, (.=))
import           Data.Aeson.Casing            (aesonPrefix, snakeCase)
import           GHC.Generics                 (Generic)
import           System.MQ.Protocol           (Creator, Timestamp)
import           System.MQ.Protocol.Technical (MonitoringData (..))

-- | Format in which data is returned to user
--
data MoniUserData = MoniUserData { muSyncTime :: Timestamp
                                 , muName     :: String
                                 , muIsAlive  :: Bool
                                 , muMessage  :: String
                                 }
 deriving (Eq, Show, Generic)

instance ToJSON MoniUserData where
  toJSON MoniUserData{..} = object $ [ "sync_time" .= muSyncTime
                                     , "name" .= muName
                                     , "is_alive" .= muIsAlive
                                     ] ++ if null muMessage then [] else [ "message" .= muMessage ]

instance FromJSON MoniUserData where
  parseJSON = genericParseJSON $ aesonPrefix snakeCase

toUser :: MonitoringData -> MoniUserData
toUser MonitoringData{..} = MoniUserData mSyncTime mName mIsAlive mMessage

-- | Format in which 'MQError's are stored in DB
--
data ErrorDBUnit = ErrorDBUnit { erCode     :: Int
                               , erMessage  :: String
                               , erSyncTime :: Timestamp
                               , erName     :: Creator
                               } deriving (Eq, Show, Generic)

instance ToJSON ErrorDBUnit where
  toJSON = genericToJSON $ aesonPrefix snakeCase

instance FromJSON ErrorDBUnit where
  parseJSON = genericParseJSON $ aesonPrefix snakeCase
