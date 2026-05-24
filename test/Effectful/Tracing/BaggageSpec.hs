{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.BaggageSpec
-- Description : Tests for the baggage value, the ambient effect, and the codec.
--
-- Three areas: the pure 'Baggage' operations (insert / lookup / delete / list),
-- the ambient 'BaggageContext' effect (reading the in-scope baggage and the
-- lexical scoping of 'withBaggageEntry' / 'localBaggage'), and the W3C @baggage@
-- header codec (render / parse, percent-encoding, metadata, whitespace, the
-- entry cap, and skipping malformed members), including 'injectBaggage' /
-- 'extractBaggage' round-trips.
module Effectful.Tracing.BaggageSpec
  ( tests
  ) where

import Data.Text qualified as T

import Effectful (Eff, runPureEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing.Baggage
  ( BaggageContext
  , BaggageEntry (BaggageEntry)
  , baggageFromList
  , baggageSize
  , baggageToList
  , deleteBaggage
  , emptyBaggage
  , getBaggage
  , insertBaggage
  , lookupBaggage
  , lookupBaggageValue
  , localBaggage
  , nullBaggage
  , runBaggage
  , runBaggageWith
  , withBaggageEntry
  )
import Effectful.Tracing.Propagation.Baggage
  ( extractBaggage
  , injectBaggage
  , maxBaggageEntries
  , parseBaggage
  , renderBaggage
  )

tests :: TestTree
tests =
  testGroup
    "Baggage"
    [ testGroup "pure operations" pureOps
    , testGroup "ambient effect" effectOps
    , testGroup "codec" codecOps
    ]

pureOps :: [TestTree]
pureOps =
  [ testCase "empty has no entries" $ do
      nullBaggage emptyBaggage @?= True
      baggageSize emptyBaggage @?= 0
  , testCase "insert then lookup" $ do
      let b = insertBaggage "k" "v" emptyBaggage
      lookupBaggageValue "k" b @?= Just "v"
      lookupBaggage "k" b @?= Just (BaggageEntry "v" Nothing)
      lookupBaggageValue "absent" b @?= Nothing
  , testCase "insert replaces an existing key" $ do
      let b = insertBaggage "k" "second" (insertBaggage "k" "first" emptyBaggage)
      lookupBaggageValue "k" b @?= Just "second"
      baggageSize b @?= 1
  , testCase "delete removes a key" $ do
      let b = deleteBaggage "k" (insertBaggage "k" "v" emptyBaggage)
      lookupBaggageValue "k" b @?= Nothing
      nullBaggage b @?= True
  , testCase "toList is ordered by key" $ do
      let b = insertBaggage "b" "2" (insertBaggage "a" "1" (insertBaggage "c" "3" emptyBaggage))
      map fst (baggageToList b) @?= ["a", "b", "c"]
  ]

effectOps :: [TestTree]
effectOps =
  [ testCase "runBaggage starts empty" $
      runPure (nullBaggage <$> getBaggage) @?= True
  , testCase "runBaggageWith seeds the ambient baggage" $
      runPureEff (runBaggageWith seeded (lookupBaggageValue "tenant" <$> getBaggage))
        @?= Just "acme"
  , testCase "withBaggageEntry is lexically scoped" $ do
      let result = runPure $ do
            before <- nullBaggage <$> getBaggage
            inside <- withBaggageEntry "x" "1" (lookupBaggageValue "x" <$> getBaggage)
            after <- lookupBaggageValue "x" <$> getBaggage
            pure (before, inside, after)
      result @?= (True, Just "1", Nothing)
  , testCase "localBaggage nests" $ do
      let result = runPure $
            withBaggageEntry "a" "1" $
              withBaggageEntry "b" "2" $ do
                b <- getBaggage
                pure (lookupBaggageValue "a" b, lookupBaggageValue "b" b)
      result @?= (Just "1", Just "2")
  , testCase "localBaggage can delete for a scope" $ do
      let result = runPure $
            withBaggageEntry "a" "1" $ do
              dropped <- localBaggage (deleteBaggage "a") (lookupBaggageValue "a" <$> getBaggage)
              restored <- lookupBaggageValue "a" <$> getBaggage
              pure (dropped, restored)
      result @?= (Nothing, Just "1")
  ]
  where
    seeded = baggageFromList [("tenant", BaggageEntry "acme" Nothing)]

codecOps :: [TestTree]
codecOps =
  [ testCase "render joins entries ordered by key" $
      renderBaggage (insertBaggage "b" "2" (insertBaggage "a" "1" emptyBaggage))
        @?= "a=1,b=2"
  , testCase "render percent-encodes values" $
      renderBaggage (insertBaggage "city" "New York" emptyBaggage)
        @?= "city=New%20York"
  , testCase "render appends metadata verbatim" $
      renderBaggage (baggageFromList [("k", BaggageEntry "v" (Just "ttl=30"))])
        @?= "k=v;ttl=30"
  , testCase "render of empty is the empty string" $
      renderBaggage emptyBaggage @?= ""
  , testCase "parse reads multiple entries" $ do
      let b = parseBaggage "k1=v1,k2=v2"
      lookupBaggageValue "k1" b @?= Just "v1"
      lookupBaggageValue "k2" b @?= Just "v2"
  , testCase "parse trims surrounding whitespace" $ do
      let b = parseBaggage " k1 = v1 , k2 = v2 "
      lookupBaggageValue "k1" b @?= Just "v1"
      lookupBaggageValue "k2" b @?= Just "v2"
  , testCase "parse percent-decodes values" $
      lookupBaggageValue "city" (parseBaggage "city=New%20York") @?= Just "New York"
  , testCase "parse keeps metadata as opaque text" $
      lookupBaggage "k" (parseBaggage "k=v;ttl=30;public")
        @?= Just (BaggageEntry "v" (Just "ttl=30;public"))
  , testCase "parse skips malformed members" $ do
      let b = parseBaggage "k1=v1,noequals,=novalue,k3=v3"
      map fst (baggageToList b) @?= ["k1", "k3"]
  , testCase "parse caps the entry count" $ do
      let header = T.intercalate "," ["k" <> T.pack (show i) <> "=v" | i <- [1 .. 200 :: Int]]
      baggageSize (parseBaggage header) @?= maxBaggageEntries
  , testCase "round-trip preserves values needing encoding" $ do
      let b = insertBaggage "k" "a b,c;d" emptyBaggage
      parseBaggage (renderBaggage b) @?= b
  , testCase "injectBaggage emits the header from ambient baggage" $
      runPure (withBaggageEntry "k" "v" injectBaggage)
        @?= [("baggage", "k=v")]
  , testCase "injectBaggage emits nothing when empty" $
      runPure injectBaggage @?= []
  , testCase "extractBaggage reads the header" $
      lookupBaggageValue "k" (extractBaggage [("baggage", "k=v")]) @?= Just "v"
  , testCase "extractBaggage on a missing header is empty" $
      nullBaggage (extractBaggage [("other", "x")]) @?= True
  ]

-- | Run a 'BaggageContext' computation that needs no other effects, starting
-- from empty baggage.
runPure :: Eff '[BaggageContext] a -> a
runPure = runPureEff . runBaggage
