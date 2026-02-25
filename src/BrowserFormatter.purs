module BrowserFormatter (browserFormatter) where

import Prelude

import BrowserFormatter.Pretty (prettyFormatter)
import Data.Log.Level (LogLevel(..))
import Data.Log.Message (Message)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console

-- | A custom browser logger that doesn't use terminal escape codes
browserFormatter :: LogLevel -> Message -> Aff Unit
browserFormatter lvl msg = when (msg.level >= lvl) $ logFunction =<< prettyFormatter msg
  where
  logFunction :: String -> Aff Unit
  logFunction = liftEffect <<< case msg.level of
    Trace -> Console.debug
    Debug -> Console.debug
    Info -> Console.info
    Warn -> Console.warn
    Error -> Console.error
