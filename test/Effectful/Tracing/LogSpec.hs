{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.LogSpec
-- Description : Tests for log correlation against the active span.
--
-- The accessors are exercised through the in-memory interpreter, where an active
-- span exists, and compared against the captured span's own context so the
-- correlation is verified to name the right trace and span (not just any
-- well-formed ids). The no-active-span cases assert the clean empty / 'Nothing'
-- result.
module Effectful.Tracing.LogSpec
  ( tests
  ) where

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Internal.Ids (spanIdToHex, traceIdToHex)
import Effectful.Tracing.Internal.Types (Span, SpanContext (..), isSampled, spanContext)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Log
  ( Correlation (..)
  , activeCorrelation
  , activeCorrelationFields
  , activeSpanId
  , activeTraceId
  , correlationFields
  )

tests :: TestTree
tests =
  testGroup
    "Log"
    [ testCase "active correlation names the active span" $ do
        (correlation, spans) <- run (withSpan "op" activeCorrelation)
        case spans of
          [s] ->
            correlation
              @?= Just
                Correlation
                  { correlationTraceId = traceIdToHex (spanContextTraceId (spanContext s))
                  , correlationSpanId = spanIdToHex (spanContextSpanId (spanContext s))
                  , correlationSampled = isSampled (spanContextTraceFlags (spanContext s))
                  }
          other -> fail ("expected exactly one captured span, got " <> show (length other))
    , testCase "active ids match the correlation" $ do
        ((tid, sid, correlation), _) <-
          run (withSpan "op" ((,,) <$> activeTraceId <*> activeSpanId <*> activeCorrelation))
        tid @?= fmap correlationTraceId correlation
        sid @?= fmap correlationSpanId correlation
    , testCase "nested spans share the trace id but differ in span id" $ do
        ((outer, inner), _) <-
          run $
            withSpan "outer" $ do
              o <- activeCorrelation
              i <- withSpan "inner" activeCorrelation
              pure (o, i)
        fmap correlationTraceId outer @?= fmap correlationTraceId inner
        (fmap correlationSpanId outer == fmap correlationSpanId inner) @?= False
    , testCase "fields use the OpenTelemetry log keys" $ do
        let correlation = Correlation "abc" "def" True
        map fst (correlationFields correlation) @?= ["trace_id", "span_id", "trace_flags"]
        lookup "trace_flags" (correlationFields correlation) @?= Just "01"
    , testCase "unsampled renders trace_flags 00" $
        lookup "trace_flags" (correlationFields (Correlation "abc" "def" False)) @?= Just "00"
    , testCase "no active span yields Nothing" $ do
        (correlation, _) <- run activeCorrelation
        correlation @?= Nothing
    , testCase "no active span yields no fields" $ do
        (fields, _) <- run activeCorrelationFields
        fields @?= []
    ]

-- | Run a 'Tracer' computation through the in-memory interpreter, returning both
-- the computation's result and the captured spans.
run :: Eff '[Tracer, IOE] a -> IO (a, [Span])
run action = runEff $ do
  captured <- newCapturedSpans
  result <- runTracerInMemory captured action
  spans <- readCapturedSpans captured
  pure (result, spans)
