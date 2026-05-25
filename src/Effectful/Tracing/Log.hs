{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Log
-- Description : Correlate log lines with the active trace and span.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- The single most useful thing you can do with a trace and a log line is join
-- them: stamp every log record with the trace and span id that was active when
-- it was written, so a log search jumps straight to the trace and a trace view
-- links back to its logs. This module exposes the active span's identifiers for
-- exactly that, using the field names from the OpenTelemetry
-- <https://opentelemetry.io/docs/specs/otel/logs/ logs data model> (@trace_id@,
-- @span_id@, @trace_flags@).
--
-- It is deliberately framework-agnostic, in the same spirit as
-- "Effectful.Tracing.Testing": the accessors return plain 'Text' and
-- @[('Text', 'Text')]@ with no logging-library dependency, so they drop into
-- @co-log@, @katip@, @fast-logger@, @monad-logger@, or a bare @hPutStrLn@ the
-- same way.
--
-- > -- attach trace context to a structured log call
-- > logWithTrace :: (Tracer :> es, Logger :> es) => Text -> Eff es ()
-- > logWithTrace message = do
-- >   fields <- activeCorrelationFields
-- >   emit message fields
--
-- All accessors read the active span through the 'Tracer' effect, so they return
-- the empty / 'Nothing' case cleanly when no span is in scope (a startup log
-- line, say) rather than forcing the caller to special-case it.
module Effectful.Tracing.Log
  ( -- * Correlation context
    Correlation (..)
  , activeCorrelation

    -- * Log fields
  , correlationFields
  , activeCorrelationFields

    -- * Individual identifiers
  , activeTraceId
  , activeSpanId
  ) where

import Data.Text (Text)

import Effectful (Eff, (:>))

import Effectful.Tracing.Effect (Tracer, getActiveSpan)
import Effectful.Tracing.Internal.Ids (spanIdToHex, traceIdToHex)
import Effectful.Tracing.Internal.Types
  ( SpanContext (..)
  , isSampled
  )

-- | The identifiers needed to tie a log record to a trace: the active span's
-- trace id and span id (lower-case hex, the wire form), and whether the trace is
-- sampled. Built from the active 't:SpanContext'.
data Correlation = Correlation
  { correlationTraceId :: !Text
  -- ^ The 32-character hex trace id.
  , correlationSpanId :: !Text
  -- ^ The 16-character hex span id.
  , correlationSampled :: !Bool
  -- ^ Whether the trace is sampled (the @trace_flags@ low bit).
  }
  deriving (Eq, Show)

-- | The 'Correlation' for the active span, or 'Nothing' when no span is in
-- scope.
activeCorrelation :: Tracer :> es => Eff es (Maybe Correlation)
activeCorrelation = fmap toCorrelation <$> getActiveSpan
  where
    toCorrelation context =
      Correlation
        { correlationTraceId = traceIdToHex (spanContextTraceId context)
        , correlationSpanId = spanIdToHex (spanContextSpanId context)
        , correlationSampled = isSampled (spanContextTraceFlags context)
        }

-- | Render a 'Correlation' as the OpenTelemetry log-correlation fields:
-- @trace_id@, @span_id@, and @trace_flags@ (@"01"@ when sampled, @"00"@
-- otherwise). The pairs drop straight into any structured logger's key-value
-- context.
correlationFields :: Correlation -> [(Text, Text)]
correlationFields correlation =
  [ ("trace_id", correlationTraceId correlation)
  , ("span_id", correlationSpanId correlation)
  , ("trace_flags", if correlationSampled correlation then "01" else "00")
  ]

-- | The log-correlation fields for the active span, or @[]@ when no span is in
-- scope, so the result appends to a logger's context unconditionally.
activeCorrelationFields :: Tracer :> es => Eff es [(Text, Text)]
activeCorrelationFields = maybe [] correlationFields <$> activeCorrelation

-- | The active span's hex trace id, or 'Nothing' when no span is in scope.
activeTraceId :: Tracer :> es => Eff es (Maybe Text)
activeTraceId = fmap correlationTraceId <$> activeCorrelation

-- | The active span's hex span id, or 'Nothing' when no span is in scope.
activeSpanId :: Tracer :> es => Eff es (Maybe Text)
activeSpanId = fmap correlationSpanId <$> activeCorrelation
