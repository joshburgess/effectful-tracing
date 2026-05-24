{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.WaiSpec
-- Description : Tests for the WAI tracing middleware.
--
-- The middleware is exercised against a hand-built 'Request' and a trivial
-- 'Application', run through the in-memory interpreter so the resulting spans
-- can be inspected directly. We assert the shape a server span should have: a
-- @server@ kind, a name and @http.*@ attributes from the request, the response
-- status code, a 5xx mapped to an error status, an inbound @traceparent@
-- continued as the parent trace, and an exception in the handler recorded and
-- re-raised.
module Effectful.Tracing.Instrumentation.WaiSpec
  ( tests
  ) where

import Control.Exception (SomeException, throwIO)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Maybe (isNothing)
import Data.Text (Text)

import Network.HTTP.Types (Status, status200, status404, status503)
import Network.Wai
  ( Application
  , Request (rawPathInfo, requestHeaders, requestMethod)
  , defaultRequest
  , responseLBS
  )
import Network.Wai.Internal (ResponseReceived (ResponseReceived))

import Effectful (Eff, IOE, UnliftStrategy (SeqUnlift), runEff, withEffToIO, (:>))
import Effectful.Exception qualified as Exc
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Span (spanAttributes, spanContext, spanKind, spanName, spanParentContext, spanStatus)
  , SpanContext (spanContextSpanId, spanContextTraceId)
  , SpanKind (Server)
  , SpanStatus (Error, Unset)
  , Tracer
  , spanIdToHex
  , traceIdToHex
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrInt, AttrText))
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Instrumentation.Wai"
    [ testCase "opens a server span named for the method, with http attributes" $ do
        (spans, outcome) <- runWai (get "/users") (ok "hi")
        assertRight outcome
        s <- single spans
        spanName s @?= "GET"
        spanKind s @?= Server
        lookupText "http.method" s @?= Just "GET"
        lookupText "http.target" s @?= Just "/users"
        lookupText "http.scheme" s @?= Just "http"
        lookupInt "http.status_code" s @?= Just 200
        spanStatus s @?= Unset
    , testCase "records the query string in http.target" $ do
        (spans, _) <- runWai (get "/search?q=cat") (ok "hi")
        s <- single spans
        lookupText "http.target" s @?= Just "/search?q=cat"
    , testCase "a 4xx leaves the span status unset" $ do
        (spans, _) <- runWai (get "/missing") (respondWith status404 "nope")
        s <- single spans
        lookupInt "http.status_code" s @?= Just 404
        spanStatus s @?= Unset
    , testCase "a 5xx marks the span as an error" $ do
        (spans, _) <- runWai (get "/boom") (respondWith status503 "down")
        s <- single spans
        lookupInt "http.status_code" s @?= Just 503
        assertError (spanStatus s)
    , testCase "with no inbound traceparent the span is a root" $ do
        (spans, _) <- runWai (get "/") (ok "hi")
        s <- single spans
        assertBool "server span is a root" (isNothing (spanParentContext s))
    , testCase "continues an inbound distributed trace" $ do
        let req = withTraceparent traceparentValue (get "/users")
        (spans, _) <- runWai req (ok "hi")
        s <- single spans
        -- The server span joins the remote trace and points at the remote span.
        traceIdToHex (spanContextTraceId (spanContext s)) @?= remoteTraceHex
        case spanParentContext s of
          Just parent -> spanIdToHex (spanContextSpanId parent) @?= remoteSpanHex
          Nothing -> assertFailure "expected the server span to have a remote parent"
    , testCase "records and re-raises an exception thrown by the handler" $ do
        (spans, outcome) <- runWai (get "/throws") boom
        case outcome of
          Left _ -> pure ()
          Right () -> assertFailure "expected the handler exception to propagate"
        s <- single spans
        assertError (spanStatus s)
    ]

-- W3C traceparent vector: version 00, a known trace id and span id, sampled.
traceparentValue :: ByteString
traceparentValue = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

remoteTraceHex :: Text
remoteTraceHex = "0af7651916cd43dd8448eb211c80319c"

remoteSpanHex :: Text
remoteSpanHex = "b7ad6b7169203331"

-- | Run the middleware around an application for one request, returning the
-- captured spans and whether the request completed or threw.
runWai :: Request -> Application -> IO ([Span], Either SomeException ())
runWai req app = runEff $ do
  cap <- newCapturedSpans
  outcome <- Exc.try (runTracerInMemory cap (runOnce req app))
  spans <- readCapturedSpans cap
  pure (spans, outcome)
  where
    runOnce :: (Tracer :> es, IOE :> es) => Request -> Application -> Eff es ()
    runOnce r a =
      withEffToIO SeqUnlift $ \runInIO ->
        void (traceMiddleware runInIO a r discardResponse)

-- | A responder that ignores the response (we read what we need from the span).
discardResponse :: a -> IO ResponseReceived
discardResponse _ = pure ResponseReceived

-- Request builders ----------------------------------------------------------

get :: ByteString -> Request
get path = defaultRequest {requestMethod = "GET", rawPathInfo = path}

withTraceparent :: ByteString -> Request -> Request
withTraceparent value req =
  req {requestHeaders = ("traceparent", value) : requestHeaders req}

-- Application builders -------------------------------------------------------

ok :: LBS.ByteString -> Application
ok = respondWith status200

respondWith :: Status -> LBS.ByteString -> Application
respondWith st body _ respond = respond (responseLBS st [] body)

boom :: Application
boom _ _ = throwIO (userError "handler exploded")

-- Assertions / lookups -------------------------------------------------------

single :: [a] -> IO a
single [x] = pure x
single other = assertFailure ("expected exactly one span, got " <> show (length other))

assertRight :: Either SomeException () -> IO ()
assertRight (Right ()) = pure ()
assertRight (Left err) = assertFailure ("expected success, got exception: " <> show err)

assertError :: SpanStatus -> IO ()
assertError (Error _) = pure ()
assertError other = assertFailure ("expected Error status, got " <> show other)

lookupText :: Text -> Span -> Maybe Text
lookupText key s =
  case findAttr key s of
    Just (AttrText t) -> Just t
    _ -> Nothing

lookupInt :: Text -> Span -> Maybe Int
lookupInt key s =
  case findAttr key s of
    Just (AttrInt n) -> Just (fromIntegral n)
    _ -> Nothing

findAttr :: Text -> Span -> Maybe AttributeValue
findAttr key s =
  fmap (\(Attribute _ v) -> v) (find (\(Attribute k _) -> k == key) (spanAttributes s))
