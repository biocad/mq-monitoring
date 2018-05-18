{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad.IO.Class       (liftIO)
import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               genericParseJSON, object, (.=))
import           Data.Aeson.Casing            (aesonPrefix, snakeCase)
import           Data.Aeson.Picker            ((|-?))
import           Data.Bson                    (Document, (=:))
import           Data.Either                  (rights)
import           Data.Function                (on)
import           Data.List                    (groupBy, sortOn)
import qualified Data.Map.Strict              as M (fromList, keys, (!?))
import           Data.Maybe                   (fromMaybe)
import           Data.Text.Lazy               (Text, toStrict, unpack)
import           Database.MongoDB.WrapperNew  (MongoPool, decode, find,
                                               loadMongoPool, withMongoPool)
import           GHC.Generics                 (Generic)
import           System.BCD.Config            (getConfigText)
import           System.MQ.Monad              (runMQMonad)
import           System.MQ.Monitoring         (monitoringColl)
import           System.MQ.Protocol           (Timestamp, getTimeMillis)
import           System.MQ.Protocol.Technical (MonitoringData (..))
import           Web.Scotty.Trans             (get, json, params)
import           Web.Template                 (CustomWebServer (..),
                                               Process (..), Route (..),
                                               runWebServer)

main :: IO ()
main = do
    port <- portIO
    runWebServer port monitoringServer
  where
    monitoringServer = CustomWebServer () [Route get 1 "/monitoring" handlerMonitoring]

    portIO :: IO Int
    portIO = do
        config <- getConfigText
        return $ fromMaybe 3000 $ config |-? ["params", "mq_monitoring_handler", "port"]

handlerMonitoring :: Process ()
handlerMonitoring = Process $ do
  pool <- liftIO $ loadMongoPool "mq-monitoring-handler"
  paramMap <- fmap M.fromList params

  messages <- liftIO $ handleReq pool (paramMap M.!? "name") (paramMap M.!? "since")

  if "last" `elem` M.keys paramMap
    then json $ lastMessages messages
    else json messages

  where
    handleReq :: MongoPool -> Maybe Text -> Maybe Text -> IO [MoniUserData]
    handleReq pool specM sinceM = do
        query <- formQuery specM sinceM
        mData <- fmap (rights . fmap decode) . withMongoPool pool $ find 0 monitoringColl query
        return $ toUser <$> mData

    formQuery :: Maybe Text -> Maybe Text -> IO Document
    formQuery specM sinceM = do
        let specQuery = maybe [] (pure . ("name" =:) . toStrict) specM

        curTime <- runMQMonad getTimeMillis

        let since = maybe (curTime - oneDay) (read . unpack) sinceM
        let sinceQuery = pure ("sync_time" =: ["$gte" =: since])

        return $ specQuery ++ sinceQuery

    lastMessages :: [MoniUserData] -> [MoniUserData]
    lastMessages = fmap (head . reverse . sortOn muSyncTime) . groupBy ((==) `on` muName) . sortOn muName

    oneDay :: Timestamp
    oneDay = 86400000

-- | Format in which data is returned to user.
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
