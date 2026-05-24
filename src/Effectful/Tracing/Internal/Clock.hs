{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : Effectful.Tracing.Internal.Clock
-- Description : Timestamp abstraction for span timing.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : internal
--
-- A thin wrapper over wall-clock time so tests can substitute a fixed clock and
-- so the underlying representation can change (for example to monotonic nanos)
-- without churning every call site.
module Effectful.Tracing.Internal.Clock
  ( Timestamp (..)
  , getTimestamp
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Time.Clock (UTCTime, getCurrentTime)

-- | A point in time associated with a span boundary or event.
newtype Timestamp = Timestamp UTCTime
  deriving stock (Eq, Ord, Show)

-- | The current wall-clock time.
getTimestamp :: (MonadIO m) => m Timestamp
getTimestamp = Timestamp <$> liftIO getCurrentTime
