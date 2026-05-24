{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Sampler
-- Description : Span sampling: decide at span-start whether to record a span.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A 'Sampler' decides, when a span starts, whether it is dropped, recorded but
-- not exported, or recorded and exported. The decision is made from the
-- 'SamplerInput': the parent context, the trace id, and the span's name, kind,
-- initial attributes, and links.
--
-- == Why @shouldSample@ is plain @IO@
--
-- 'shouldSample' returns @'IO' 'SamplingResult'@ rather than @'Effectful.Eff' es@.
-- The built-in samplers are pure or clock-only, so 'IO' is sufficient, and it
-- keeps 'Sampler' a plain value that interpreters can hold without threading an
-- effect row through their configuration. The cost is that a user-written
-- sampler cannot use other effects (for example, reading configuration through
-- an effect). If that turns out to matter, the alternative is
-- @SamplerInput -> Eff es SamplingResult@ with the sampler parameterized over a
-- fixed effect row. For now the simpler 'IO' form is the default.
module Effectful.Tracing.Sampler
  ( -- * Decisions
    SamplingDecision (..)
  , SamplingResult (..)
  , simpleResult

    -- * Samplers
  , Sampler (..)
  , SamplerInput (..)

    -- * Built-in samplers
  , alwaysOn
  , alwaysOff
  , traceIdRatioBased
  , parentBased

    -- * Parent-based configuration
  , ParentBasedConfig (..)
  , defaultParentBasedConfig
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Effectful.Tracing.Attribute (Attribute)
import Effectful.Tracing.Internal.Ids (TraceId (TraceId))
import Effectful.Tracing.Internal.Types
  ( Link
  , SpanContext (spanContextIsRemote, spanContextTraceFlags)
  , SpanKind
  , TraceState
  , isSampled
  )

-- | What a sampler decides for a span.
data SamplingDecision
  = -- | Do not record the span at all.
    Drop
  | -- | Record the span locally, but do not export it. Useful for debugging.
    -- Interpreters without an export step treat this like 'RecordAndSample'.
    RecordOnly
  | -- | Record the span and export it; the @sampled@ trace flag is set.
    RecordAndSample
  deriving (Eq, Show, Enum, Bounded)

-- | A sampler's verdict: a 'SamplingDecision', any attributes the sampler wants
-- added to the span, and an optional replacement 'TraceState'.
data SamplingResult = SamplingResult
  { decision :: !SamplingDecision
  , extraAttributes :: ![Attribute]
  , newTraceState :: !(Maybe TraceState)
  }
  deriving (Eq, Show)

-- | A 'SamplingResult' carrying just a decision: no extra attributes, no
-- trace-state change.
simpleResult :: SamplingDecision -> SamplingResult
simpleResult d =
  SamplingResult {decision = d, extraAttributes = [], newTraceState = Nothing}

-- | The information a sampler sees about a span that is about to start.
data SamplerInput = SamplerInput
  { parentContext :: !(Maybe SpanContext)
  , traceId :: !TraceId
  , spanName :: !Text
  , spanKind :: !SpanKind
  , initialAttributes :: ![Attribute]
  , links :: ![Link]
  }

-- | A named sampling policy. 'shouldSample' is consulted once per span, at
-- start.
data Sampler = Sampler
  { samplerName :: !Text
  , shouldSample :: SamplerInput -> IO SamplingResult
  }

-- | Always record and sample every span.
alwaysOn :: Sampler
alwaysOn =
  Sampler
    { samplerName = "AlwaysOn"
    , shouldSample = \_ -> pure (simpleResult RecordAndSample)
    }

-- | Never record any span.
alwaysOff :: Sampler
alwaysOff =
  Sampler
    { samplerName = "AlwaysOff"
    , shouldSample = \_ -> pure (simpleResult Drop)
    }

-- | Sample a deterministic fraction of traces, keyed on the trace id, so every
-- span in a given trace gets the same decision. A ratio @<= 0@ drops
-- everything; @>= 1@ samples everything.
traceIdRatioBased :: Double -> Sampler
traceIdRatioBased ratio =
  Sampler
    { samplerName = "TraceIdRatioBased{" <> T.pack (show ratio) <> "}"
    , shouldSample = pure . simpleResult . decide . traceId
    }
  where
    decide tid
      | ratio <= 0 = Drop
      | ratio >= 1 = RecordAndSample
      | fromIntegral (traceIdHighBits tid) / twoToThe64 < ratio = RecordAndSample
      | otherwise = Drop
    twoToThe64 = fromIntegral (maxBound :: Word64) + 1 :: Double

-- | The high 8 bytes of a trace id as a big-endian 'Word64'.
traceIdHighBits :: TraceId -> Word64
traceIdHighBits (TraceId bs) =
  BS.foldl' (\acc b -> (acc `shiftL` 8) .|. fromIntegral b) 0 (BS.take 8 bs)

-- | How 'parentBased' decides, given the kind of parent a span has.
data ParentBasedConfig = ParentBasedConfig
  { rootSampler :: !Sampler
  -- ^ Used when the span has no parent.
  , remoteParentSampled :: !Sampler
  , remoteParentNotSampled :: !Sampler
  , localParentSampled :: !Sampler
  , localParentNotSampled :: !Sampler
  }

-- | The usual parent-based configuration: defer to a parent's @sampled@ flag
-- when there is a parent (sampled parent -> sample, unsampled parent -> drop,
-- for both local and remote parents), and use the given root sampler otherwise.
defaultParentBasedConfig :: Sampler -> ParentBasedConfig
defaultParentBasedConfig root =
  ParentBasedConfig
    { rootSampler = root
    , remoteParentSampled = alwaysOn
    , remoteParentNotSampled = alwaysOff
    , localParentSampled = alwaysOn
    , localParentNotSampled = alwaysOff
    }

-- | Follow the parent span's sampling decision when there is a parent,
-- otherwise consult the configured root sampler. This is the recommended
-- default policy: it keeps a trace's spans consistently sampled or dropped.
parentBased :: ParentBasedConfig -> Sampler
parentBased config =
  Sampler
    { samplerName = "ParentBased{" <> samplerName (rootSampler config) <> "}"
    , shouldSample = \input -> case parentContext input of
        Nothing -> shouldSample (rootSampler config) input
        Just pc -> shouldSample (chooseFor pc) input
    }
  where
    chooseFor pc = case (spanContextIsRemote pc, isSampled (spanContextTraceFlags pc)) of
      (True, True) -> remoteParentSampled config
      (True, False) -> remoteParentNotSampled config
      (False, True) -> localParentSampled config
      (False, False) -> localParentNotSampled config
