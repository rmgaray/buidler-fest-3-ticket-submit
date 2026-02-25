-- | Copy of CTL's tag formatter, but without ANSI colours because they break
--   the browser output.
module BrowserFormatter.Pretty
  ( prettyFormatter
  ) where

import Prelude

import Control.Plus (empty)
import Data.Array (concat, cons, singleton)
import Data.Map (toUnfoldable, isEmpty)
import Data.Maybe (Maybe(Nothing, Just), fromMaybe)
import Data.JSDate (JSDate, toISOString)
import Data.Log.Level (LogLevel(Trace, Debug, Info, Warn, Error))
import Data.Log.Message (Message)
import Data.Log.Tag
  ( TagSet
  , Tag(StringTag, NumberTag, IntTag, BooleanTag, JSDateTag, TagSetTag)
  )
import Data.String (joinWith)
import Data.Traversable (sequence)
import Data.Tuple (Tuple(Tuple))
import Effect.Class (class MonadEffect, liftEffect)

prettyFormatter :: forall m. MonadEffect m => Message -> m String
prettyFormatter message =
  append <$> showMainLine message <*> showTags message.tags

showMainLine :: forall m. MonadEffect m => Message -> m String
showMainLine { level, timestamp, message } =
  liftEffect $ toISOString timestamp <#> \ts ->
    joinWith " "
      [ showLevel level
      , ts
      , message
      ]

showLevel :: LogLevel -> String
showLevel Trace = "[TRACE]"
showLevel Debug = "[DEBUG]"
showLevel Info = "[INFO]"
showLevel Warn = "[WARN]"
showLevel Error = "[ERROR]"

showTags :: forall m. MonadEffect m => TagSet -> m String
showTags = tagLines >>> case _ of
  Nothing -> pure ""
  Just lines -> lines <#> joinWith "\n" >>> append "\n"

tagLines :: forall m. MonadEffect m => TagSet -> Maybe (m (Array String))
tagLines tags
  | isEmpty tags = empty
  | otherwise = pure $ indentEachLine <$> concat <$> lineify tags

lineify :: forall m. MonadEffect m => TagSet -> m (Array (Array String))
lineify tags = sequence $ showField <$> toUnfoldable tags

showField :: forall m. MonadEffect m => Tuple String Tag -> m (Array String)
showField (Tuple name value) = showTag value $ name <> ": "

showTag :: forall m. MonadEffect m => Tag -> String -> m (Array String)
showTag (StringTag value) = showBasic value
showTag (IntTag value) = showBasic $ show value
showTag (NumberTag value) = showBasic $ show value
showTag (BooleanTag value) = showBasic $ show value
showTag (TagSetTag value) = showSubTags value
showTag (JSDateTag value) = showJsDate value

showSubTags :: forall m. MonadEffect m => TagSet -> String -> m (Array String)
showSubTags value label = cons label <$> fromMaybe (pure []) (tagLines value)

showJsDate :: forall m. MonadEffect m => JSDate -> String -> m (Array String)
showJsDate value label =
  liftEffect $ toISOString value >>= flip showBasic label

showBasic :: forall m. Applicative m => String -> String -> m (Array String)
showBasic value label = pure $ singleton $ label <> value

indentEachLine :: forall m. Functor m => m String -> m String
indentEachLine = map $ append "   "
