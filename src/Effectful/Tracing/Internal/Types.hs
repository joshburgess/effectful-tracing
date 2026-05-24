{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Internal.Types
-- Description : Core span data model shared by all interpreters.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : internal
--
-- The effect-system-independent data types that every interpreter shares:
-- trace flags, trace state, span context, and the immutable record of a
-- completed 'Span'. These deliberately do not depend on @effectful@ or
-- @hs-opentelemetry@; translation to OpenTelemetry happens in the bridge.
module Effectful.Tracing.Internal.Types
  ( -- * Trace flags
    TraceFlags (..)
  , defaultTraceFlags
  , isSampled
  , setSampled

    -- * Trace state
  , TraceState
  , emptyTraceState
  , insertTraceState
  , lookupTraceState
  , traceStateEntries
  , traceStateToHeader
  , traceStateFromHeader
  , maxTraceStateEntries

    -- * Span context
  , SpanContext (..)

    -- * Span metadata
  , SpanKind (..)
  , SpanStatus (..)
  , Event (..)
  , Link (..)

    -- * Completed span
  , Span (..)
  ) where

import Data.Bits (clearBit, setBit, testBit)
import Data.Char (isAsciiLower, isDigit, ord)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)

import Effectful.Tracing.Attribute (Attribute)
import Effectful.Tracing.Internal.Clock (Timestamp)
import Effectful.Tracing.Internal.Ids (SpanId, TraceId)

-- | W3C trace flags. Only bit 0 (@sampled@) currently has a defined meaning;
-- the remaining bits are reserved and are preserved across round-trips.
newtype TraceFlags = TraceFlags Word8
  deriving (Eq, Ord, Show)

-- | Trace flags with all bits clear (not sampled).
defaultTraceFlags :: TraceFlags
defaultTraceFlags = TraceFlags 0

-- | Whether the @sampled@ bit is set.
isSampled :: TraceFlags -> Bool
isSampled (TraceFlags w) = testBit w 0

-- | Set or clear the @sampled@ bit, leaving the reserved bits untouched.
setSampled :: Bool -> TraceFlags -> TraceFlags
setSampled True (TraceFlags w) = TraceFlags (setBit w 0)
setSampled False (TraceFlags w) = TraceFlags (clearBit w 0)

-- | W3C @tracestate@: an ordered list of key/value pairs, most-recently-mutated
-- first, with at most 'maxTraceStateEntries' entries. Construct it through
-- 'emptyTraceState' and 'insertTraceState' (which validate keys and values) or
-- parse it with 'traceStateFromHeader'.
newtype TraceState = TraceState [(Text, Text)]
  deriving (Eq, Show)

-- | The maximum number of entries a 'TraceState' may hold (32, per the W3C
-- spec).
maxTraceStateEntries :: Int
maxTraceStateEntries = 32

-- | An empty trace state.
emptyTraceState :: TraceState
emptyTraceState = TraceState []

-- | The entries of a trace state, in order (most-recently-mutated first).
traceStateEntries :: TraceState -> [(Text, Text)]
traceStateEntries (TraceState entries) = entries

-- | Insert or update a key, moving it to the head (most recent). Returns
-- 'Nothing' if the key or value is invalid, or if adding a new key would exceed
-- 'maxTraceStateEntries'.
insertTraceState :: Text -> Text -> TraceState -> Maybe TraceState
insertTraceState key value (TraceState entries)
  | not (isValidKey key) = Nothing
  | not (isValidValue value) = Nothing
  | length without >= maxTraceStateEntries = Nothing
  | otherwise = Just (TraceState ((key, value) : without))
  where
    without = filter ((/= key) . fst) entries

-- | Look up a key's value.
lookupTraceState :: Text -> TraceState -> Maybe Text
lookupTraceState key (TraceState entries) = lookup key entries

-- | Serialize to a @tracestate@ header value.
traceStateToHeader :: TraceState -> Text
traceStateToHeader (TraceState entries) =
  T.intercalate "," [key <> "=" <> value | (key, value) <- entries]

-- | Parse a @tracestate@ header value. Total: malformed members are dropped
-- (per the W3C resilience guidance), duplicate keys keep their first
-- occurrence, and the result is capped at 'maxTraceStateEntries'.
traceStateFromHeader :: Text -> TraceState
traceStateFromHeader header =
  TraceState (take maxTraceStateEntries (dedupe (mapMaybe parseMember members)))
  where
    members = T.splitOn "," header

    parseMember member =
      let trimmed = T.strip member
          (key, rest) = T.breakOn "=" trimmed
       in case T.stripPrefix "=" rest of
            Just value | isValidKey key && isValidValue value -> Just (key, value)
            _ -> Nothing

    dedupe = go []
      where
        go _ [] = []
        go seen (kv@(key, _) : rest)
          | key `elem` seen = go seen rest
          | otherwise = kv : go (key : seen) rest

-- | Whether a string is a valid @tracestate@ key. This validates a practical
-- subset of the W3C grammar: a non-empty, at-most-256-character string of
-- @[a-z0-9_\-*\/\@]@ beginning with a lowercase letter or digit.
isValidKey :: Text -> Bool
isValidKey key =
  not (T.null key)
    && T.length key <= 256
    && isKeyStart (T.head key)
    && T.all isKeyChar key
  where
    isKeyStart c = isAsciiLower c || isDigit c
    isKeyChar c = isAsciiLower c || isDigit c || c `elem` ['_', '-', '*', '/', '@']

-- | Whether a string is a valid @tracestate@ value: non-empty, at most 256
-- printable ASCII characters excluding comma and equals, with no trailing
-- space.
isValidValue :: Text -> Bool
isValidValue value =
  not (T.null value)
    && T.length value <= 256
    && T.all isValueChar value
    && T.last value /= ' '
  where
    isValueChar c =
      let o = ord c
       in o >= 0x20 && o <= 0x7E && c /= ',' && c /= '='

-- | The identity of a span and the trace it belongs to, as propagated in-band
-- and across process boundaries.
data SpanContext = SpanContext
  { spanContextTraceId :: !TraceId
  , spanContextSpanId :: !SpanId
  , spanContextTraceFlags :: !TraceFlags
  , spanContextTraceState :: !TraceState
  , spanContextIsRemote :: !Bool
  }
  deriving (Eq, Show)

-- | The role a span plays in a trace, per OpenTelemetry.
data SpanKind
  = Internal
  | Server
  | Client
  | Producer
  | Consumer
  deriving (Eq, Show, Enum, Bounded)

-- | A span's status. 'Unset' is the default; 'Error' carries a description.
data SpanStatus
  = Unset
  | Ok
  | Error !Text
  deriving (Eq, Show)

-- | A timestamped, named occurrence within a span.
data Event = Event
  { eventName :: !Text
  , eventTime :: !Timestamp
  , eventAttributes :: ![Attribute]
  }
  deriving (Eq, Show)

-- | A reference from this span to another span (possibly in another trace).
data Link = Link
  { linkContext :: !SpanContext
  , linkAttributes :: ![Attribute]
  }
  deriving (Eq, Show)

-- | The immutable record of a completed span. This is the value that crosses
-- the boundary into an interpreter for capture or export. The
-- mutable-during-construction representation lives in the interpreter layer.
data Span = Span
  { spanContext :: !SpanContext
  , spanParentContext :: !(Maybe SpanContext)
  , spanName :: !Text
  , spanKind :: !SpanKind
  , spanStartTime :: !Timestamp
  , spanEndTime :: !Timestamp
  , spanAttributes :: ![Attribute]
  , spanEvents :: ![Event]
  , spanLinks :: ![Link]
  , spanStatus :: !SpanStatus
  }
  deriving (Eq, Show)
