{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.HttpClient
-- Description : Tracing wrappers for http-client requests.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Wrap an @http-client@ request so it runs inside a @client@-kind span that
-- injects @traceparent@ \/ @tracestate@ into the outbound request (so the next
-- hop continues the trace), records the request and response following the
-- stable OpenTelemetry HTTP semantic conventions (see
-- "Effectful.Tracing.SemConv"), and is finalized even if the request throws.
--
-- > fetch :: (IOE :> es, Tracer :> es) => Manager -> Eff es (Response ByteString)
-- > fetch manager = do
-- >   req <- liftIO (parseRequest "https://example.com/widgets")
-- >   httpLbsTraced req manager
--
-- The API stays in @'Eff' es@ (unlike the WAI middleware, which must take an
-- unlift because WAI is an 'IO' type) because span management needs the effect
-- context and the request is driven from inside it. The optional manager-hook
-- approach is intentionally not provided: @'Manager'@'s @managerModifyRequest@
-- runs in 'IO' with no effect context, so it cannot carry the active span
-- without capturing an unlift at manager-construction time, and the request
-- wrapper here covers the need without that complication.
module Effectful.Tracing.Instrumentation.HttpClient
  ( httpLbsTraced
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)

import Network.HTTP.Client
  ( Manager
  , Request (requestHeaders)
  , Response (responseStatus)
  , getUri
  , httpLbs
  , method
  )
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (HeaderName)

import Effectful (Eff, IOE, (:>))

import Effectful.Tracing
  ( SpanArguments (attributes, kind)
  , SpanKind (Client)
  , SpanStatus (Error)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , injectContext
  , setStatus
  , traceparentHeader
  , tracestateHeader
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute)
import Effectful.Tracing.SemConv qualified as SemConv

-- | Perform an @http-client@ request (via 'httpLbs') inside a @client@-kind
-- span. The span is named after the HTTP method (low cardinality), the active
-- context is injected into the outbound request as @traceparent@ \/ @tracestate@
-- so the downstream service continues this trace, and the request and response
-- are recorded following the stable OpenTelemetry HTTP semantic conventions (see
-- "Effectful.Tracing.SemConv"). A response status @>= 400@ sets the span status to
-- 'Error' (from the client's view the call failed); a thrown exception is
-- recorded by the shared span lifecycle and re-raised.
httpLbsTraced
  :: (IOE :> es, Tracer :> es)
  => Request
  -> Manager
  -> Eff es (Response LBS.ByteString)
httpLbsTraced req manager =
  withSpan' (decodeUtf8Lenient (method req)) clientArgs $ do
    -- Inside the span, inject the active (client) span's context, then send.
    headers <- injectContext
    response <- liftIO (httpLbs (injectHeaders headers req) manager)
    let status = statusCode (responseStatus response)
    addAttribute SemConv.httpResponseStatusCode status
    when (status >= 400) $
      setStatus (Error ("HTTP " <> T.pack (show status)))
    pure response
  where
    clientArgs =
      defaultSpanArguments
        { kind = Client
        , attributes = requestAttributes req
        }

-- | The request attributes recorded at span start, following the stable HTTP
-- and URL semantic conventions (see "Effectful.Tracing.SemConv").
requestAttributes :: Request -> [Attribute]
requestAttributes req =
  [ SemConv.httpRequestMethod .= decodeUtf8Lenient (method req)
  , SemConv.urlFull .= urlText req
  ]

-- | The full request URL, as the @url.full@ attribute.
urlText :: Request -> Text
urlText = T.pack . show . getUri

-- | Replace any existing @traceparent@ \/ @tracestate@ on the request with the
-- freshly-injected ones, leaving all other headers untouched.
injectHeaders :: [(HeaderName, ByteString)] -> Request -> Request
injectHeaders injected req =
  req {requestHeaders = injected <> filter (not . isTraceHeader . fst) (requestHeaders req)}
  where
    isTraceHeader h = h == traceparentHeader || h == tracestateHeader
