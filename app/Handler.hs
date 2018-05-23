{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Monad.IO.Class      (liftIO)
import           Data.Aeson                  (FromJSON (..), ToJSON (..))
import           Data.Aeson.Picker           ((|-?))
import           Data.Bson                   (Document, (=:))
import           Data.Either                 (rights)
import           Data.Function               (on)
import           Data.List                   (groupBy, sortOn)
import qualified Data.Map.Strict             as M (fromList, keys, (!?))
import           Data.Maybe                  (fromMaybe)
import qualified Data.Text                   as T (Text)
import           Data.Text.Lazy              (Text, toStrict, unpack)
import           Database.MongoDB.WrapperNew (MongoPool, decode, find,
                                              loadMongoPool, withMongoPool)
import           System.BCD.Config           (getConfigText)
import           System.MQ.Monad             (runMQMonad)
import           System.MQ.Monitoring        (ErrorDBUnit (..),
                                              MoniUserData (..), errorsColl,
                                              monitoringColl, toUser)
import           System.MQ.Protocol          (Timestamp, getTimeMillis)
import           Web.Scotty.Trans            (get, json, params)
import           Web.Template                (CustomWebServer (..),
                                              Process (..), Route (..),
                                              runWebServer)

-- | Type of handler that is being run
--
data Handler a b = Handler { name          :: b -> String -- ^ getter of name from db unit
                           , time          :: b -> Int    -- ^ getter of time from db unit
                           , changeMessage :: a -> b      -- ^ function to change representation of db unit
                           , collName      :: T.Text      -- ^ collection in which units are stored
                           }

main :: IO ()
main = do
    port <- portIO
    runWebServer port monitoringServer
  where
    monitoringServer = CustomWebServer () [ Route get 1 "/monitoring" $ runHandler monitoringHandler
                                          , Route get 1 "/errors" $ runHandler errorsHandler
                                          ]

    monitoringHandler = Handler muName muSyncTime toUser monitoringColl
    errorsHandler = Handler erName erSyncTime id errorsColl

    portIO :: IO Int
    portIO = do
        config <- getConfigText
        return $ fromMaybe 3000 $ config |-? ["params", "mq_monitoring_handler", "port"]

runHandler :: forall a b . (FromJSON a, ToJSON b) => Handler a b -> Process ()
runHandler Handler{..} = Process $ do
    pool <- liftIO $ loadMongoPool "mq-monitoring-handler"
    paramMap <- fmap M.fromList params

    messages <- liftIO $ handleReq pool (paramMap M.!? "name") (paramMap M.!? "since")
    let changedMessages = fmap changeMessage messages

    if "last" `elem` M.keys paramMap
      then json $ lastMessages changedMessages
      else json changedMessages

  where
    handleReq :: MongoPool -> Maybe Text -> Maybe Text -> IO [a]
    handleReq pool specM sinceM = do
        query <- formQuery specM sinceM
        mData <- fmap (rights . fmap decode) . withMongoPool pool $ find 0 collName query
        return mData

    formQuery :: Maybe Text -> Maybe Text -> IO Document
    formQuery specM sinceM = do
        let specQuery = maybe [] (pure . ("name" =:) . toStrict) specM

        curTime <- runMQMonad getTimeMillis

        let since = maybe (curTime - oneDay) (read . unpack) sinceM
        let sinceQuery = pure ("sync_time" =: ["$gte" =: since])

        return $ specQuery ++ sinceQuery

    lastMessages :: [b] -> [b]
    lastMessages mData = res
      where
        groupedData = groupBy ((==) `on` name) . sortOn name $ mData

        res = fmap (head . reverse . sortOn time) groupedData

    oneDay :: Timestamp
    oneDay = 86400000
