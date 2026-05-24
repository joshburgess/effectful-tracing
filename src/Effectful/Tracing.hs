-- |
-- Module      : Effectful.Tracing
-- Description : Public entry point for the effectful-tracing library.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Maintainer  : joshualoganburgess@gmail.com
-- Stability   : experimental
--
-- The public surface of @effectful-tracing@. This re-exports the core,
-- effect-system-independent data model (identifiers, attributes, trace flags
-- and state, the immutable 't:Span' record) together with the 'Tracer' effect and
-- its smart-constructor API, the sampling and context-propagation surface, and
-- the no-op interpreter. The span-opening interpreters live in their own
-- modules: @Effectful.Tracing.Interpreter.InMemory@,
-- @Effectful.Tracing.Interpreter.PrettyPrint@, and (behind the @otel@ flag)
-- @Effectful.Tracing.Interpreter.OpenTelemetry@.
module Effectful.Tracing
  ( -- * The tracing effect
    Tracer
  , withSpan
  , withSpan'
  , withLinkedRoot
  , withRemoteParent
  , addAttribute
  , addAttributes
  , addEvent
  , recordException
  , setStatus
  , getActiveSpan
  , SpanArguments (..)
  , defaultSpanArguments
  , transitionStatus

    -- * Interpreters
  , runTracerNoOp

    -- * Context propagation
  , traceparentHeader
  , tracestateHeader
  , injectContext
  , extractContext

    -- * Sampling
  , SamplingDecision (..)
  , SamplingResult (..)
  , Sampler (..)
  , SamplerInput
  , alwaysOn
  , alwaysOff
  , traceIdRatioBased
  , parentBased
  , ParentBasedConfig (..)
  , defaultParentBasedConfig

    -- * Attributes
  , module Effectful.Tracing.Attribute

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
import Effectful.Tracing.Effect
  ( SpanArguments (..)
  , Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , defaultSpanArguments
  , getActiveSpan
  , recordException
  , setStatus
  , transitionStatus
  , withLinkedRoot
  , withRemoteParent
  , withSpan
  , withSpan'
  )
import Effectful.Tracing.Interpreter.NoOp (runTracerNoOp)
import Effectful.Tracing.Propagation
  ( extractContext
  , injectContext
  , traceparentHeader
  , tracestateHeader
  )
import Effectful.Tracing.Sampler
  ( ParentBasedConfig (..)
  , Sampler (..)
  , SamplerInput
  , SamplingDecision (..)
  , SamplingResult (..)
  , alwaysOff
  , alwaysOn
  , defaultParentBasedConfig
  , parentBased
  , traceIdRatioBased
  )
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
