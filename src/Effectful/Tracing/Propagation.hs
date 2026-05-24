{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation
-- Description : W3C Trace Context propagation across process boundaries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Carry a trace across a network hop using the
-- <https://www.w3.org/TR/trace-context/ W3C Trace Context> @traceparent@ and
-- @tracestate@ headers. 'injectContext' serializes the active span for an
-- outbound request; 'extractContext' parses the headers from an inbound request
-- into a 't:SpanContext', which 'withRemoteParent' then continues as a local
-- trace.
--
-- > -- server side: rejoin the caller's trace
-- > handle req =
-- >   case extractContext (requestHeaders req) of
-- >     Just parent -> withRemoteParent parent (withSpan "handle" (serve req))
-- >     Nothing     -> withSpan "handle" (serve req)
-- >
-- > -- client side: propagate to the next hop
-- > call = withSpan "call.downstream" $ do
-- >   headers <- injectContext
-- >   liftIO (httpGet url (baseHeaders <> headers))
--
-- This implements propagation directly against the library's own context, with
-- no dependency on an OpenTelemetry SDK, so it works under any interpreter that
-- maintains an active span (in-memory, pretty-print, OpenTelemetry).
module Effectful.Tracing.Propagation
  ( -- * Wire format
    traceparentHeader
  , tracestateHeader

    -- * Outbound
  , injectContext

    -- * Inbound
  , extractContext
  , withRemoteParent
  ) where

import Data.ByteString (ByteString)
import Data.Char (isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Network.HTTP.Types.Header (HeaderName)
import Numeric (readHex, showHex)

import Effectful (Eff, (:>))

import Effectful.Tracing.Effect (Tracer, getActiveSpan, withRemoteParent)
import Effectful.Tracing.Internal.Ids
  ( isValidSpanId
  , isValidTraceId
  , spanIdFromHex
  , spanIdToHex
  , traceIdFromHex
  , traceIdToHex
  )
import Effectful.Tracing.Internal.Types
  ( SpanContext (..)
  , TraceFlags (TraceFlags)
  , TraceState
  , emptyTraceState
  , traceStateFromHeader
  , traceStateToHeader
  )

-- | The @traceparent@ header name (case-insensitive, per HTTP).
traceparentHeader :: HeaderName
traceparentHeader = "traceparent"

-- | The @tracestate@ header name.
tracestateHeader :: HeaderName
tracestateHeader = "tracestate"

-- | Serialize the active span's context as @traceparent@ (and @tracestate@, if
-- non-empty) headers for an outbound request. Returns @[]@ when there is no
-- active span, so it composes with a base header list unconditionally.
injectContext :: Tracer :> es => Eff es [(HeaderName, ByteString)]
injectContext = maybe [] contextToHeaders <$> getActiveSpan

-- | The header list for a specific context.
contextToHeaders :: SpanContext -> [(HeaderName, ByteString)]
contextToHeaders context =
  (traceparentHeader, encodeUtf8 (renderTraceparent context))
    : [ (tracestateHeader, encodeUtf8 rendered)
      | let rendered = traceStateToHeader (spanContextTraceState context)
      , not (T.null rendered)
      ]

-- | Render a @traceparent@ value: @version-traceid-spanid-flags@, all lowercase
-- hex, version pinned to @00@.
renderTraceparent :: SpanContext -> Text
renderTraceparent context =
  T.intercalate
    "-"
    [ "00"
    , traceIdToHex (spanContextTraceId context)
    , spanIdToHex (spanContextSpanId context)
    , flagsToHex (spanContextTraceFlags context)
    ]

-- | A 't:TraceFlags' byte as two lowercase hex digits.
flagsToHex :: TraceFlags -> Text
flagsToHex (TraceFlags w) = T.justifyRight 2 '0' (T.pack (showHex w ""))

-- | Parse @traceparent@ / @tracestate@ headers from an inbound request into a
-- 't:SpanContext' marked remote. Returns 'Nothing' if @traceparent@ is absent or
-- malformed (an unparsable @tracestate@ is treated as empty rather than failing
-- the whole extraction, per the spec's resilience guidance). Header lookup is
-- case-insensitive because 'HeaderName' is case-insensitive.
extractContext :: [(HeaderName, ByteString)] -> Maybe SpanContext
extractContext headers = do
  rawTraceparent <- lookup traceparentHeader headers
  traceparent <- either (const Nothing) Just (decodeUtf8' rawTraceparent)
  parseTraceparent traceparent traceState
  where
    traceState = case lookup tracestateHeader headers of
      Just raw -> either (const emptyTraceState) traceStateFromHeader (decodeUtf8' raw)
      Nothing -> emptyTraceState

-- | Parse a decoded @traceparent@ value, attaching the already-parsed trace
-- state. Future versions are accepted by reading the first four fields; version
-- @00@ must have exactly four fields, and the all-zero ids are rejected.
parseTraceparent :: Text -> TraceState -> Maybe SpanContext
parseTraceparent raw traceState =
  case T.splitOn "-" (T.strip raw) of
    (version : tid : sid : flags : rest)
      | validVersion version
      , version /= "00" || null rest -> do
          traceId <- traceIdFromHex tid
          spanId <- spanIdFromHex sid
          if isValidTraceId traceId && isValidSpanId spanId
            then do
              flagsByte <- parseFlags flags
              Just
                SpanContext
                  { spanContextTraceId = traceId
                  , spanContextSpanId = spanId
                  , spanContextTraceFlags = flagsByte
                  , spanContextTraceState = traceState
                  , spanContextIsRemote = True
                  }
            else Nothing
    _ -> Nothing

-- | A version field is two hex digits and not the reserved @ff@.
validVersion :: Text -> Bool
validVersion v = T.length v == 2 && T.all isHexDigit v && v /= "ff"

-- | Parse the two-hex-digit flags field into a 't:TraceFlags' byte.
parseFlags :: Text -> Maybe TraceFlags
parseFlags t
  | T.length t == 2
  , T.all isHexDigit t
  , [(n, "")] <- readHex (T.unpack t) =
      Just (TraceFlags (fromIntegral (n :: Int)))
  | otherwise = Nothing
