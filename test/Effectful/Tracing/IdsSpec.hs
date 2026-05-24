{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.IdsSpec
-- Description : Edge-case tests for the identifier hex codec and validity checks.
--
-- The round-trip property lives in "Effectful.Tracing.PropertySpec"; this file
-- pins the rejection and acceptance boundaries that round-trips never reach:
-- odd-length and non-hex input, wrong-length byte arrays, uppercase hex, the
-- all-zero sentinel, and lowercase rendering.
module Effectful.Tracing.IdsSpec
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing.Internal.Ids
  ( SpanId (SpanId)
  , TraceId (TraceId)
  , isValidSpanId
  , isValidTraceId
  , spanIdFromBytes
  , spanIdFromHex
  , traceIdFromBytes
  , traceIdFromHex
  , traceIdToHex
  )

tests :: TestTree
tests =
  testGroup
    "Identifiers"
    [ testGroup "hex parsing" hexTests
    , testGroup "byte construction" byteTests
    , testGroup "validity" validityTests
    ]

hexTests :: [TestTree]
hexTests =
  [ testCase "an odd-length string is rejected" $
      assertBool "odd length" (isNothing (traceIdFromHex (hexDigits 31)))
  , testCase "a too-short even-length string is rejected" $
      -- 30 hex chars decode to 15 bytes, one short of a trace id.
      assertBool "15 bytes" (isNothing (traceIdFromHex (hexDigits 30)))
  , testCase "a non-hex character is rejected" $
      assertBool "non-hex" (isNothing (traceIdFromHex "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
  , testCase "uppercase hex is accepted and renders back lowercase" $ do
      let upper = "4BF92F3577B34DA6A3CE929D0E0E4736"
          lower = "4bf92f3577b34da6a3ce929d0e0e4736"
      traceIdFromHex upper @?= traceIdFromHex lower
      fmap traceIdToHex (traceIdFromHex upper) @?= Just lower
  , testCase "a span id parses from exactly 16 hex characters" $
      assertBool "valid span hex" (isJust (spanIdFromHex "00f067aa0ba902b7"))
  , testCase "an odd-length span id string is rejected" $
      assertBool "odd span length" (isNothing (spanIdFromHex "00f067aa0ba902b"))
  ]

byteTests :: [TestTree]
byteTests =
  [ testCase "16 bytes makes a trace id" $
      assertBool "16 bytes" (isJust (traceIdFromBytes (BS.replicate 16 1)))
  , testCase "15 or 17 bytes is rejected as a trace id" $ do
      assertBool "15 bytes" (isNothing (traceIdFromBytes (BS.replicate 15 1)))
      assertBool "17 bytes" (isNothing (traceIdFromBytes (BS.replicate 17 1)))
  , testCase "8 bytes makes a span id" $
      assertBool "8 bytes" (isJust (spanIdFromBytes (BS.replicate 8 1)))
  , testCase "7 or 9 bytes is rejected as a span id" $ do
      assertBool "7 bytes" (isNothing (spanIdFromBytes (BS.replicate 7 1)))
      assertBool "9 bytes" (isNothing (spanIdFromBytes (BS.replicate 9 1)))
  ]

validityTests :: [TestTree]
validityTests =
  [ testCase "a correctly-sized but all-zero trace id is invalid" $
      isValidTraceId (TraceId (BS.replicate 16 0)) @?= False
  , testCase "a non-zero, correctly-sized trace id is valid" $
      isValidTraceId (TraceId (BS.replicate 16 1)) @?= True
  , testCase "a wrong-length trace id is invalid" $
      isValidTraceId (TraceId (BS.replicate 15 1)) @?= False
  , testCase "a correctly-sized but all-zero span id is invalid" $
      isValidSpanId (SpanId (BS.replicate 8 0)) @?= False
  , testCase "a non-zero, correctly-sized span id is valid" $
      isValidSpanId (SpanId (BS.replicate 8 1)) @?= True
  , testCase "a wrong-length span id is invalid" $
      isValidSpanId (SpanId (BS.replicate 7 1)) @?= False
  ]

-- | A string of @n@ copies of the hex digit @a@.
hexDigits :: Int -> Text
hexDigits n = T.replicate n "a"
