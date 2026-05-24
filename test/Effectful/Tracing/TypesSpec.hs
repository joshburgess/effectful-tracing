{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.TypesSpec
-- Description : Unit and property tests for the pure span data model.
--
-- These cover the small total functions that the interpreters lean on but never
-- exercise in isolation: the OpenTelemetry status-transition rules, the W3C
-- trace-state insert/lookup invariants (dedup, capacity, key and value
-- validation), the @tracestate@ header parser's resilience, and the trace-flags
-- bit manipulation.
module Effectful.Tracing.TypesSpec
  ( tests
  ) where

import Data.Bits (testBit)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text qualified as T
import Data.Word (Word8)

import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing.Effect (transitionStatus)
import Effectful.Tracing.Internal.Types
  ( SpanStatus (Error, Ok, Unset)
  , TraceFlags (TraceFlags)
  , defaultTraceFlags
  , emptyTraceState
  , insertTraceState
  , isSampled
  , lookupTraceState
  , maxTraceStateEntries
  , setSampled
  , traceStateEntries
  , traceStateFromHeader
  )

tests :: TestTree
tests =
  testGroup
    "Pure data model"
    [ testGroup "transitionStatus" transitionTests
    , testGroup "trace state" traceStateTests
    , testGroup "trace flags" traceFlagsTests
    ]

transitionTests :: [TestTree]
transitionTests =
  [ testCase "Unset moves to Ok or Error" $ do
      transitionStatus Unset Ok @?= Ok
      transitionStatus Unset (Error "boom") @?= Error "boom"
  , testCase "Error is overridden by Ok" $
      transitionStatus (Error "boom") Ok @?= Ok
  , testCase "Error is overridden by a later Error" $
      transitionStatus (Error "first") (Error "second") @?= Error "second"
  , testCase "Ok is terminal and ignores later transitions" $ do
      transitionStatus Ok (Error "boom") @?= Ok
      transitionStatus Ok Unset @?= Ok
      transitionStatus Ok Ok @?= Ok
  , testCase "a proposed Unset never downgrades the current status" $ do
      transitionStatus (Error "boom") Unset @?= Error "boom"
      transitionStatus Unset Unset @?= Unset
  , testProperty "Ok absorbs every proposed status" prop_okAbsorbs
  , testProperty "the result is Unset only when both inputs are Unset" prop_neverDowngradesToUnset
  ]

prop_okAbsorbs :: Property
prop_okAbsorbs = property $ do
  proposed <- forAll genStatus
  transitionStatus Ok proposed === Ok

prop_neverDowngradesToUnset :: Property
prop_neverDowngradesToUnset = property $ do
  current <- forAll genStatus
  proposed <- forAll genStatus
  (transitionStatus current proposed == Unset)
    === (current == Unset && proposed == Unset)

genStatus :: Gen SpanStatus
genStatus =
  Gen.choice [pure Unset, pure Ok, Error <$> Gen.text (Range.linear 0 12) Gen.alphaNum]

traceStateTests :: [TestTree]
traceStateTests =
  [ testCase "insert then lookup returns the value" $ do
      let st = insert "vendor" "value" emptyTraceState
      lookupTraceState "vendor" st @?= Just "value"
  , testCase "an inserted key is at the head (most recent)" $ do
      let st = insert "b" "2" (insert "a" "1" emptyTraceState)
      fmap fst (take 1 (traceStateEntries st)) @?= ["b"]
  , testCase "re-inserting a key dedupes and moves it to the head" $ do
      let st = insert "a" "v2" (insert "c" "3" (insert "a" "v1" emptyTraceState))
      traceStateEntries st @?= [("a", "v2"), ("c", "3")]
  , testCase "rejects an empty key" $
      assertBool "empty key" (isNothing (insertTraceState "" "v" emptyTraceState))
  , testCase "rejects an uppercase key" $
      assertBool "uppercase key" (isNothing (insertTraceState "Vendor" "v" emptyTraceState))
  , testCase "rejects an empty value" $
      assertBool "empty value" (isNothing (insertTraceState "k" "" emptyTraceState))
  , testCase "rejects a value containing a comma" $
      assertBool "comma value" (isNothing (insertTraceState "k" "a,b" emptyTraceState))
  , testCase "rejects a value containing an equals sign" $
      assertBool "equals value" (isNothing (insertTraceState "k" "a=b" emptyTraceState))
  , testCase "rejects a new key once the entry cap is reached" $
      assertBool "over capacity" (isNothing (insertTraceState "overflow" "v" fullState))
  , testCase "updates an existing key even at the entry cap" $ do
      -- key0 already exists, so the update removes it before inserting and stays
      -- within the cap.
      let updated = insertTraceState "key0" "fresh" fullState
      fmap (lookupTraceState "key0") updated @?= Just (Just "fresh")
  , testCase "the parser drops malformed members but keeps valid ones" $
      traceStateEntries (traceStateFromHeader "foo=bar,this is junk,baz=qux")
        @?= [("foo", "bar"), ("baz", "qux")]
  , testCase "the parser keeps the first occurrence of a duplicate key" $
      traceStateEntries (traceStateFromHeader "k=1,k=2") @?= [("k", "1")]
  ]
  where
    insert k v st = fromMaybe st (insertTraceState k v st)
    -- A trace state filled to exactly the entry cap, keys key0..key31.
    fullState =
      foldl'
        (\st n -> insert ("key" <> tShow n) (tShow n) st)
        emptyTraceState
        [0 .. maxTraceStateEntries - 1]
    tShow = T.pack . show

traceFlagsTests :: [TestTree]
traceFlagsTests =
  [ testCase "default flags are not sampled" $
      isSampled defaultTraceFlags @?= False
  , testCase "setSampled True then False round-trips the sampled bit" $ do
      isSampled (setSampled True defaultTraceFlags) @?= True
      isSampled (setSampled False (setSampled True defaultTraceFlags)) @?= False
  , testProperty "setSampled toggles only bit 0, preserving the reserved bits" prop_setSampledReservedBits
  ]

prop_setSampledReservedBits :: Property
prop_setSampledReservedBits = property $ do
  w <- forAll (Gen.word8 Range.constantBounded)
  b <- forAll Gen.bool
  let TraceFlags w' = setSampled b (TraceFlags w)
  -- bit 0 reflects the request; bits 1..7 are untouched.
  testBit w' 0 === b
  reservedBits w' === reservedBits w

-- | Bits 1 through 7 of a flags byte (everything but the sampled bit).
reservedBits :: Word8 -> [Bool]
reservedBits w = [testBit w i | i <- [1 .. 7]]
