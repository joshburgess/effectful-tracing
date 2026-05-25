{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.ServantSpec
-- Description : Tests for the Servant route-aware tracing middleware.
--
-- A tiny two-endpoint Servant API is served and driven through
-- 'traceServantMiddleware' with hand-built requests, run through the in-memory
-- interpreter so the resulting span can be inspected. We assert that an endpoint
-- annotated with 'WithSpanName' renames its server span to @\"{method} {route}\"@
-- and records the route template as @http.route@, while an unannotated endpoint
-- keeps the default method name and carries no route.
module Effectful.Tracing.Instrumentation.ServantSpec
  ( tests
  ) where

import Control.Monad (void)
import Data.List (find)
import Data.Maybe (isNothing)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Data.Text qualified as T

import Network.Wai (Application, Request (pathInfo, requestMethod), defaultRequest)
import Network.Wai.Internal (ResponseReceived (ResponseReceived))

import Servant
  ( Capture
  , Get
  , Handler
  , PlainText
  , Server
  , serve
  , type (:<|>) ((:<|>))
  , type (:>)
  )

import Effectful (Eff, IOE, UnliftStrategy (SeqUnlift), runEff, withEffToIO)
import Effectful qualified as E
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Span (spanAttributes, spanKind, spanName)
  , SpanKind (Server)
  , Tracer
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrText))
import Effectful.Tracing.Instrumentation.Servant (WithSpanName, traceServantMiddleware)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

-- | A two-endpoint API: an annotated, parameterized route and an unannotated
-- one. 'PlainText' avoids an @aeson@ dependency in the test.
type API =
  WithSpanName "/users/{id}" :> "users" :> Capture "id" Int :> Get '[PlainText] Text
    :<|> "health" :> Get '[PlainText] Text

server :: Server API
server = handleUser :<|> handleHealth
  where
    handleUser :: Int -> Handler Text
    handleUser uid = pure ("user " <> T.pack (show uid))

    handleHealth :: Handler Text
    handleHealth = pure "ok"

app :: Application
app = serve (Proxy :: Proxy API) server

tests :: TestTree
tests =
  testGroup
    "Instrumentation.Servant"
    [ testCase "an annotated endpoint is renamed to {method} {route}" $ do
        spans <- runServant (get ["users", "42"])
        s <- single spans
        spanName s @?= "GET /users/{id}"
        spanKind s @?= Server
        lookupText "http.route" s @?= Just "/users/{id}"
    , testCase "an unannotated endpoint keeps the default method name" $ do
        spans <- runServant (get ["health"])
        s <- single spans
        spanName s @?= "GET"
        assertBool "no http.route on an unannotated endpoint" (isNothing (lookupText "http.route" s))
    ]

-- | Serve the API around 'traceServantMiddleware' for one request, returning the
-- captured spans.
runServant :: Request -> IO [Span]
runServant req = runEff $ do
  cap <- newCapturedSpans
  runTracerInMemory cap (runOnce req)
  readCapturedSpans cap
  where
    runOnce :: (Tracer E.:> es, IOE E.:> es) => Request -> Eff es ()
    runOnce r =
      withEffToIO SeqUnlift $ \runInIO ->
        void (traceServantMiddleware runInIO app r discardResponse)

discardResponse :: a -> IO ResponseReceived
discardResponse _ = pure ResponseReceived

-- | A GET request for the given decoded path segments. Servant routes on
-- 'pathInfo'.
get :: [Text] -> Request
get segments =
  defaultRequest
    { requestMethod = "GET"
    , pathInfo = segments
    }

single :: [a] -> IO a
single [x] = pure x
single other = assertFailure ("expected exactly one span, got " <> show (length other))

lookupText :: Text -> Span -> Maybe Text
lookupText key s =
  case fmap (\(Attribute _ v) -> v) (find (\(Attribute k _) -> k == key) (spanAttributes s)) of
    Just (AttrText t) -> Just t
    _ -> Nothing
