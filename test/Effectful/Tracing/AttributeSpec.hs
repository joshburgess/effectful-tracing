{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.AttributeSpec
-- Description : Tests for the 'ToAttributeValue' conversions and '(.=)'.
--
-- One conversion per instance: scalars map to the matching scalar variant,
-- 'Int' and 'Float' widen to their 64-bit representations, and both list and
-- 'Vector' inputs land on the homogeneous-array variants. '(.=)' is the
-- key/value sugar over 'toAttributeValue'.
module Effectful.Tracing.AttributeSpec
  ( tests
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Vector qualified as V

import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing.Attribute
  ( Attribute (Attribute)
  , AttributeValue (..)
  , toAttributeValue
  , (.=)
  )

tests :: TestTree
tests =
  testGroup
    "Attribute conversions"
    [ testGroup "scalars" scalarTests
    , testGroup "arrays" arrayTests
    , testGroup "(.=) and identity" sugarTests
    , testGroup "numeric widening" wideningProperties
    ]

scalarTests :: [TestTree]
scalarTests =
  [ testCase "Text maps to AttrText" $
      toAttributeValue ("hello" :: Text) @?= AttrText "hello"
  , testCase "String maps to AttrText" $
      toAttributeValue ("hello" :: String) @?= AttrText "hello"
  , testCase "Bool maps to AttrBool" $
      toAttributeValue True @?= AttrBool True
  , testCase "Int64 maps to AttrInt" $
      toAttributeValue (7 :: Int64) @?= AttrInt 7
  , testCase "Double maps to AttrDouble" $
      toAttributeValue (1.5 :: Double) @?= AttrDouble 1.5
  , testCase "Float widens to AttrDouble" $
      toAttributeValue (0.5 :: Float) @?= AttrDouble 0.5
  ]

arrayTests :: [TestTree]
arrayTests =
  [ testCase "[Text] maps to AttrTextArray" $
      toAttributeValue (["a", "b"] :: [Text]) @?= AttrTextArray (V.fromList ["a", "b"])
  , testCase "[Bool] maps to AttrBoolArray" $
      toAttributeValue [True, False] @?= AttrBoolArray (V.fromList [True, False])
  , testCase "[Int64] maps to AttrIntArray" $
      toAttributeValue ([1, 2] :: [Int64]) @?= AttrIntArray (V.fromList [1, 2])
  , testCase "[Int] widens to AttrIntArray" $
      toAttributeValue ([1, 2] :: [Int]) @?= AttrIntArray (V.fromList [1, 2])
  , testCase "[Double] maps to AttrDoubleArray" $
      toAttributeValue ([1.5, 2.5] :: [Double]) @?= AttrDoubleArray (V.fromList [1.5, 2.5])
  , testCase "[Float] widens to AttrDoubleArray" $
      toAttributeValue ([0.5, 1.5] :: [Float]) @?= AttrDoubleArray (V.fromList [0.5, 1.5])
  , testCase "Vector Text maps to AttrTextArray" $
      toAttributeValue (V.fromList ["a"] :: V.Vector Text) @?= AttrTextArray (V.fromList ["a"])
  , testCase "Vector Bool maps to AttrBoolArray" $
      toAttributeValue (V.fromList [True]) @?= AttrBoolArray (V.fromList [True])
  , testCase "Vector Int64 maps to AttrIntArray" $
      toAttributeValue (V.fromList [9] :: V.Vector Int64) @?= AttrIntArray (V.fromList [9])
  , testCase "Vector Double maps to AttrDoubleArray" $
      toAttributeValue (V.fromList [9.5] :: V.Vector Double) @?= AttrDoubleArray (V.fromList [9.5])
  ]

sugarTests :: [TestTree]
sugarTests =
  [ testCase "AttributeValue maps to itself (identity instance)" $
      toAttributeValue (AttrInt 3) @?= AttrInt 3
  , testCase "(.=) pairs the key with the converted value" $
      ("http.status_code" .= (200 :: Int)) @?= Attribute "http.status_code" (AttrInt 200)
  ]

wideningProperties :: [TestTree]
wideningProperties =
  [ testProperty "Int widens to AttrInt by fromIntegral" prop_intWidening
  , testProperty "Float widens to AttrDouble by realToFrac" prop_floatWidening
  ]

prop_intWidening :: Property
prop_intWidening = property $ do
  n <- forAll (Gen.integral (Range.linearFrom 0 minBound maxBound) :: Gen Int)
  toAttributeValue n === AttrInt (fromIntegral n)

prop_floatWidening :: Property
prop_floatWidening = property $ do
  f <- forAll (Gen.float (Range.linearFracFrom 0 (-1.0e6) 1.0e6))
  toAttributeValue f === AttrDouble (realToFrac f)
