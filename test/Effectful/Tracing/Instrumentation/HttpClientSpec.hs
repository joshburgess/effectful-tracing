{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.HttpClientSpec
-- Description : Tests for the http-client tracing wrapper.
--
-- These run against a real loopback server (a tiny WAI app served by Warp on an
-- ephemeral port via 'Warp.testWithApplication') so the wrapper exercises an
-- actual request/response. The server records the headers it received, which
-- lets us assert that the wrapper injected a @traceparent@ carrying the client
-- span's trace id (propagation end to end), and the captured spans let us assert
-- the @client@ kind, the stable HTTP \/ URL attributes, and the status mapping.
module Effectful.Tracing.Instrumentation.HttpClientSpec
  ( tests
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Monad (void)
import Data.List (find, isInfixOf)
import Data.Text qualified as T

import Network.HTTP.Client
  ( Manager
  , Request
  , defaultManagerSettings
  , newManager
  , parseRequest
  )
import Network.HTTP.Types (Status, status200, status500)
import Network.HTTP.Types.Header (RequestHeaders)
import Network.Wai (Application, requestHeaders, responseLBS)
import Network.Wai.Handler.Warp (Port)
import Network.Wai.Handler.Warp qualified as Warp

import Effectful (Eff, IOE, runEff, (:>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Span (spanAttributes, spanContext, spanKind, spanStatus)
  , SpanContext (spanContextTraceId)
  , SpanKind (Client)
  , SpanStatus (Error, Unset)
  , Tracer
  , extractContext
  , traceIdToHex
  , withSpan
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrInt, AttrText))
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Instrumentation.HttpClient"
    [ testCase "opens a client span and records http attributes" $
        withEchoServer status200 $ \captured port -> do
          (spans, _) <- runClient port "/widgets"
          s <- clientSpan spans
          lookupText "http.request.method" s @?= Just "GET"
          assertBool
            "url.full contains the request path"
            (maybe False (("/widgets" `isInfixOf`) . T.unpack) (lookupText "url.full" s))
          lookupInt "http.response.status_code" s @?= Just 200
          spanStatus s @?= Unset
          -- The server received our traceparent, carrying the client span's trace.
          headers <- readMVar captured
          remote <- maybe (assertFailure "server saw no traceparent") pure (extractContext headers)
          traceIdToHex (spanContextTraceId remote)
            @?= traceIdToHex (spanContextTraceId (spanContext s))
    , testCase "a >= 400 response sets the span status to error" $
        withEchoServer status500 $ \_ port -> do
          (spans, _) <- runClient port "/boom"
          s <- clientSpan spans
          lookupInt "http.response.status_code" s @?= Just 500
          case spanStatus s of
            Error _ -> pure ()
            other -> assertFailure ("expected Error status, got " <> show other)
    ]

-- | Serve a tiny app on an ephemeral port that records the inbound headers and
-- replies with the given status, then run the continuation against it.
withEchoServer :: Status -> (MVar RequestHeaders -> Port -> IO a) -> IO a
withEchoServer responseStatus k = do
  captured <- newMVar []
  let app :: Application
      app req respond = do
        modifyMVar_ captured (const (pure (requestHeaders req)))
        respond (responseLBS responseStatus [] "ok")
  Warp.testWithApplication (pure app) (k captured)

-- | Send a traced GET to the loopback server, returning the captured spans.
runClient :: Port -> String -> IO ([Span], ())
runClient port path = do
  manager <- newManager defaultManagerSettings
  req <- parseRequest ("http://localhost:" <> show port <> path)
  spans <- runEff $ do
    cap <- newCapturedSpans
    _ <- runTracerInMemory cap (call manager req)
    readCapturedSpans cap
  pure (spans, ())
  where
    call :: (Tracer :> es, IOE :> es) => Manager -> Request -> Eff es ()
    call manager req = withSpan "outer" (void (httpLbsTraced req manager))

-- | The single @client@-kind span among the captured spans.
clientSpan :: [Span] -> IO Span
clientSpan spans =
  maybe (assertFailure "expected a client span") pure (find ((== Client) . spanKind) spans)

lookupText :: T.Text -> Span -> Maybe T.Text
lookupText key s =
  case findAttr key s of
    Just (AttrText t) -> Just t
    _ -> Nothing

lookupInt :: T.Text -> Span -> Maybe Int
lookupInt key s =
  case findAttr key s of
    Just (AttrInt n) -> Just (fromIntegral n)
    _ -> Nothing

findAttr :: T.Text -> Span -> Maybe AttributeValue
findAttr key s =
  fmap (\(Attribute _ v) -> v) (find (\(Attribute k _) -> k == key) (spanAttributes s))
