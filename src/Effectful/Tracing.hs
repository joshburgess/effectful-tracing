-- |
-- Module      : Effectful.Tracing
-- Description : Public entry point for the effectful-tracing library.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Maintainer  : joshualoganburgess@gmail.com
-- Stability   : experimental
--
-- The public surface of @effectful-tracing@. As of Phase 1 this re-exports the
-- core, effect-system-independent data model: identifiers, attributes, trace
-- flags and state, and the immutable 'Span' record. The @Tracer@ effect and the
-- interpreters are layered on top in later phases.
module Effectful.Tracing
  ( -- * Attributes
    module Effectful.Tracing.Attribute

    -- * Identifiers
  , TraceId
  , SpanId
  , newTraceId
  , newSpanId
  , traceIdToHex
  , spanIdToHex
  , traceIdFromHex
  , spanIdFromHex
  , isValidTraceId
  , isValidSpanId

    -- * Timestamps
  , Timestamp (..)
  , getTimestamp

    -- * Trace flags
  , TraceFlags
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

    -- * Spans
  , SpanContext (..)
  , SpanKind (..)
  , SpanStatus (..)
  , Event (..)
  , Link (..)
  , Span (..)
  ) where

import Effectful.Tracing.Attribute
import Effectful.Tracing.Internal.Clock (Timestamp (..), getTimestamp)
import Effectful.Tracing.Internal.Ids
  ( SpanId
  , TraceId
  , isValidSpanId
  , isValidTraceId
  , newSpanId
  , newTraceId
  , spanIdFromHex
  , spanIdToHex
  , traceIdFromHex
  , traceIdToHex
  )
import Effectful.Tracing.Internal.Types
