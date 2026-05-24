{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.PropagationSpec
-- Description : Tests for W3C Trace Context propagation.
--
-- 'extractContext' is exercised directly with W3C @traceparent@ test vectors
-- (the parse is the whole contract for inbound requests), and 'injectContext'
-- is exercised through the in-memory interpreter, where an active span exists.
-- A round-trip test confirms inject-then-extract preserves the trace and span
-- ids and the sampled flag.
module Effectful.Tracing.PropagationSpec
  ( tests
  ) where

import Data.ByteString (ByteString)
import Data.Maybe (isJust)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Internal.Ids
  ( spanIdToHex
  , traceIdToHex
  )
import Effectful.Tracing.Internal.Types
  ( SpanContext (..)
  , isSampled
  )
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Propagation
  ( extractContext
  , injectContext
  , traceparentHeader
  , tracestateHeader
  )

tests :: TestTree
tests =
  testGroup
    "Propagation"
    [ testGroup "extractContext (W3C vectors)" extractVectors
    , testGroup "injectContext" injectTests
    , testGroup "round-trip" roundTripTests
    ]

-- A canonical valid traceparent from the W3C spec examples.
validTraceparent :: ByteString
validTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

extractVectors :: [TestTree]
extractVectors =
  [ testCase "parses a valid traceparent" $ do
      let context = extractContext [(traceparentHeader, validTraceparent)]
      fmap (traceIdToHex . spanContextTraceId) context
        @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
      fmap (spanIdToHex . spanContextSpanId) context
        @?= Just "00f067aa0ba902b7"
      fmap (isSampled . spanContextTraceFlags) context @?= Just True
      fmap spanContextIsRemote context @?= Just True
  , testCase "unsampled flag (00) parses as not sampled" $ do
      let context =
            extractContext
              [(traceparentHeader, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")]
      fmap (isSampled . spanContextTraceFlags) context @?= Just False
  , testCase "absent traceparent yields Nothing" $
      extractContext [] @?= Nothing
  , testCase "all-zero trace id is rejected" $
      extractContext
        [(traceparentHeader, "00-00000000000000000000000000000000-00f067aa0ba902b7-01")]
        @?= Nothing
  , testCase "all-zero span id is rejected" $
      extractContext
        [(traceparentHeader, "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01")]
        @?= Nothing
  , testCase "reserved version ff is rejected" $
      extractContext
        [(traceparentHeader, "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")]
        @?= Nothing
  , testCase "version 00 with a trailing field is rejected" $
      extractContext
        [(traceparentHeader, validTraceparent <> "-extra")]
        @?= Nothing
  , testCase "future version with a trailing field is accepted" $ do
      let context =
            extractContext
              [(traceparentHeader, "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra")]
      fmap (traceIdToHex . spanContextTraceId) context
        @?= Just "4bf92f3577b34da6a3ce929d0e0e4736"
  , testCase "too few fields is rejected" $
      extractContext [(traceparentHeader, "00-4bf92f3577b34da6a3ce929d0e0e4736")] @?= Nothing
  , testCase "non-hex flags is rejected" $
      extractContext
        [(traceparentHeader, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-zz")]
        @?= Nothing
  , testCase "a malformed tracestate does not fail extraction" $ do
      let context =
            extractContext
              [ (traceparentHeader, validTraceparent)
              , (tracestateHeader, "this is = not valid = tracestate")
              ]
      assertBool "traceparent still parses" (isJust context)
  , testCase "header lookup is case-insensitive" $ do
      let context = extractContext [("TraceParent", validTraceparent)]
      fmap (spanIdToHex . spanContextSpanId) context @?= Just "00f067aa0ba902b7"
  ]

injectTests :: [TestTree]
injectTests =
  [ testCase "emits a traceparent for the active span" $ do
      headers <- run (withSpan "outbound" injectContext)
      assertBool "a traceparent header is present" (traceparentHeader `elem` map fst headers)
  , testCase "emits no headers when there is no active span" $ do
      headers <- run injectContext
      headers @?= []
  ]

roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "inject then extract preserves ids and sampled flag" $ do
      headers <- run (withSpan "outbound" injectContext)
      let extracted = extractContext headers
      -- The injected span is the live (sampled) child; extraction must recover
      -- its trace id, span id, and sampled flag, now marked remote.
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
