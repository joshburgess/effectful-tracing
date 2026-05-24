{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Effectful.Tracing.PropertySpec
-- Description : Hedgehog property tests for the core data model.
module Effectful.Tracing.PropertySpec
  ( tests
  ) where

import Data.Int (Int64)

import Hedgehog (Gen, Property, assert, evalIO, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing.Attribute (AttributeValue (..), toAttributeValue)
import Effectful.Tracing.Internal.Ids
  ( isValidSpanId
  , isValidTraceId
  , newSpanId
  , newTraceId
  , spanIdFromHex
  , spanIdToHex
  , traceIdFromHex
  , traceIdToHex
  )
import Effectful.Tracing.Internal.Types
  ( maxTraceStateEntries
  , spanEndTime
  , spanStartTime
  , traceStateEntries
  , traceStateFromHeader
  , traceStateToHeader
  )

import Effectful.Tracing.Gen
  ( genSpan
  , genSpanId
  , genTraceId
  , genTraceState
  )

tests :: TestTree
tests =
  testGroup
    "Phase 1 data model"
    [ testProperty "TraceId hex round-trips" prop_traceIdHexRoundTrip
    , testProperty "SpanId hex round-trips" prop_spanIdHexRoundTrip
    , testProperty "generated TraceId is valid" prop_generatedTraceIdValid
    , testProperty "generated SpanId is valid" prop_generatedSpanIdValid
    , testProperty "TraceState header round-trips" prop_traceStateRoundTrip
    , testProperty "TraceState respects the entry cap" prop_traceStateCap
    , testProperty "Int64 coerces to AttrInt" prop_int64Coercion
    , testProperty "Int widens to AttrInt" prop_intWidening
    , testProperty "Bool coerces to AttrBool" prop_boolCoercion
    , testProperty "span start precedes end" prop_spanStartLeEnd
    ]

prop_traceIdHexRoundTrip :: Property
prop_traceIdHexRoundTrip = property $ do
  tid <- forAll genTraceId
  traceIdFromHex (traceIdToHex tid) === Just tid

prop_spanIdHexRoundTrip :: Property
prop_spanIdHexRoundTrip = property $ do
  sid <- forAll genSpanId
  spanIdFromHex (spanIdToHex sid) === Just sid

prop_generatedTraceIdValid :: Property
prop_generatedTraceIdValid = property $ do
  tid <- evalIO newTraceId
  assert (isValidTraceId tid)

prop_generatedSpanIdValid :: Property
prop_generatedSpanIdValid = property $ do
  sid <- evalIO newSpanId
  assert (isValidSpanId sid)

prop_traceStateRoundTrip :: Property
prop_traceStateRoundTrip = property $ do
  st <- forAll genTraceState
  traceStateFromHeader (traceStateToHeader st) === st

prop_traceStateCap :: Property
prop_traceStateCap = property $ do
  st <- forAll genTraceState
  assert (length (traceStateEntries st) <= maxTraceStateEntries)

prop_int64Coercion :: Property
prop_int64Coercion = property $ do
  n <- forAll (Gen.integral (Range.linearFrom 0 minBound maxBound) :: Gen Int64)
  toAttributeValue n === AttrInt n

prop_intWidening :: Property
prop_intWidening = property $ do
  n <- forAll (Gen.integral (Range.linearFrom 0 minBound maxBound) :: Gen Int)
  toAttributeValue n === AttrInt (fromIntegral n)

prop_boolCoercion :: Property
prop_boolCoercion = property $ do
  b <- forAll Gen.bool
  toAttributeValue b === AttrBool b

prop_spanStartLeEnd :: Property
prop_spanStartLeEnd = property $ do
  s <- forAll genSpan
  assert (spanStartTime s <= spanEndTime s)
