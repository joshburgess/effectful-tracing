{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.CompositeSpec
-- Description : Tests for combining propagators.
--
-- The combinators are exercised end to end: 'injectContextAll' and
-- 'injectBaggageAll' through the in-memory interpreter (where an active span and
-- ambient baggage exist), and 'extractContextFirst' \/ 'extractBaggageAll' with
-- crafted header vectors. The order-sensitive cases pin down the contract that
-- matters for a composite: inject writes every format, extract takes the first
-- matching context but merges all baggage, and the @OTEL_PROPAGATORS@ token
-- lookups resolve the standard names.
module Effectful.Tracing.Propagation.CompositeSpec
  ( tests
  ) where

import Data.ByteString (ByteString)

import Effectful (Eff, IOE, runEff, runPureEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Baggage
  ( lookupBaggageValue
  , runBaggage
  , withBaggageEntry
  )
import Effectful.Tracing.Internal.Ids (traceIdToHex)
import Effectful.Tracing.Internal.Types (SpanContext (..))
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Propagation (traceparentHeader)
import Effectful.Tracing.Propagation.B3 (b3Header)
import Effectful.Tracing.Propagation.Baggage (baggageHeader)
import Effectful.Tracing.Propagation.Composite
  ( baggageByToken
  , baggageName
  , b3Multi
  , b3Single
  , extractBaggageAll
  , extractContextFirst
  , injectBaggageAll
  , injectContextAll
  , jaegerBaggage
  , jaegerTraceContext
  , traceContextByToken
  , traceContextName
  , w3cBaggage
  , w3cTraceContext
  )

tests :: TestTree
tests =
  testGroup
    "Propagation.Composite"
    [ testGroup "injectContextAll" injectContextTests
    , testGroup "extractContextFirst" extractContextTests
    , testGroup "injectBaggageAll" injectBaggageTests
    , testGroup "extractBaggageAll" extractBaggageTests
    , testGroup "token lookup" tokenTests
    ]

-- A pair of distinct trace ids so the "first wins" extract test can tell which
-- propagator produced the context.
traceIdA :: ByteString
traceIdA = "4bf92f3577b34da6a3ce929d0e0e4736"

traceIdB :: ByteString
traceIdB = "0af7651916cd43dd8448eb211c80319c"

spanIdA :: ByteString
spanIdA = "00f067aa0ba902b7"

injectContextTests :: [TestTree]
injectContextTests =
  [ testCase "writes every configured format for the active span" $ do
      headers <- run (withSpan "outbound" (injectContextAll [w3cTraceContext, b3Single]))
      let names = map fst headers
      assertBool "traceparent present" (traceparentHeader `elem` names)
      assertBool "b3 present" (b3Header `elem` names)
  , testCase "an empty propagator list emits no headers" $ do
      headers <- run (withSpan "outbound" (injectContextAll []))
      headers @?= []
  , testCase "emits no headers when there is no active span" $ do
      headers <- run (injectContextAll [w3cTraceContext, b3Single])
      headers @?= []
  ]

extractContextTests :: [TestTree]
extractContextTests =
  [ testCase "takes the first propagator that parses" $ do
      -- Only a b3 header is present; W3C is tried first and misses, B3 matches.
      let headers = [(b3Header, traceIdB <> "-" <> spanIdA <> "-1")]
          context = extractContextFirst [w3cTraceContext, b3Single] headers
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "0af7651916cd43dd8448eb211c80319c"
  , testCase "order decides the winner when several formats are present" $ do
      -- traceparent carries traceIdA, b3 carries traceIdB; W3C is listed first.
      let headers =
            [ (traceparentHeader, "00-" <> traceIdA <> "-" <> spanIdA <> "-01")
            , (b3Header, traceIdB <> "-" <> spanIdA <> "-1")
            ]
          context = extractContextFirst [w3cTraceContext, b3Single] headers
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
  , testCase "reordering the list reverses the winner" $ do
      let headers =
            [ (traceparentHeader, "00-" <> traceIdA <> "-" <> spanIdA <> "-01")
            , (b3Header, traceIdB <> "-" <> spanIdA <> "-1")
            ]
          context = extractContextFirst [b3Single, w3cTraceContext] headers
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "0af7651916cd43dd8448eb211c80319c"
  , testCase "an empty propagator list never matches" $
      extractContextFirst [] [(b3Header, traceIdB <> "-" <> spanIdA <> "-1")] @?= Nothing
  , testCase "no matching headers yield Nothing" $
      extractContextFirst [w3cTraceContext, b3Single, jaegerTraceContext] [] @?= Nothing
  ]

injectBaggageTests :: [TestTree]
injectBaggageTests =
  [ testCase "writes every configured baggage format" $ do
      let headers =
            runPureEff (runBaggage (withBaggageEntry "tenant" "acme" (injectBaggageAll [w3cBaggage, jaegerBaggage])))
          names = map fst headers
      assertBool "W3C baggage header present" (baggageHeader `elem` names)
      assertBool "uberctx- header present" ("uberctx-tenant" `elem` names)
  , testCase "an empty propagator list emits no headers" $ do
      let headers = runPureEff (runBaggage (withBaggageEntry "tenant" "acme" (injectBaggageAll [])))
      headers @?= []
  ]

extractBaggageTests :: [TestTree]
extractBaggageTests =
  [ testCase "merges entries from every format" $ do
      let headers =
            [ (baggageHeader, "fromw3c=1")
            , ("uberctx-fromjaeger", "2")
            ]
          merged = extractBaggageAll [w3cBaggage, jaegerBaggage] headers
      lookupBaggageValue "fromw3c" merged @?= Just "1"
      lookupBaggageValue "fromjaeger" merged @?= Just "2"
  , testCase "a later propagator wins on a shared key" $ do
      let headers =
            [ (baggageHeader, "shared=w3c")
            , ("uberctx-shared", "jaeger")
            ]
          merged = extractBaggageAll [w3cBaggage, jaegerBaggage] headers
      lookupBaggageValue "shared" merged @?= Just "jaeger"
  ]

tokenTests :: [TestTree]
tokenTests =
  [ testCase "trace-context tokens resolve to their propagators" $ do
      fmap traceContextName (traceContextByToken "tracecontext") @?= Just "tracecontext"
      fmap traceContextName (traceContextByToken "b3") @?= Just "b3"
      fmap traceContextName (traceContextByToken "b3multi") @?= Just "b3multi"
      fmap traceContextName (traceContextByToken "jaeger") @?= Just "jaeger"
  , testCase "an unknown or baggage-only token has no trace-context side" $ do
      fmap traceContextName (traceContextByToken "baggage") @?= Nothing
      fmap traceContextName (traceContextByToken "nonsense") @?= Nothing
  , testCase "baggage tokens resolve to their propagators" $ do
      fmap baggageName (baggageByToken "baggage") @?= Just "baggage"
      fmap baggageName (baggageByToken "jaeger") @?= Just "jaeger"
  , testCase "a trace-context-only token has no baggage side" $
      fmap baggageName (baggageByToken "b3") @?= Nothing
  , testCase "the standard values carry their expected tokens" $ do
      traceContextName w3cTraceContext @?= "tracecontext"
      traceContextName b3Single @?= "b3"
      traceContextName b3Multi @?= "b3multi"
      traceContextName jaegerTraceContext @?= "jaeger"
      baggageName w3cBaggage @?= "baggage"
      baggageName jaegerBaggage @?= "jaeger"
  ]

-- | Run a 'Tracer' computation through the in-memory interpreter, discarding the
-- captured spans and returning the computation's result.
run :: Eff '[Tracer, IOE] a -> IO a
run action = runEff $ do
  captured <- newCapturedSpans
  runTracerInMemory captured action
