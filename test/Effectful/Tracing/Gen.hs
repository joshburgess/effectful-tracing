-- |
-- Module      : Effectful.Tracing.Gen
-- Description : Hedgehog generators for the core data model.
--
-- Generators for every public type in the core data model, used by the
-- property tests.
module Effectful.Tracing.Gen
  ( genTraceId
  , genSpanId
  , genAttributeKey
  , genAttributeValue
  , genAttribute
  , genTraceFlags
  , genTraceState
  , genTimestamp
  , genSpanContext
  , genSpanKind
  , genSpanStatus
  , genEvent
  , genLink
  , genSpan
  ) where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Time.Clock (addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range

import Effectful.Tracing.Attribute (Attribute (..), AttributeValue (..))
import Effectful.Tracing.Internal.Clock (Timestamp (..))
import Effectful.Tracing.Internal.Ids (SpanId (..), TraceId (..))
import Effectful.Tracing.Internal.Types
  ( Event (..)
  , Link (..)
  , Span (..)
  , SpanContext (..)
  , SpanKind
  , SpanStatus (..)
  , TraceFlags (..)
  , TraceState
  , emptyTraceState
  , insertTraceState
  )

-- | A 16-byte trace identifier (may be all-zero, which is fine for the codec
-- properties).
genTraceId :: Gen TraceId
genTraceId = TraceId <$> Gen.bytes (Range.singleton 16)

-- | An 8-byte span identifier.
genSpanId :: Gen SpanId
genSpanId = SpanId <$> Gen.bytes (Range.singleton 8)

genText :: Gen Text
genText = Gen.text (Range.linear 0 16) Gen.alphaNum

-- | A non-empty attribute key.
genAttributeKey :: Gen Text
genAttributeKey = Gen.text (Range.linear 1 24) Gen.alphaNum

genInt64 :: Gen Int64
genInt64 = Gen.integral (Range.linearFrom 0 minBound maxBound)

genDouble :: Gen Double
genDouble = Gen.double (Range.linearFracFrom 0 (-1.0e9) 1.0e9)

-- | Any attribute value, scalar or homogeneous array.
genAttributeValue :: Gen AttributeValue
genAttributeValue =
  Gen.choice
    [ AttrText <$> genText
    , AttrBool <$> Gen.bool
    , AttrInt <$> genInt64
    , AttrDouble <$> genDouble
    , AttrTextArray . V.fromList <$> Gen.list (Range.linear 0 4) genText
    , AttrBoolArray . V.fromList <$> Gen.list (Range.linear 0 4) Gen.bool
    , AttrIntArray . V.fromList <$> Gen.list (Range.linear 0 4) genInt64
    , AttrDoubleArray . V.fromList <$> Gen.list (Range.linear 0 4) genDouble
    ]

genAttribute :: Gen Attribute
genAttribute = Attribute <$> genAttributeKey <*> genAttributeValue

genTraceFlags :: Gen TraceFlags
genTraceFlags = TraceFlags <$> Gen.word8 Range.constantBounded

-- | A valid trace state, built through 'insertTraceState' so all entries
-- satisfy the W3C key/value constraints and the entry cap.
genTraceState :: Gen TraceState
genTraceState = do
  pairs <- Gen.list (Range.linear 0 10) ((,) <$> genStateKey <*> genStateValue)
  pure (foldr addEntry emptyTraceState pairs)
  where
    addEntry (key, value) st = fromMaybe st (insertTraceState key value st)

genStateKey :: Gen Text
genStateKey = do
  start <- Gen.element keyStartChars
  rest <- Gen.list (Range.linear 0 8) (Gen.element keyChars)
  pure (mkText (start : rest))
  where
    keyStartChars = ['a' .. 'z'] <> ['0' .. '9']
    keyChars = keyStartChars <> "_-*/@"

genStateValue :: Gen Text
genStateValue = mkText <$> Gen.list (Range.linear 1 12) (Gen.element valueChars)
  where
    valueChars = [c | c <- [' ' .. '~'], c /= ' ', c /= ',', c /= '=']

mkText :: String -> Text
mkText = T.pack

genTimestamp :: Gen Timestamp
genTimestamp = do
  secs <- Gen.integral (Range.linear 0 2_000_000_000)
  pure (Timestamp (posixSecondsToUTCTime (fromInteger (secs :: Integer))))

genSpanContext :: Gen SpanContext
genSpanContext =
  SpanContext
    <$> genTraceId
    <*> genSpanId
    <*> genTraceFlags
    <*> genTraceState
    <*> Gen.bool

genSpanKind :: Gen SpanKind
genSpanKind = Gen.enumBounded

genSpanStatus :: Gen SpanStatus
genSpanStatus =
  Gen.choice
    [ pure Unset
    , pure Ok
    , Error <$> genText
    ]

genEvent :: Gen Event
genEvent =
  Event
    <$> genText
    <*> genTimestamp
    <*> Gen.list (Range.linear 0 4) genAttribute

genLink :: Gen Link
genLink = Link <$> genSpanContext <*> Gen.list (Range.linear 0 4) genAttribute

-- | A completed span with @start <= end@ by construction.
genSpan :: Gen Span
genSpan = do
  context <- genSpanContext
  parent <- Gen.maybe genSpanContext
  name <- genText
  kind <- genSpanKind
  Timestamp start <- genTimestamp
  durationSecs <- Gen.integral (Range.linear 0 100_000)
  let end = addUTCTime (fromInteger (durationSecs :: Integer)) start
  attributes <- Gen.list (Range.linear 0 6) genAttribute
  events <- Gen.list (Range.linear 0 4) genEvent
  links <- Gen.list (Range.linear 0 4) genLink
  status <- genSpanStatus
  pure
    Span
      { spanContext = context
      , spanParentContext = parent
      , spanName = name
      , spanKind = kind
      , spanStartTime = Timestamp start
      , spanEndTime = Timestamp end
      , spanAttributes = attributes
      , spanEvents = events
      , spanLinks = links
      , spanStatus = status
      }
