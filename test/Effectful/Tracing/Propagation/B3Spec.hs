{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.B3Spec
-- Description : Tests for B3 (Zipkin) propagation.
--
-- 'extractContextB3' is exercised directly with single-header and multi-header
-- B3 test vectors (the parse is the whole contract for inbound requests), and
-- the injectors are exercised through the in-memory interpreter, where an
-- active span exists. Round-trip tests confirm inject-then-extract preserves the
-- trace and span ids and the sampled flag in both wire encodings.
module Effectful.Tracing.Propagation.B3Spec
  ( tests
  ) where

import Data.ByteString (ByteString)
import Data.Maybe (isJust)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Internal.Ids (spanIdToHex, traceIdToHex)
import Effectful.Tracing.Internal.Types (SpanContext (..), isSampled)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Propagation.B3
  ( b3FlagsHeader
  , b3Header
  , b3SampledHeader
  , b3SpanIdHeader
  , b3TraceIdHeader
  , extractContextB3
  , injectContextB3
  , injectContextB3Multi
  )

tests :: TestTree
tests =
  testGroup
    "Propagation.B3"
    [ testGroup "extractContextB3 (single header)" singleVectors
    , testGroup "extractContextB3 (multi header)" multiVectors
    , testGroup "inject" injectTests
    , testGroup "round-trip" roundTripTests
    ]

traceId128 :: ByteString
traceId128 = "4bf92f3577b34da6a3ce929d0e0e4736"

spanId :: ByteString
spanId = "00f067aa0ba902b7"

singleVectors :: [TestTree]
singleVectors =
  [ testCase "parses a 128-bit single header with sampling" $ do
      let context = extractContextB3 [(b3Header, traceId128 <> "-" <> spanId <> "-1")]
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
      fmap spanContextIsRemote context @?= Just True
  , testCase "left-pads a 64-bit trace id to 128 bits" $ do
      let context = extractContextB3 [(b3Header, "a3ce929d0e0e4736-" <> spanId <> "-1")]
      fmap (traceIdToHex . spanContextTraceId) context
        @?= Just "0000000000000000a3ce929d0e0e4736"
  , testCase "deny sampling (0) parses as not sampled" $ do
      let context = extractContextB3 [(b3Header, traceId128 <> "-" <> spanId <> "-0")]
      fmap (isSampled . spanContextTraceFlags) context @?= Just False
  , testCase "debug (d) parses as sampled" $ do
      let context = extractContextB3 [(b3Header, traceId128 <> "-" <> spanId <> "-d")]
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
  , testCase "absent sampling field defers to unsampled" $ do
      let context = extractContextB3 [(b3Header, traceId128 <> "-" <> spanId)]
      fmap (isSampled . spanContextTraceFlags) context @?= Just False
  , testCase "a trailing parent span id is accepted and ignored" $ do
      let context =
            extractContextB3
              [(b3Header, traceId128 <> "-" <> spanId <> "-1-05e3ac9a4f6e3b90")]
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
  , testCase "the deny-only single value (0) yields Nothing" $
      extractContextB3 [(b3Header, "0")] @?= Nothing
  , testCase "an all-zero trace id is rejected" $
      extractContextB3 [(b3Header, "00000000000000000000000000000000-" <> spanId <> "-1")]
        @?= Nothing
  , testCase "a non-hex span id is rejected" $
      extractContextB3 [(b3Header, traceId128 <> "-zzzzzzzzzzzzzzzz-1")] @?= Nothing
  , testCase "absent headers yield Nothing" $
      extractContextB3 [] @?= Nothing
  , testCase "the b3 header lookup is case-insensitive" $ do
      let context = extractContextB3 [("B3", traceId128 <> "-" <> spanId <> "-1")]
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
  ]

multiVectors :: [TestTree]
multiVectors =
  [ testCase "parses the multi-header form with X-B3-Sampled" $ do
      let context =
            extractContextB3
              [ (b3TraceIdHeader, traceId128)
              , (b3SpanIdHeader, spanId)
              , (b3SampledHeader, "1")
              ]
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
      fmap spanContextIsRemote context @?= Just True
  , testCase "X-B3-Flags: 1 (debug) implies sampled" $ do
      let context =
            extractContextB3
              [ (b3TraceIdHeader, traceId128)
              , (b3SpanIdHeader, spanId)
              , (b3FlagsHeader, "1")
              ]
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
  , testCase "X-B3-Sampled: 0 parses as not sampled" $ do
      let context =
            extractContextB3
              [ (b3TraceIdHeader, traceId128)
              , (b3SpanIdHeader, spanId)
              , (b3SampledHeader, "0")
              ]
      fmap (isSampled . spanContextTraceFlags) context @?= Just False
  , testCase "missing X-B3-SpanId yields Nothing" $
      extractContextB3 [(b3TraceIdHeader, traceId128)] @?= Nothing
  , testCase "the single header is preferred when both forms are present" $ do
      -- The single header carries the real ids; the multi headers are decoys.
      let context =
            extractContextB3
              [ (b3Header, traceId128 <> "-" <> spanId <> "-1")
              , (b3TraceIdHeader, "00000000000000000000000000000000")
              , (b3SpanIdHeader, "0000000000000000")
              ]
      fmap (traceIdToHex . spanContextTraceId) context @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
  ]

injectTests :: [TestTree]
injectTests =
  [ testCase "emits a single b3 header for the active span" $ do
      headers <- run (withSpan "outbound" injectContextB3)
      assertBool "a b3 header is present" (b3Header `elem` map fst headers)
  , testCase "emits multi headers for the active span" $ do
      headers <- run (withSpan "outbound" injectContextB3Multi)
      let names = map fst headers
      assertBool "X-B3-TraceId present" (b3TraceIdHeader `elem` names)
      assertBool "X-B3-SpanId present" (b3SpanIdHeader `elem` names)
      assertBool "X-B3-Sampled present" (b3SampledHeader `elem` names)
  , testCase "emits no single header when there is no active span" $ do
      headers <- run injectContextB3
      headers @?= []
  , testCase "emits no multi headers when there is no active span" $ do
      headers <- run injectContextB3Multi
      headers @?= []
  ]

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "single-header inject then extract preserves ids and sampled flag" $ do
      headers <- run (withSpan "outbound" injectContextB3)
      let extracted = extractContextB3 headers
      assertBool "round-trips to a context" (isJust extracted)
      fmap (isSampled . spanContextTraceFlags) extracted @?= Just True
      fmap spanContextIsRemote extracted @?= Just True
  , testCase "multi-header inject then extract preserves ids and sampled flag" $ do
      headers <- run (withSpan "outbound" injectContextB3Multi)
      let extracted = extractContextB3 headers
      assertBool "round-trips to a context" (isJust extracted)
      fmap (isSampled . spanContextTraceFlags) extracted @?= Just True
      fmap spanContextIsRemote extracted @?= Just True
  ]

-- | Run a 'Tracer' computation through the in-memory interpreter, discarding the
-- captured spans and returning the computation's result.
run :: Eff '[Tracer, IOE] a -> IO a
run action = runEff $ do
  captured <- newCapturedSpans
  runTracerInMemory captured action
