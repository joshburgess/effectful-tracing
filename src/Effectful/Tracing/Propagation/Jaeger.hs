{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.Jaeger
-- Description : Jaeger (uber-trace-id) propagation across process boundaries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Carry a trace across a network hop using the
-- <https://www.jaegertracing.io/docs/1.21/client-libraries/#propagation-format uber-trace-id>
-- header that older Jaeger client libraries emit, plus the @uberctx-@ baggage
-- headers. This is an alternative to the W3C Trace Context propagator in
-- "Effectful.Tracing.Propagation" and the B3 propagator in
-- "Effectful.Tracing.Propagation.B3"; reach for it when interoperating with
-- infrastructure still instrumented with native Jaeger clients.
--
-- The single @uber-trace-id@ header is
-- @{trace-id}:{span-id}:{parent-span-id}:{flags}@, where the ids are hex (Jaeger
-- strips leading zeros, so they may be shorter than full width), the
-- @parent-span-id@ field is deprecated (carries no information the library
-- needs) but still required by the format, and @flags@ is a one-byte bitmask
-- whose low bit is the sampled decision. 'injectContextJaeger' writes it and
-- 'extractContextJaeger' reads it into a 't:SpanContext' that
-- 'Effectful.Tracing.withRemoteParent' can continue locally.
--
-- Baggage rides on one @uberctx-{key}: {value}@ header per item.
-- 'injectBaggageJaeger' emits those from the ambient
-- 'Effectful.Tracing.Baggage.BaggageContext', and 'extractBaggageJaeger' reads
-- them back into a 'Baggage' set. Jaeger baggage has no metadata concept, so
-- metadata is dropped on the way out and absent on the way in.
--
-- > -- server side: rejoin a Jaeger caller's trace and its baggage
-- > handle req = serveWith (extractBaggageJaeger headers) $
-- >   case extractContextJaeger headers of
-- >     Just parent -> withRemoteParent parent (withSpan "handle" (serve req))
-- >     Nothing     -> withSpan "handle" (serve req)
-- >   where headers = requestHeaders req
-- >
-- > -- client side: propagate to a Jaeger downstream
-- > call = withSpan "call.downstream" $ do
-- >   context <- injectContextJaeger
-- >   bag     <- injectBaggageJaeger
-- >   liftIO (httpGet url (baseHeaders <> context <> bag))
--
-- Like the W3C and B3 propagators, this works directly against the library's own
-- context under any interpreter that maintains an active span, with no
-- dependency on an OpenTelemetry SDK.
module Effectful.Tracing.Propagation.Jaeger
  ( -- * Header names
    uberTraceIdHeader
  , uberBaggagePrefix

    -- * Trace context
  , injectContextJaeger
  , extractContextJaeger

    -- * Baggage
  , injectBaggageJaeger
  , extractBaggageJaeger
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.Char (digitToInt, isHexDigit)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Network.HTTP.Types.Header (HeaderName)

import Effectful (Eff, (:>))

import Effectful.Tracing.Baggage
  ( Baggage
  , BaggageContext
  , BaggageEntry (BaggageEntry)
  , baggageFromList
  , baggageToList
  , getBaggage
  )
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
import Effectful.Tracing.Propagation.Baggage (maxBaggageEntries)

-- | The @uber-trace-id@ header name (case-insensitive, per HTTP).
uberTraceIdHeader :: HeaderName
uberTraceIdHeader = "uber-trace-id"

-- | The prefix Jaeger puts on each per-item baggage header, @uberctx-@. A header
-- named @uberctx-{key}@ carries the baggage value for @{key}@.
uberBaggagePrefix :: ByteString
uberBaggagePrefix = "uberctx-"

-- | Serialize the active span's context as a single @uber-trace-id@ header for an
-- outbound request, using the full 128-bit trace id and a @0@ parent field.
-- Returns @[]@ when there is no active span, so it composes with a base header
-- list unconditionally.
injectContextJaeger :: Tracer :> es => Eff es [(HeaderName, ByteString)]
injectContextJaeger = maybe [] (\context -> [renderUberTraceId context]) <$> getActiveSpan

-- | Serialize the ambient baggage as @uberctx-{key}@ headers, one per entry
-- (ordered by key). Metadata is dropped, as Jaeger baggage has no equivalent.
-- Returns @[]@ when the baggage is empty.
injectBaggageJaeger :: BaggageContext :> es => Eff es [(HeaderName, ByteString)]
injectBaggageJaeger = map renderItem . baggageToList <$> getBaggage
  where
    renderItem (key, BaggageEntry value _metadata) =
      (CI.mk (uberBaggagePrefix <> encodeUtf8 key), encodeUtf8 value)

-- | The @uber-trace-id@ header for a context.
renderUberTraceId :: SpanContext -> (HeaderName, ByteString)
renderUberTraceId context = (uberTraceIdHeader, encodeUtf8 value)
  where
    value =
      T.intercalate
        ":"
        [ traceIdToHex (spanContextTraceId context)
        , spanIdToHex (spanContextSpanId context)
        , "0"
        , renderFlags (spanContextTraceFlags context)
        ]
    renderFlags flags = if isSampled flags then "1" else "0"

-- | Parse an inbound @uber-trace-id@ header into a 't:SpanContext' marked remote.
-- Returns 'Nothing' when the header is absent, not decodable, or malformed.
-- Jaeger carries no @tracestate@ equivalent, so the trace state is empty.
extractContextJaeger :: [(HeaderName, ByteString)] -> Maybe SpanContext
extractContextJaeger headers =
  lookup uberTraceIdHeader headers >>= eitherToMaybe . decodeUtf8' >>= parseUberTraceId

-- | Read @uberctx-@ baggage headers into a 'Baggage' set, skipping any whose key
-- or value is empty or not decodable, and capping at the W3C entry limit so a
-- flood of headers cannot grow the set without bound. Metadata is always absent.
extractBaggageJaeger :: [(HeaderName, ByteString)] -> Baggage
extractBaggageJaeger = baggageFromList . take maxBaggageEntries . mapMaybe item
  where
    item (name, rawValue) = do
      keyBytes <- BS.stripPrefix uberBaggagePrefix (CI.foldedCase name)
      key <- T.strip <$> eitherToMaybe (decodeUtf8' keyBytes)
      value <- T.strip <$> eitherToMaybe (decodeUtf8' rawValue)
      if T.null key then Nothing else Just (key, BaggageEntry value Nothing)

-- | Parse a decoded @uber-trace-id@ value. The format requires exactly four
-- colon-separated fields; the trace and span ids must be valid hex, the parent
-- field is accepted and ignored, and the flags field's low bit is the sampled
-- decision.
parseUberTraceId :: Text -> Maybe SpanContext
parseUberTraceId raw =
  case T.splitOn ":" (T.strip raw) of
    [tid, sid, _parent, flags] -> do
      traceId <- parseTraceId tid
      spanId <- parseSpanId sid
      traceFlags <- parseFlags flags
      validContext traceId spanId traceFlags
    _ -> Nothing

-- | Parse a Jaeger trace id. Jaeger may strip leading zeros and may use a 64-bit
-- (16-hex) or 128-bit (32-hex) id, so any non-empty hex string up to 32
-- characters is left-padded with zeros to the library's fixed 128-bit width.
parseTraceId :: Text -> Maybe TraceId
parseTraceId t
  | T.null t || T.length t > 32 = Nothing
  | otherwise = traceIdFromHex (T.justifyRight 32 '0' t)

-- | Parse a Jaeger span id, left-padding a leading-zero-stripped value back to
-- the full 64-bit (16-hex) width.
parseSpanId :: Text -> Maybe SpanId
parseSpanId t
  | T.null t || T.length t > 16 = Nothing
  | otherwise = spanIdFromHex (T.justifyRight 16 '0' t)

-- | Parse the one-byte flags field (a hex bitmask) and read its low bit as the
-- sampled decision; the debug and firehose bits have no home in the library's
-- one-bit 'TraceFlags' and are ignored. A non-hex or empty field is rejected.
parseFlags :: Text -> Maybe TraceFlags
parseFlags t
  | T.null t || not (T.all isHexDigit t) = Nothing
  | otherwise =
      let sampled = odd (T.foldl' (\acc c -> acc * 16 + digitToInt c) (0 :: Int) t)
       in Just (if sampled then setSampled True defaultTraceFlags else defaultTraceFlags)

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
