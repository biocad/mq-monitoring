{-# LANGUAGE DeriveGeneric #-}

module Main where

import           System.MQ.Component  (runApp)
import           System.MQ.Monitoring (monitoringActionComm)

main :: IO ()
main = runApp "mq_monitoring" monitoringActionComm
