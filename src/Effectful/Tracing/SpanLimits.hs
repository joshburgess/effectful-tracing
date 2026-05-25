-- |
-- Module      : Effectful.Tracing.SpanLimits
-- Description : Per-span caps on attributes, events, links, and value length.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A span with no upper bound on what it records is a memory hazard: an
-- accidental loop that calls @addEvent@ or @addAttribute@ grows the in-flight
-- span without limit, and a stray multi-megabyte string value rides all the way
-- to the exporter. OpenTelemetry's SDK guards against this with __span limits__,
-- and this module is the same idea: a small 'SpanLimits' record that the
-- span-opening interpreters honour.
--
-- Four caps are modelled, each a @'Maybe' 'Int'@ where 'Nothing' means
-- unlimited:
--
-- * 'attributeCountLimit': the most attributes a span keeps. Attributes past the
--   cap are dropped (the earliest are kept).
-- * 'attributeValueLengthLimit': the most characters a string attribute value
--   keeps; longer values (and the elements of string arrays) are truncated.
-- * 'eventCountLimit': the most events a span keeps (earliest kept).
-- * 'linkCountLimit': the most links a span keeps (earliest kept).
--
-- 'defaultSpanLimits' matches the OpenTelemetry defaults (128 attributes, 128
-- events, 128 links, and no value-length cap); 'unlimitedSpanLimits' disables
-- every cap. The interpreters apply the count caps as a span records, so an
-- in-flight span cannot grow past the limit, and 'applySpanLimits' is the pure
-- transform that produces the final, capped-and-truncated span. Keeping that
-- transform pure is what makes the whole policy testable without running an
-- interpreter.
module Effectful.Tracing.SpanLimits
  ( -- * Limits
    SpanLimits (..)
  , defaultSpanLimits
  , unlimitedSpanLimits

    -- * Applying limits (pure)
  , applySpanLimits
  ) where

import Data.Text qualified as T
import Data.Vector qualified as V

import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrText, AttrTextArray))
import Effectful.Tracing.Internal.Types
  ( Event (eventAttributes)
  , Link (linkAttributes)
  , Span (spanAttributes, spanEvents, spanLinks)
  )

-- | The per-span caps an interpreter enforces. Each count is a @'Maybe' 'Int'@:
-- 'Nothing' disables that cap, @'Just' n@ caps at @n@ (a negative @n@ is treated
-- as @0@).
data SpanLimits = SpanLimits
  { attributeCountLimit :: !(Maybe Int)
  -- ^ The most attributes a span keeps. Once reached, further attributes are
  -- dropped; the earliest-recorded are the ones kept.
  , attributeValueLengthLimit :: !(Maybe Int)
  -- ^ The most characters a string attribute value keeps. Longer 'AttrText'
  -- values, and the elements of 'AttrTextArray' values, are truncated to this
  -- many characters. Non-string values are unaffected.
  , eventCountLimit :: !(Maybe Int)
  -- ^ The most events a span keeps (earliest kept).
  , linkCountLimit :: !(Maybe Int)
  -- ^ The most links a span keeps (earliest kept).
  }
  deriving (Eq, Show)

-- | The OpenTelemetry default limits: 128 attributes, 128 events, 128 links, and
-- no value-length cap.
defaultSpanLimits :: SpanLimits
defaultSpanLimits =
  SpanLimits
    { attributeCountLimit = Just 128
    , attributeValueLengthLimit = Nothing
    , eventCountLimit = Just 128
    , linkCountLimit = Just 128
    }

-- | No caps at all: a span keeps every attribute, event, and link, and never
-- truncates a value. Useful in tests that assert on everything a computation
-- emitted.
unlimitedSpanLimits :: SpanLimits
unlimitedSpanLimits =
  SpanLimits
    { attributeCountLimit = Nothing
    , attributeValueLengthLimit = Nothing
    , eventCountLimit = Nothing
    , linkCountLimit = Nothing
    }

-- | Apply the limits to a completed span: cap its attributes, events, and links
-- to their counts (keeping the earliest), and truncate every string attribute
-- value (on the span, its events, and its links) to the value-length cap. Pure,
-- so it is the unit under test for the limit policy and is what every
-- span-opening interpreter runs as it finalizes a span.
applySpanLimits :: SpanLimits -> Span -> Span
applySpanLimits limits s =
  s
    { spanAttributes = map truncateAttr (capCount (attributeCountLimit limits) (spanAttributes s))
    , spanEvents = map truncateEventAttrs (capCount (eventCountLimit limits) (spanEvents s))
    , spanLinks = map truncateLinkAttrs (capCount (linkCountLimit limits) (spanLinks s))
    }
  where
    truncateAttr = truncateAttribute (attributeValueLengthLimit limits)
    truncateEventAttrs e = e {eventAttributes = map truncateAttr (eventAttributes e)}
    truncateLinkAttrs l = l {linkAttributes = map truncateAttr (linkAttributes l)}

-- | Keep at most @n@ of a list (the first @n@) when a cap is set; a negative cap
-- keeps none. 'Nothing' keeps everything.
capCount :: Maybe Int -> [a] -> [a]
capCount Nothing = id
capCount (Just n) = take (max 0 n)

-- | Truncate a string attribute value to the character cap, if one is set.
-- 'AttrText' is truncated; 'AttrTextArray' has each element truncated; every
-- other value is returned unchanged.
truncateAttribute :: Maybe Int -> Attribute -> Attribute
truncateAttribute Nothing attr = attr
truncateAttribute (Just n) (Attribute key value) = Attribute key (truncateValue (max 0 n) value)

truncateValue :: Int -> AttributeValue -> AttributeValue
truncateValue n (AttrText t) = AttrText (T.take n t)
truncateValue n (AttrTextArray v) = AttrTextArray (V.map (T.take n) v)
truncateValue _ value = value
