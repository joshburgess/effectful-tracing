{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.B3
-- Description : B3 (Zipkin) propagation across process boundaries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Carry a trace across a network hop using the
-- <https://github.com/openzipkin/b3-propagation B3> headers that Zipkin and
-- many service meshes (Envoy, older Istio) emit. This is an alternative to the
-- W3C Trace Context propagator in "Effectful.Tracing.Propagation"; reach for it
-- when interoperating with infrastructure that speaks B3 rather than
-- @traceparent@.
--
-- Two wire encodings are supported, as in the B3 spec:
--
-- * the single @b3@ header, @{traceId}-{spanId}-{samplingState}-{parentSpanId}@
--   (the last two fields optional), which is the recommended form for new
--   deployments; and
-- * the legacy multi-header form (@X-B3-TraceId@, @X-B3-SpanId@,
--   @X-B3-Sampled@, @X-B3-Flags@, @X-B3-ParentSpanId@).
--
-- 'injectContextB3' writes the single header and 'injectContextB3Multi' the
-- multi-header form; 'extractContextB3' reads either (preferring the single
-- header when present) into a 't:SpanContext' that 'Effectful.Tracing.withRemoteParent'
-- can continue locally.
--
-- > -- server side: rejoin a B3 caller's trace
-- > handle req =
-- >   case extractContextB3 (requestHeaders req) of
-- >     Just parent -> withRemoteParent parent (withSpan "handle" (serve req))
-- >     Nothing     -> withSpan "handle" (serve req)
-- >
-- > -- client side: propagate to a B3 downstream
-- > call = withSpan "call.downstream" $ do
-- >   headers <- injectContextB3
-- >   liftIO (httpGet url (baseHeaders <> headers))
--
-- Like the W3C propagator, this works directly against the library's own
-- context under any interpreter that maintains an active span, with no
-- dependency on an OpenTelemetry SDK.
module Effectful.Tracing.Propagation.B3
  ( -- * Single-header wire format
    b3Header

    -- * Multi-header wire format
  , b3TraceIdHeader
  , b3SpanIdHeader
  , b3ParentSpanIdHeader
  , b3SampledHeader
  , b3FlagsHeader

    -- * Outbound
  , injectContextB3
  , injectContextB3Multi

    -- * Inbound
  , extractContextB3
  ) where

import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Network.HTTP.Types.Header (HeaderName)

import Effectful (Eff, (:>))

import Effectful.Tracing.Effect (Tracer, getActiveSpan)
import Effectful.Tracing.Internal.Ids
  ( SpanId
  , TraceId
  , isValidSpanId
  , isValidTraceId
  , spanIdFromHex
  , spanIdToHex
  , traceIdFromHex
  , traceIdToHex
  )
import Effectful.Tracing.Internal.Types
  ( SpanContext (..)
  , TraceFlags
  , defaultTraceFlags
  , emptyTraceState
  , isSampled
  , setSampled
  )

-- | The single @b3@ header name (case-insensitive, per HTTP).
b3Header :: HeaderName
b3Header = "b3"

-- | The @X-B3-TraceId@ header name (multi-header form).
b3TraceIdHeader :: HeaderName
b3TraceIdHeader = "X-B3-TraceId"

-- | The @X-B3-SpanId@ header name (multi-header form).
b3SpanIdHeader :: HeaderName
b3SpanIdHeader = "X-B3-SpanId"

-- | The @X-B3-ParentSpanId@ header name. Read tolerantly but never required:
-- the library continues the caller's span (@X-B3-SpanId@) as the remote parent,
-- so the grandparent id carries no information it needs.
b3ParentSpanIdHeader :: HeaderName
b3ParentSpanIdHeader = "X-B3-ParentSpanId"

-- | The @X-B3-Sampled@ header name, carrying @1@ or @0@.
b3SampledHeader :: HeaderName
b3SampledHeader = "X-B3-Sampled"

-- | The @X-B3-Flags@ header name. A value of @1@ is B3's debug flag, which
-- implies a sampling decision of accept.
b3FlagsHeader :: HeaderName
b3FlagsHeader = "X-B3-Flags"

-- | Serialize the active span's context as a single @b3@ header for an outbound
-- request, using the full 128-bit trace id. Returns @[]@ when there is no
-- active span, so it composes with a base header list unconditionally.
injectContextB3 :: Tracer :> es => Eff es [(HeaderName, ByteString)]
injectContextB3 = maybe [] (\context -> [renderSingle context]) <$> getActiveSpan

-- | Serialize the active span's context as the legacy multi-header form
-- (@X-B3-TraceId@ \/ @X-B3-SpanId@ \/ @X-B3-Sampled@). Returns @[]@ when there
-- is no active span.
injectContextB3Multi :: Tracer :> es => Eff es [(HeaderName, ByteString)]
injectContextB3Multi = maybe [] renderMulti <$> getActiveSpan

-- | The single @b3@ header for a context.
renderSingle :: SpanContext -> (HeaderName, ByteString)
renderSingle context = (b3Header, encodeUtf8 value)
  where
    value =
      T.intercalate
        "-"
        [ traceIdToHex (spanContextTraceId context)
        , spanIdToHex (spanContextSpanId context)
        , renderSampling (spanContextTraceFlags context)
        ]

-- | The multi-header list for a context.
renderMulti :: SpanContext -> [(HeaderName, ByteString)]
renderMulti context =
  [ (b3TraceIdHeader, encodeUtf8 (traceIdToHex (spanContextTraceId context)))
  , (b3SpanIdHeader, encodeUtf8 (spanIdToHex (spanContextSpanId context)))
  , (b3SampledHeader, encodeUtf8 (renderSampling (spanContextTraceFlags context)))
  ]

-- | The sampling field for the sampled bit: @"1"@ when set, @"0"@ otherwise.
renderSampling :: TraceFlags -> Text
renderSampling flags = if isSampled flags then "1" else "0"

-- | Parse B3 headers from an inbound request into a 't:SpanContext' marked
-- remote. The single @b3@ header is preferred when present (and a malformed one
-- fails the extraction rather than falling through); otherwise the multi-header
-- form is read. Returns 'Nothing' when neither form yields a valid trace id and
-- span id. B3 carries no @tracestate@ equivalent, so the trace state is empty.
extractContextB3 :: [(HeaderName, ByteString)] -> Maybe SpanContext
extractContextB3 headers =
  case lookup b3Header headers of
    Just raw -> eitherToMaybe (decodeUtf8' raw) >>= parseSingle
    Nothing -> parseMulti headers

-- | Parse a decoded single-header value. The trace and span ids are required;
-- the sampling field is optional (absent means a deferred decision, treated as
-- unsampled) and a trailing parent span id is accepted and ignored.
parseSingle :: Text -> Maybe SpanContext
parseSingle raw =
  case T.splitOn "-" (T.strip raw) of
    [tid, sid] -> build tid sid Nothing
    [tid, sid, samp] -> build tid sid (Just samp)
    [tid, sid, samp, _parent] -> build tid sid (Just samp)
    _ -> Nothing
  where
    build tid sid msamp = do
      traceId <- parseTraceId tid
      spanId <- parseSpanId sid
      flags <- maybe (Just deferredFlags) parseSampling msamp
      validContext traceId spanId flags

-- | Parse the multi-header form. @X-B3-TraceId@ and @X-B3-SpanId@ are required;
-- the sampling decision comes from @X-B3-Flags: 1@ (debug, implies accept) or
-- @X-B3-Sampled@, defaulting to unsampled when neither is present.
parseMulti :: [(HeaderName, ByteString)] -> Maybe SpanContext
parseMulti headers = do
  tid <- decoded b3TraceIdHeader
  sid <- decoded b3SpanIdHeader
  traceId <- parseTraceId tid
  spanId <- parseSpanId sid
  validContext traceId spanId multiFlags
  where
    decoded name = lookup name headers >>= eitherToMaybe . decodeUtf8'
    multiFlags =
      case (decoded b3FlagsHeader, decoded b3SampledHeader) of
        (Just "1", _) -> setSampled True defaultTraceFlags
        (_, Just samp) -> fromMaybe deferredFlags (parseSampling samp)
        _ -> deferredFlags

-- | The flags for a deferred or absent sampling decision: unsampled, the
-- conservative choice when the caller has expressed no preference we can read.
deferredFlags :: TraceFlags
deferredFlags = defaultTraceFlags

-- | Parse a B3 sampling field. @1@ and @d@ (debug) mean accept; @0@ means deny.
parseSampling :: Text -> Maybe TraceFlags
parseSampling s
  | s == "1" || s == "d" = Just (setSampled True defaultTraceFlags)
  | s == "0" = Just defaultTraceFlags
  | otherwise = Nothing

-- | Parse a B3 trace id, which may be 64-bit (16 hex characters) or 128-bit (32
-- hex characters). A 64-bit id is left-padded with zeros to the library's
-- fixed 128-bit width, per the B3 spec.
parseTraceId :: Text -> Maybe TraceId
parseTraceId t
  | T.length t == 16 = traceIdFromHex (T.replicate 16 "0" <> t)
  | otherwise = traceIdFromHex t

-- | Parse a B3 span id (16 hex characters).
parseSpanId :: Text -> Maybe SpanId
parseSpanId = spanIdFromHex

-- | Assemble a remote 't:SpanContext' once the ids are confirmed non-zero and
-- correctly sized.
validContext :: TraceId -> SpanId -> TraceFlags -> Maybe SpanContext
validContext traceId spanId flags
  | isValidTraceId traceId && isValidSpanId spanId =
      Just
        SpanContext
          { spanContextTraceId = traceId
          , spanContextSpanId = spanId
          , spanContextTraceFlags = flags
          , spanContextTraceState = emptyTraceState
          , spanContextIsRemote = True
          }
  | otherwise = Nothing

-- | Collapse a decode 'Either' to 'Maybe', discarding the error.
eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe = either (const Nothing) Just
