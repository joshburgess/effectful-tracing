{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.SamplerSpec
-- Description : Tests for the built-in samplers and their interpreter integration.
--
-- The samplers are tested directly through 'shouldSample' (the decision is the
-- whole contract), and the in-memory interpreter is used to confirm that a
-- 'Drop' omits a span, that 'RecordOnly' captures without setting the sampled
-- flag, and that 'RecordAndSample' captures and flags.
module Effectful.Tracing.SamplerSpec
  ( tests
  ) where

import Control.Monad (replicateM)
import Data.Maybe (fromMaybe)

import Effectful (Eff, IOE, runEff)
import Hedgehog (Property, evalIO, forAll, property, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Gen (genTraceId)
import Effectful.Tracing.Internal.Ids
  ( SpanId
  , TraceId
  , newTraceId
  , spanIdFromHex
  , traceIdFromHex
  )
import Effectful.Tracing.Internal.Types
  ( Span (spanContext)
  , SpanContext (..)
  , SpanKind (Internal)
  , defaultTraceFlags
  , emptyTraceState
  , isSampled
  , setSampled
  )
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemoryWith
  )
import Effectful.Tracing.Sampler
  ( Sampler (Sampler, shouldSample)
  , SamplerInput (SamplerInput)
  , SamplingDecision (Drop, RecordAndSample, RecordOnly)
  , SamplingResult (decision)
  , alwaysOff
  , alwaysOn
  , defaultParentBasedConfig
  , parentBased
  , simpleResult
  , traceIdRatioBased
  )

tests :: TestTree
tests =
  testGroup
    "Sampling"
    [ testGroup
        "built-in decisions"
        [ testCase "alwaysOn records and samples; alwaysOff drops" $ do
            decisionOf alwaysOn (input Nothing) >>= (@?= RecordAndSample)
            decisionOf alwaysOff (input Nothing) >>= (@?= Drop)
        , testProperty "traceIdRatioBased 1.0 always samples" prop_ratioOneSamples
        , testProperty "traceIdRatioBased 0.0 never samples" prop_ratioZeroDrops
        , testProperty "traceIdRatioBased is deterministic per trace id" prop_ratioDeterministic
        , testCase "traceIdRatioBased 0.5 samples about half of many trace ids" $ do
            ids <- replicateM sampleCount newTraceId
            let half = traceIdRatioBased 0.5
            sampled <-
              length . filter (== RecordAndSample)
                <$> traverse (decisionOf half . inputFor Nothing) ids
            let fraction = fromIntegral sampled / fromIntegral sampleCount :: Double
            assertBool
              ("sampled fraction " <> show fraction <> " should be near 0.5")
              (abs (fraction - 0.5) < 0.03)
        , testCase "parentBased follows the parent and falls back to the root" $ do
            -- root is alwaysOff, so a sampled parent decision can only come from
            -- inheritance, not the root sampler.
            let s = parentBased (defaultParentBasedConfig alwaysOff)
            decisionOf s (input Nothing) >>= (@?= Drop)
            decisionOf s (input (Just (parentContext True False))) >>= (@?= RecordAndSample)
            decisionOf s (input (Just (parentContext False False))) >>= (@?= Drop)
            decisionOf s (input (Just (parentContext True True))) >>= (@?= RecordAndSample)
            decisionOf s (input (Just (parentContext False True))) >>= (@?= Drop)
        ]
    , testGroup
        "interpreter integration"
        [ testCase "alwaysOff captures no spans" $ do
            spans <- captureWith alwaysOff twoSpans
            spans @?= []
        , testCase "traceIdRatioBased 0.0 captures no spans" $ do
            spans <- captureWith (traceIdRatioBased 0.0) twoSpans
            spans @?= []
        , testCase "alwaysOn captures every span and flags it sampled" $ do
            spans <- captureWith alwaysOn twoSpans
            length spans @?= 2
            assertBool "every captured span is flagged sampled" (all sampledFlag spans)
        , testCase "RecordOnly captures spans but does not flag them sampled" $ do
            spans <- captureWith recordOnly twoSpans
            length spans @?= 2
            assertBool "no captured span is flagged sampled" (not (any sampledFlag spans))
        ]
    ]

-- Properties ----------------------------------------------------------------

prop_ratioOneSamples :: Property
prop_ratioOneSamples = property $ do
  t <- forAll genTraceId
  d <- evalIO (decisionOf (traceIdRatioBased 1.0) (inputFor Nothing t))
  d === RecordAndSample

prop_ratioZeroDrops :: Property
prop_ratioZeroDrops = property $ do
  t <- forAll genTraceId
  d <- evalIO (decisionOf (traceIdRatioBased 0.0) (inputFor Nothing t))
  d === Drop

prop_ratioDeterministic :: Property
prop_ratioDeterministic = property $ do
  t <- forAll genTraceId
  let s = traceIdRatioBased 0.37
  d1 <- evalIO (decisionOf s (inputFor Nothing t))
  d2 <- evalIO (decisionOf s (inputFor Nothing t))
  d1 === d2

-- Programs and interpreter helpers ------------------------------------------

twoSpans :: Eff '[Tracer, IOE] ()
twoSpans = withSpan "outer" (withSpan "inner" (pure ()))

captureWith :: Sampler -> Eff '[Tracer, IOE] () -> IO [Span]
captureWith sampler prog = do
  captured <- runEff newCapturedSpans
  runEff (runTracerInMemoryWith sampler captured prog)
  runEff (readCapturedSpans captured)

recordOnly :: Sampler
recordOnly = Sampler "RecordOnly" (\_ -> pure (simpleResult RecordOnly))

sampledFlag :: Span -> Bool
sampledFlag = isSampled . spanContextTraceFlags . spanContext

-- Sampler helpers -----------------------------------------------------------

sampleCount :: Int
sampleCount = 20000

decisionOf :: Sampler -> SamplerInput -> IO SamplingDecision
decisionOf sampler = fmap decision . shouldSample sampler

input :: Maybe SpanContext -> SamplerInput
input parent = inputFor parent fixedTraceId

inputFor :: Maybe SpanContext -> TraceId -> SamplerInput
inputFor parent traceId = SamplerInput parent traceId "op" Internal [] []

parentContext :: Bool -> Bool -> SpanContext
parentContext sampled remote =
  SpanContext
    { spanContextTraceId = fixedTraceId
    , spanContextSpanId = fixedSpanId
    , spanContextTraceFlags = setSampled sampled defaultTraceFlags
    , spanContextTraceState = emptyTraceState
    , spanContextIsRemote = remote
    }

fixedTraceId :: TraceId
fixedTraceId = unsafeHex traceIdFromHex "4f1a9c000000000000000000000000aa"

fixedSpanId :: SpanId
fixedSpanId = unsafeHex spanIdFromHex "0000000000000001"

unsafeHex :: (t -> Maybe a) -> t -> a
unsafeHex parse raw = fromMaybe (error "bad fixture id") (parse raw)
