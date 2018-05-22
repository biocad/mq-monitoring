{-# LANGUAGE DeriveGeneric #-}

module Main where

import           System.MQ.Component  (runAppWithTech)
import           System.MQ.Monitoring (monitoringActionComm,
                                       monitoringActionTech)

main :: IO ()
main = runAppWithTech "mq_monitoring" monitoringActionComm monitoringActionTech
