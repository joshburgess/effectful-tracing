{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.OpenTelemetrySpec
-- Description : Tests for the OpenTelemetry export interpreter.
--
-- Two angles. 'toImmutableSpan' is tested directly (the translation is the whole
-- contract: our ids, name, kind, status, and attributes must survive the
-- crossing into @hs-opentelemetry@'s representation). And 'runTracerOTel' is
-- tested end to end through a capturing 'SpanProcessor', confirming that a small
-- traced program drives well-formed spans, carrying our ids and parent linkage,
-- all the way to a processor. This is the runnable stand-in for the manual Jaeger
-- smoke test, which needs a live collector.
--
-- The processor is a synchronous one built straight from the @hs-opentelemetry@
-- API: it records each span in 'spanProcessorOnEnd' as the span finishes. The
-- SDK's @simpleProcessor@ exports on a worker thread whose shutdown races an
-- in-flight export, which drops spans nondeterministically; a synchronous
-- processor removes that race while exercising exactly the interface
-- 'runTracerOTel' drives.
module Effectful.Tracing.OpenTelemetrySpec
  ( tests
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.ByteString (ByteString)
import Data.IORef (readIORef)
import Data.List (find, nub, sort)
import Data.Maybe (isNothing)
import Data.Text qualified as T

import OpenTelemetry.Attributes qualified as OtelAttr
import OpenTelemetry.Processor.Span
  ( ShutdownResult (ShutdownSuccess)
  , SpanProcessor (..)
  )
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as OtelId

import Effectful (Eff, IOE, runEff, (:>))
import Hedgehog (Property, evalEither, evalIO, forAll, property, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing
  ( SpanArguments (kind)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , withSpan
  , withSpan'
  )
import Effectful.Tracing.Attribute (Attribute (attributeKey))
import Effectful.Tracing.Gen (genSpan)
import Effectful.Tracing.Internal.Ids (SpanId (SpanId), TraceId (TraceId))
import Effectful.Tracing.Internal.Types
  ( Span (..)
  , SpanContext (..)
  , SpanKind (Server)
  , SpanStatus (Error, Ok, Unset)
  )
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Interpreter.OpenTelemetry
  ( OtelConfig (OtelConfig, instrumentationScope, sampler, spanProcessors)
  , runTracerOTel
  , toImmutableSpan
  )
import Effectful.Tracing.Sampler (alwaysOn)

tests :: TestTree
tests =
  testGroup
    "OpenTelemetry"
    [ testGroup "toImmutableSpan" translationTests
    , testGroup "toImmutableSpan (property)" translationProperties
    , testGroup "runTracerOTel (end to end)" endToEndTests
    ]

-- A small traced program: a parent span with an attribute, wrapping a child.
program :: Tracer :> es => Eff es ()
program =
  withSpan "parent" $ do
    addAttribute "service.name" ("checkout" :: String)
    withSpan "child" (pure ())

translationTests :: [TestTree]
translationTests =
  [ testCase "preserves ids, name, status, and attributes" $ do
      spans <- runInMemory (withSpan "root" (addAttribute "k" ("v" :: String)))
      tracer <- makeTestTracer
      completed <- single spans
      case toImmutableSpan tracer completed of
        Left err -> fail ("translation failed: " <> err)
        Right immutable -> do
          OTel.spanName immutable @?= "root"
          let TraceId ourTrace = spanContextTraceId (spanContext completed)
              SpanId ourSpan = spanContextSpanId (spanContext completed)
          OtelId.traceIdBytes (OTel.traceId (OTel.spanContext immutable)) @?= ourTrace
          OtelId.spanIdBytes (OTel.spanId (OTel.spanContext immutable)) @?= ourSpan
          OTel.spanStatus immutable @?= OTel.Unset
          OtelAttr.getCount (OTel.spanAttributes immutable) @?= 1
  , testCase "maps span kind" $ do
      spans <- runInMemory (withSpan' "srv" defaultSpanArguments {kind = Server} (pure ()))
      tracer <- makeTestTracer
      completed <- single spans
      case toImmutableSpan tracer completed of
        Left err -> fail err
        Right immutable -> case OTel.spanKind immutable of
          OTel.Server -> pure ()
          other -> assertFailure ("expected Server kind, got " <> show other)
  ]

translationProperties :: [TestTree]
translationProperties =
  [ testProperty "preserves ids, name, kind, status, and attribute count" prop_translationPreserves
  ]

-- | For any generated span, the crossing into @hs-opentelemetry@ must be
-- lossless on the fields that identify and classify the span: our trace and
-- span id bytes, the name, the kind, the status, and the number of distinct
-- attribute keys. (The OTel attribute set is a keyed map, so the count it
-- reports is the number of distinct keys, which is what we compare against.)
prop_translationPreserves :: Property
prop_translationPreserves = property $ do
  completed <- forAll genSpan
  tracer <- evalIO makeTestTracer
  immutable <- evalEither (toImmutableSpan tracer completed)
  let TraceId ourTrace = spanContextTraceId (spanContext completed)
      SpanId ourSpan = spanContextSpanId (spanContext completed)
  OtelId.traceIdBytes (OTel.traceId (OTel.spanContext immutable)) === ourTrace
  OtelId.spanIdBytes (OTel.spanId (OTel.spanContext immutable)) === ourSpan
  OTel.spanName immutable === spanName completed
  -- Our 'SpanKind' and OpenTelemetry's share constructor names, so comparing
  -- their 'Show' output sidesteps the missing 'Eq' on OTel's 'SpanKind'.
  show (OTel.spanKind immutable) === show (spanKind completed)
  OTel.spanStatus immutable === expectedStatus (spanStatus completed)
  OtelAttr.getCount (OTel.spanAttributes immutable)
    === length (nub (map attributeKey (spanAttributes completed)))

-- | The expected OpenTelemetry status for one of ours.
expectedStatus :: SpanStatus -> OTel.SpanStatus
expectedStatus Unset = OTel.Unset
expectedStatus Ok = OTel.Ok
expectedStatus (Error message) = OTel.Error message

endToEndTests :: [TestTree]
endToEndTests =
  [ testCase "drives well-formed spans to a processor, parent linkage intact" $ do
      (processor, captured) <- capturingProcessor
      let config =
            OtelConfig
              { spanProcessors = [processor]
              , instrumentationScope = "effectful-tracing-test"
              , sampler = alwaysOn
              }
      runEff (runTracerOTel config program)
      exported <- readMVar captured

      sort (map (T.unpack . OTel.spanName) exported) @?= ["child", "parent"]
      parentSpan <- requireSpan "parent" exported
      childSpan <- requireSpan "child" exported

      -- Same trace.
      OtelId.traceIdBytes (OTel.traceId (OTel.spanContext childSpan))
        @?= OtelId.traceIdBytes (OTel.traceId (OTel.spanContext parentSpan))
      -- The child's parent is the parent span.
      childParent <- parentSpanId childSpan
      childParent @?= Just (OtelId.spanIdBytes (OTel.spanId (OTel.spanContext parentSpan)))
      -- The parent is a root (no parent of its own).
      assertBool "parent span is a root" (isNothing (OTel.spanParent parentSpan))
  ]

-- | A synchronous 'SpanProcessor' that records every span it sees in
-- 'spanProcessorOnEnd' into an 'MVar', in finish order.
capturingProcessor :: IO (SpanProcessor, MVar [OTel.ImmutableSpan])
capturingProcessor = do
  captured <- newMVar []
  let processor =
        SpanProcessor
          { spanProcessorOnStart = \_ _ -> pure ()
          , spanProcessorOnEnd = \ref -> do
              immutable <- readIORef ref
              modifyMVar_ captured (\acc -> pure (acc <> [immutable]))
          , spanProcessorShutdown = async (pure ShutdownSuccess)
          , spanProcessorForceFlush = pure ()
          }
  pure (processor, captured)

-- | The OTel span id of an immutable span's parent, if any.
parentSpanId :: OTel.ImmutableSpan -> IO (Maybe ByteString)
parentSpanId immutable =
  case OTel.spanParent immutable of
    Nothing -> pure Nothing
    Just p -> do
      context <- OTel.getSpanContext p
      pure (Just (OtelId.spanIdBytes (OTel.spanId context)))

requireSpan :: String -> [OTel.ImmutableSpan] -> IO OTel.ImmutableSpan
requireSpan name spans =
  maybe (fail ("no span named " <> name)) pure (find ((== name) . T.unpack . OTel.spanName) spans)

-- | Build an OTel tracer with no processors, just to satisfy translation.
makeTestTracer :: IO OTel.Tracer
makeTestTracer = do
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  pure (OTel.makeTracer provider "effectful-tracing-test" OTel.tracerOptions)

single :: [a] -> IO a
single [x] = pure x
single other = fail ("expected exactly one span, got " <> show (length other))

runInMemory :: Eff '[Tracer, IOE] a -> IO [Span]
runInMemory action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemory captured action
  readCapturedSpans captured
