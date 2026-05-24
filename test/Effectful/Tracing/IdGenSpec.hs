-- |
-- Module      : Effectful.Tracing.IdGenSpec
-- Description : Tests for the id generators (newTraceId / newSpanId).
--
-- "Effectful.Tracing.IdsSpec" pins the codec and validity edges, and the
-- round-trip over arbitrary bytes lives in "Effectful.Tracing.PropertySpec".
-- Neither exercises the generators themselves, which draw real bytes from the
-- configured entropy source. This module does: it asserts that a freshly
-- generated id is valid, round-trips through hex, and that a large batch is
-- collision-free.
--
-- The same assertions run whichever byte source the library was built with, so
-- building the suite with the @secure-ids@ cabal flag turns this into coverage
-- of the @crypton@ system-entropy path (otherwise it covers the default
-- splitmix PRNG). The group label reflects which source is under test.
{-# LANGUAGE CPP #-}

module Effectful.Tracing.IdGenSpec
  ( tests
  ) where

import Control.Monad (replicateM)
import Data.Set qualified as Set

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing
  ( isValidSpanId
  , isValidTraceId
  , newSpanId
  , newTraceId
  , spanIdFromHex
  , spanIdToHex
  , traceIdFromHex
  , traceIdToHex
  )

-- | Which entropy source these assertions are exercising, decided by the
-- @secure-ids@ cabal flag (which sets @-DSECURE_IDS@ on this suite).
sourceName :: String
#ifdef SECURE_IDS
sourceName = "crypton system entropy (secure-ids)"
#else
sourceName = "splitmix PRNG (default)"
#endif

-- | How many ids to mint when checking for collisions. Large enough that a
-- broken (constant or low-entropy) source would almost certainly repeat: even
-- the 8-byte span id has a birthday-collision probability here on the order of
-- 1e-12.
batchSize :: Int
batchSize = 10000

tests :: TestTree
tests =
  testGroup
    ("Id generation: " <> sourceName)
    [ testCase "a generated trace id is valid" $ do
        tid <- newTraceId
        assertBool "valid trace id" (isValidTraceId tid)
    , testCase "a generated span id is valid" $ do
        sid <- newSpanId
        assertBool "valid span id" (isValidSpanId sid)
    , testCase "a generated trace id round-trips through hex" $ do
        tid <- newTraceId
        traceIdFromHex (traceIdToHex tid) @?= Just tid
    , testCase "a generated span id round-trips through hex" $ do
        sid <- newSpanId
        spanIdFromHex (spanIdToHex sid) @?= Just sid
    , testCase (show batchSize <> " generated trace ids are all distinct") $ do
        ids <- replicateM batchSize newTraceId
        Set.size (Set.fromList ids) @?= batchSize
    , testCase (show batchSize <> " generated span ids are all distinct") $ do
        ids <- replicateM batchSize newSpanId
        Set.size (Set.fromList ids) @?= batchSize
    ]
