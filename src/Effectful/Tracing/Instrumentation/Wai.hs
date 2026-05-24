{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Wai
-- Description : Tracing middleware for WAI applications.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A WAI 'Middleware' that opens a @server@-kind span around each request. It
-- continues an inbound distributed trace (reading @traceparent@ \/ @tracestate@
-- with "Effectful.Tracing.Propagation"), records the request and response as
-- @http.*@ attributes following the OpenTelemetry HTTP semantic conventions
-- (v1.20.0, the @http.method@ \/ @http.target@ \/ @http.status_code@ set that
-- existing collectors and Jaeger understand), and lets the shared span lifecycle
-- record any exception as a span error before it propagates.
--
-- Because span management lives in @'Eff' es@ but WAI runs in 'IO', the
-- middleware takes an unlift function @forall a. 'Eff' es a -> 'IO' a@. Obtain
-- one with effectful's @withEffToIO@ (or @withRunInIO@) at the point you start
-- the server:
--
-- > import Effectful
-- >
-- > server :: (IOE :> es, Tracer :> es) => Application -> Eff es ()
-- > server app = withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
-- >   Warp.run 8080 (traceMiddleware runInIO app)
--
-- A real server handles requests concurrently, so the unlift must tolerate
-- concurrent invocation: use a concurrent unlift strategy, not the default
-- sequential one.
module Effectful.Tracing.Instrumentation.Wai
  ( -- * Middleware
    traceMiddleware
  , traceMiddlewareWith

    -- * Span naming
  , defaultSpanName
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)

import Network.HTTP.Types (HttpVersion (httpMajor, httpMinor), Status (statusCode, statusMessage))
import Network.Wai
  ( Middleware
  , Request
  , httpVersion
  , isSecure
  , rawPathInfo
  , rawQueryString
  , requestHeaders
  , requestMethod
  , responseStatus
  )

import Effectful (Eff, IOE, (:>))

import Effectful.Tracing
  ( Attribute
  , SpanArguments (attributes, kind)
  , SpanKind (Server)
  , SpanStatus (Error)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , extractContext
  , setStatus
  , withRemoteParent
  , withSpan'
  , (.=)
  )

-- | Wrap an 'Network.Wai.Application' so every request runs inside a
-- @server@-kind span, naming the span with 'defaultSpanName' (the request
-- method). See 'traceMiddlewareWith' to supply your own name (for example the
-- matched route, which produces lower-cardinality, more useful span names when
-- the routing layer knows it).
traceMiddleware
  :: (IOE :> es, Tracer :> es)
  => (forall a. Eff es a -> IO a)
  -- ^ Run an @'Eff' es@ action in 'IO'. Must tolerate concurrent calls; see the
  -- module header.
  -> Middleware
traceMiddleware = traceMiddlewareWith defaultSpanName

-- | 'traceMiddleware' with an explicit span-naming function. The OpenTelemetry
-- HTTP conventions recommend a low-cardinality name such as @\"{method}
-- {route}\"@; pass the matched route here when you have it, and avoid putting the
-- raw path (which is high-cardinality) in the name.
traceMiddlewareWith
  :: (IOE :> es, Tracer :> es)
  => (Request -> Text)
  -> (forall a. Eff es a -> IO a)
  -> Middleware
traceMiddlewareWith nameFor runInIO app req respond =
  runInIO (continueRemote (withSpan' (nameFor req) serverArgs body))
  where
    -- Rejoin an inbound distributed trace when the headers carry one; otherwise
    -- this request roots a new trace.
    continueRemote =
      maybe id withRemoteParent (extractContext (requestHeaders req))

    serverArgs =
      defaultSpanArguments
        { kind = Server
        , attributes = requestAttributes req
        }

    body = do
      -- Capture the response status as it flows back through the responder, so
      -- it can be recorded on the span before the scope closes.
      statusRef <- liftIO (newIORef Nothing)
      let respond' response = do
            writeIORef statusRef (Just (responseStatus response))
            respond response
      received <- liftIO (app req respond')
      mStatus <- liftIO (readIORef statusRef)
      case mStatus of
        Nothing -> pure ()
        Just status -> do
          addAttribute "http.status_code" (statusCode status)
          -- 5xx marks the server span as failed (4xx is a client error, not the
          -- server's, so it leaves the status unset per the conventions).
          when (statusCode status >= 500) $
            setStatus (Error (decodeUtf8Lenient (statusMessage status)))
      pure received

-- | The default span name: the HTTP request method (for example @\"GET\"@). This
-- is deliberately low-cardinality. When the route template is known, prefer
-- 'traceMiddlewareWith' to name the span after it.
defaultSpanName :: Request -> Text
defaultSpanName = decodeUtf8Lenient . requestMethod

-- | The @http.*@ request attributes recorded at span start.
requestAttributes :: Request -> [Attribute]
requestAttributes req =
  [ "http.method" .= decodeUtf8Lenient (requestMethod req)
  , "http.target" .= decodeUtf8Lenient (rawPathInfo req <> rawQueryString req)
  , "http.scheme" .= (if isSecure req then "https" else "http" :: Text)
  , "http.flavor" .= httpFlavor (httpVersion req)
  ]

-- | Render an 'HttpVersion' as the OTel @http.flavor@ value, for example
-- @\"1.1\"@.
httpFlavor :: HttpVersion -> Text
httpFlavor v = T.pack (show (httpMajor v)) <> "." <> T.pack (show (httpMinor v))
