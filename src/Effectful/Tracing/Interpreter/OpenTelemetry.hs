{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Effectful.Tracing.Interpreter.OpenTelemetry
-- Description : Export spans to an OpenTelemetry SDK via @hs-opentelemetry@.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- 'runTracerOTel' interprets the 'Tracer' effect by opening real spans (the
-- shared lifecycle in "Effectful.Tracing.Internal.Live") and, as each span
-- completes, translating it into an @hs-opentelemetry@ 'OTel.ImmutableSpan' and
-- handing it to one or more OpenTelemetry 'SpanProcessor's. This is the bridge
-- to real export: pair it with an exporter (OTLP over HTTP\/gRPC, or a file
-- exporter for testing) and a processor (simple or batch) from
-- @hs-opentelemetry-sdk@.
--
-- __Identity stays ours.__ The library mints its own trace and span ids and runs
-- its own 'Sampler' before OpenTelemetry sees the span; the translation copies
-- those ids verbatim into the exported span. This keeps the ids consistent with
-- what "Effectful.Tracing.Propagation" injects on the wire, which would not hold
-- if we delegated id generation to OpenTelemetry's @createSpan@. The design note
-- for this phase records why, and the consequences.
--
-- __Interop boundary.__ We deliberately do not thread OpenTelemetry's in-process
-- @Context@. Mixing this interpreter with an existing @hs-opentelemetry@
-- instrumented library (for example upstream WAI or @http-client@
-- instrumentation that reads\/writes OpenTelemetry's @Context@) will not
-- automatically nest spans across that boundary: the two context worlds are
-- separate. Use this library's own instrumentation helpers, or bridge the two
-- worlds explicitly at the seam. The design note expands on this.
module Effectful.Tracing.Interpreter.OpenTelemetry
  ( OtelConfig (..)
  , runTracerOTel

    -- * Translation (exposed for testing)
  , toImmutableSpan
  ) where

import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Vector qualified as V

import System.Clock (TimeSpec (TimeSpec))

import OpenTelemetry.Attributes qualified as OtelAttr
import OpenTelemetry.Common qualified as OtelCommon
import OpenTelemetry.Processor.Span (SpanProcessor, spanProcessorForceFlush, spanProcessorOnEnd)
import OpenTelemetry.Trace.Core
  ( InstrumentationLibrary
  , TracerOptions
  , tracerOptions
  )
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as OtelId
import OpenTelemetry.Trace.TraceState qualified as OtelTS
import OpenTelemetry.Util qualified as OtelUtil

import Effectful (Eff, IOE, (:>))
import Effectful.Exception (finally)
import Control.Monad.IO.Class (liftIO)

import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (..))
import Effectful.Tracing.Effect (Tracer)
import Effectful.Tracing.Internal.Clock (Timestamp (Timestamp))
import Effectful.Tracing.Internal.Ids (SpanId (SpanId), TraceId (TraceId))
import Effectful.Tracing.Internal.Live (interpretTracer)
import Effectful.Tracing.Internal.Types
  ( Event (Event)
  , Link (Link)
  , Span (..)
  , SpanContext (..)
  , SpanKind (Client, Consumer, Internal, Producer, Server)
  , SpanStatus (Error, Ok, Unset)
  , TraceFlags (TraceFlags)
  , TraceState
  , traceStateEntries
  )
import Effectful.Tracing.Sampler (Sampler)

-- | How to export spans to OpenTelemetry.
--
-- The library cannot reach the processors registered inside a
-- @TracerProvider@ (the SDK does not expose them), so the processors are passed
-- here directly. Build them from @hs-opentelemetry-sdk@ (for example
-- @simpleProcessor@ or @batchProcessor@ wrapping an OTLP or file exporter) and
-- supply the same instrumentation scope you would give the SDK. Completed spans
-- are handed to every processor in the list.
data OtelConfig = OtelConfig
  { spanProcessors :: ![SpanProcessor]
  -- ^ Processors that receive each completed span. Lifecycle (shutdown) is the
  -- caller's responsibility; 'runTracerOTel' force-flushes them when its scope
  -- ends.
  , instrumentationScope :: !InstrumentationLibrary
  -- ^ Names the instrumentation (library name and version). Exporters group
  -- spans by this scope.
  , sampler :: !Sampler
  -- ^ Our sampler, consulted once per span before OpenTelemetry sees it.
  }

-- | Interpret 'Tracer' by exporting every recorded span to the configured
-- OpenTelemetry processors. Spans dropped by the 'Sampler' are not exported;
-- 'RecordOnly' and 'RecordAndSample' both are (the @sampled@ flag distinguishes
-- them on the wire). When the scope ends, every processor is force-flushed so
-- buffered spans are not lost.
--
-- > main :: IO ()
-- > main = do
-- >   exporter  <- loadExporterEnvironmentVariables >>= otlpExporter
-- >   processor <- batchProcessor batchTimeoutConfig exporter
-- >   let config = OtelConfig [processor] "my-service" alwaysOn
-- >   runEff . runTracerOTel config $ withSpan "request" (pure ())
runTracerOTel
  :: IOE :> es
  => OtelConfig
  -> Eff (Tracer : es) a
  -> Eff es a
runTracerOTel config action = do
  -- A Tracer is required for the ImmutableSpan's tracer field (exporters read
  -- its instrumentation scope to group spans). It needs a TracerProvider, but
  -- not its processors: we feed the processors ourselves, so an empty provider
  -- suffices to carry the scope.
  provider <- liftIO (OTel.createTracerProvider [] OTel.emptyTracerProviderOptions)
  let tracer = OTel.makeTracer provider (instrumentationScope config) emptyTracerOptions
      processors = spanProcessors config
  interpretTracer (sampler config) (export tracer processors) action
    `finally` liftIO (mapM_ spanProcessorForceFlush processors)

-- | 'tracerOptions' with no overrides.
emptyTracerOptions :: TracerOptions
emptyTracerOptions = tracerOptions

-- | Translate a completed span and hand it to each processor. A span whose ids
-- are malformed (impossible for spans this library mints, since it always uses
-- 16- and 8-byte ids) is skipped rather than crashing the closing thread.
export :: OTel.Tracer -> [SpanProcessor] -> Span -> IO ()
export tracer processors completed =
  case toImmutableSpan tracer completed of
    Left _ -> pure ()
    Right immutable -> do
      ref <- newIORef immutable
      mapM_ (`spanProcessorOnEnd` ref) processors

-- | Translate one of our completed 'Span's into an @hs-opentelemetry@
-- 'OTel.ImmutableSpan'. Returns 'Left' only if a trace or span id is not the
-- byte length OpenTelemetry requires, which cannot happen for spans this library
-- produces; the 'Either' makes the translation total and gives the round-trip
-- tests something to assert on.
toImmutableSpan :: OTel.Tracer -> Span -> Either String OTel.ImmutableSpan
toImmutableSpan tracer completed = do
  context <- toOtelContext (spanContext completed)
  parentContext <- traverse toOtelContext (spanParentContext completed)
  links <- traverse toOtelLink (spanLinks completed)
  pure
    OTel.ImmutableSpan
      { OTel.spanName = spanName completed
      , OTel.spanParent = OTel.wrapSpanContext <$> parentContext
      , OTel.spanContext = context
      , OTel.spanKind = toOtelKind (spanKind completed)
      , OTel.spanStart = toOtelTimestamp (spanStartTime completed)
      , OTel.spanEnd = Just (toOtelTimestamp (spanEndTime completed))
      , OTel.spanAttributes = toOtelAttributes (spanAttributes completed)
      , OTel.spanLinks = toCollection links
      , OTel.spanEvents = toCollection (map toOtelEvent (spanEvents completed))
      , OTel.spanStatus = toOtelStatus (spanStatus completed)
      , OTel.spanTracer = tracer
      }

-- | Translate a span context, copying our ids and flags verbatim.
toOtelContext :: SpanContext -> Either String OTel.SpanContext
toOtelContext context = do
  let TraceId traceBytes = spanContextTraceId context
      SpanId spanBytes = spanContextSpanId context
  traceId <- OtelId.bytesToTraceId traceBytes
  spanId <- OtelId.bytesToSpanId spanBytes
  pure
    OTel.SpanContext
      { OTel.traceFlags = toOtelFlags (spanContextTraceFlags context)
      , OTel.isRemote = spanContextIsRemote context
      , OTel.traceId = traceId
      , OTel.spanId = spanId
      , OTel.traceState = toOtelTraceState (spanContextTraceState context)
      }

-- | The only flag is @sampled@, so the byte maps across directly.
toOtelFlags :: TraceFlags -> OTel.TraceFlags
toOtelFlags (TraceFlags w) = OTel.traceFlagsFromWord8 w

-- | Rebuild the W3C trace state in OpenTelemetry's representation, preserving
-- the most-recently-mutated-first ordering ('OtelTS.insert' prepends, so folding
-- from the oldest entry leaves the newest first).
toOtelTraceState :: TraceState -> OtelTS.TraceState
toOtelTraceState traceState =
  foldr
    (\(key, value) -> OtelTS.insert (OtelTS.Key key) (OtelTS.Value value))
    OtelTS.empty
    (traceStateEntries traceState)

toOtelKind :: SpanKind -> OTel.SpanKind
toOtelKind = \case
  Internal -> OTel.Internal
  Server -> OTel.Server
  Client -> OTel.Client
  Producer -> OTel.Producer
  Consumer -> OTel.Consumer

toOtelStatus :: SpanStatus -> OTel.SpanStatus
toOtelStatus = \case
  Unset -> OTel.Unset
  Ok -> OTel.Ok
  Error message -> OTel.Error message

-- | Our 'Timestamp' is a 'UTCTime'; OpenTelemetry's is a @TimeSpec@ split into
-- whole seconds and nanoseconds since the Unix epoch.
toOtelTimestamp :: Timestamp -> OtelCommon.Timestamp
toOtelTimestamp (Timestamp utc) =
  let nanos = floor (toRational (utcTimeToPOSIXSeconds utc) * 1_000_000_000) :: Integer
      (secs, nsec) = nanos `divMod` 1_000_000_000
   in OtelCommon.Timestamp (TimeSpec (fromInteger secs) (fromInteger nsec))

toOtelEvent :: Event -> OTel.Event
toOtelEvent (Event name time attrs) =
  OTel.Event
    { OTel.eventName = name
    , OTel.eventAttributes = toOtelAttributes attrs
    , OTel.eventTimestamp = toOtelTimestamp time
    }

toOtelLink :: Link -> Either String OTel.Link
toOtelLink (Link context attrs) = do
  otelContext <- toOtelContext context
  pure
    OTel.Link
      { OTel.frozenLinkContext = otelContext
      , OTel.frozenLinkAttributes = toOtelAttributes attrs
      }

-- | Build OpenTelemetry 'OtelAttr.Attributes' from our attribute list. The
-- limits are not applied (the library does not impose its own caps); the SDK's
-- span limits still apply downstream.
toOtelAttributes :: [Attribute] -> OtelAttr.Attributes
toOtelAttributes attrs =
  OtelAttr.unsafeAttributesFromListIgnoringLimits (map toOtelAttribute attrs)

toOtelAttribute :: Attribute -> (Text, OTel.Attribute)
toOtelAttribute (Attribute key value) = (key, toOtelAttributeValue value)

toOtelAttributeValue :: AttributeValue -> OTel.Attribute
toOtelAttributeValue = \case
  AttrText t -> OTel.AttributeValue (OTel.TextAttribute t)
  AttrBool b -> OTel.AttributeValue (OTel.BoolAttribute b)
  AttrInt i -> OTel.AttributeValue (OTel.IntAttribute i)
  AttrDouble d -> OTel.AttributeValue (OTel.DoubleAttribute d)
  AttrTextArray xs -> OTel.AttributeArray (map OTel.TextAttribute (V.toList xs))
  AttrBoolArray xs -> OTel.AttributeArray (map OTel.BoolAttribute (V.toList xs))
  AttrIntArray xs -> OTel.AttributeArray (map OTel.IntAttribute (V.toList xs))
  AttrDoubleArray xs -> OTel.AttributeArray (map OTel.DoubleAttribute (V.toList xs))

-- | Pour a list into an append-only bounded collection. Our spans are already
-- bounded by the caller, so the cap is generous.
toCollection :: [a] -> OtelUtil.AppendOnlyBoundedCollection a
toCollection = foldl OtelUtil.appendToBoundedCollection (OtelUtil.emptyAppendOnlyBoundedCollection 1024)
