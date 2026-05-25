{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.JaegerSpec
-- Description : Tests for Jaeger (uber-trace-id) propagation.
--
-- 'extractContextJaeger' is exercised directly with @uber-trace-id@ test vectors
-- (the parse is the whole contract for inbound requests), the injectors are
-- exercised through the in-memory interpreter and the baggage interpreter where
-- the ambient context exists, and round-trip tests confirm inject-then-extract
-- preserves the trace and span ids, the sampled flag, and the baggage entries.
module Effectful.Tracing.Propagation.JaegerSpec
  ( tests
  ) where

import Data.ByteString (ByteString)
import Data.Maybe (isJust)

import Effectful (Eff, IOE, runEff, runPureEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Baggage
  ( lookupBaggageValue
  , nullBaggage
  , runBaggage
  , withBaggageEntry
  )
import Effectful.Tracing.Internal.Ids (spanIdToHex, traceIdToHex)
import Effectful.Tracing.Internal.Types (SpanContext (..), isSampled)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Propagation.Jaeger
  ( extractBaggageJaeger
  , extractContextJaeger
  , injectBaggageJaeger
  , injectContextJaeger
  , uberTraceIdHeader
  )

tests :: TestTree
tests =
  testGroup
    "Propagation.Jaeger"
    [ testGroup "extractContextJaeger" extractVectors
    , testGroup "inject" injectTests
    , testGroup "extractBaggageJaeger" baggageVectors
    , testGroup "round-trip" roundTripTests
    ]

traceId128 :: ByteString
traceId128 = "4bf92f3577b34da6a3ce929d0e0e4736"

spanId :: ByteString
spanId = "00f067aa0ba902b7"

extractVectors :: [TestTree]
extractVectors =
  [ testCase "parses a 128-bit uber-trace-id with sampling" $ do
      let context = extractContextJaeger [(uberTraceIdHeader, traceId128 <> ":" <> spanId <> ":0:1")]
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
      fmap spanContextIsRemote context @?= Just True
  , testCase "left-pads leading-zero-stripped ids back to full width" $ do
      let context = extractContextJaeger [(uberTraceIdHeader, "a3ce929d0e0e4736:f067aa0ba902b7:0:1")]
      fmap (traceIdToHex . spanContextTraceId) context
        @?= Just "0000000000000000a3ce929d0e0e4736"
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
  , testCase "flags low bit clear parses as not sampled" $ do
      let context = extractContextJaeger [(uberTraceIdHeader, traceId128 <> ":" <> spanId <> ":0:0")]
      fmap (isSampled . spanContextTraceFlags) context @?= Just False
  , testCase "debug flag (3) still reads the sampled low bit" $ do
      let context = extractContextJaeger [(uberTraceIdHeader, traceId128 <> ":" <> spanId <> ":0:3")]
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
  , testCase "fewer than four fields yields Nothing" $
      extractContextJaeger [(uberTraceIdHeader, traceId128 <> ":" <> spanId <> ":1")] @?= Nothing
  , testCase "an all-zero trace id is rejected" $
      extractContextJaeger [(uberTraceIdHeader, "0:" <> spanId <> ":0:1")] @?= Nothing
  , testCase "a non-hex flags field is rejected" $
      extractContextJaeger [(uberTraceIdHeader, traceId128 <> ":" <> spanId <> ":0:z")] @?= Nothing
  , testCase "absent header yields Nothing" $
      extractContextJaeger [] @?= Nothing
  , testCase "the header lookup is case-insensitive" $ do
      let context = extractContextJaeger [("Uber-Trace-Id", traceId128 <> ":" <> spanId <> ":0:1")]
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
  ]

injectTests :: [TestTree]
injectTests =
  [ testCase "emits an uber-trace-id header for the active span" $ do
      headers <- run (withSpan "outbound" injectContextJaeger)
      assertBool "an uber-trace-id header is present" (uberTraceIdHeader `elem` map fst headers)
  , testCase "emits no header when there is no active span" $ do
      headers <- run injectContextJaeger
      headers @?= []
  , testCase "emits uberctx- headers for the ambient baggage" $ do
      let headers = runPureEff (runBaggage (withBaggageEntry "tenant" "acme" injectBaggageJaeger))
      headers @?= [("uberctx-tenant", "acme")]
  , testCase "emits no baggage headers when the baggage is empty" $ do
      let headers = runPureEff (runBaggage injectBaggageJaeger)
      headers @?= []
  ]

baggageVectors :: [TestTree]
baggageVectors =
  [ testCase "reads a uberctx- header" $
      lookupBaggageValue "tenant" (extractBaggageJaeger [("uberctx-tenant", "acme")]) @?= Just "acme"
  , testCase "the prefix match is case-insensitive" $
      lookupBaggageValue "tenant" (extractBaggageJaeger [("Uberctx-tenant", "acme")]) @?= Just "acme"
  , testCase "trims surrounding whitespace" $
      lookupBaggageValue "tenant" (extractBaggageJaeger [("uberctx-tenant", " acme ")]) @?= Just "acme"
  , testCase "ignores non-uberctx headers" $
      nullBaggage (extractBaggageJaeger [("x-other", "v")]) @?= True
  , testCase "skips an empty key" $
      nullBaggage (extractBaggageJaeger [("uberctx-", "v")]) @?= True
  ]

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "context inject then extract preserves ids and sampled flag" $ do
      headers <- run (withSpan "outbound" injectContextJaeger)
      let extracted = extractContextJaeger headers
      assertBool "round-trips to a context" (isJust extracted)
      fmap (isSampled . spanContextTraceFlags) extracted @?= Just True
      fmap spanContextIsRemote extracted @?= Just True
  , testCase "baggage inject then extract preserves entries" $ do
      let headers = runPureEff (runBaggage (withBaggageEntry "tenant" "acme" injectBaggageJaeger))
      lookupBaggageValue "tenant" (extractBaggageJaeger headers) @?= Just "acme"
  ]

-- | Run a 'Tracer' computation through the in-memory interpreter, discarding the
-- captured spans and returning the computation's result.
run :: Eff '[Tracer, IOE] a -> IO a
run action = runEff $ do
  captured <- newCapturedSpans
  runTracerInMemory captured action
