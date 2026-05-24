{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.TestingSpec
-- Description : Tests for the public testing helpers.
--
-- Drives a small traced computation through the re-exported in-memory
-- interpreter and checks that the matchers and finders in
-- "Effectful.Tracing.Testing" report the captured tree faithfully: span lookup
-- (single and repeated names), parent/child and descendant structure, root
-- detection, and the attribute / status / event / kind predicates.
module Effectful.Tracing.TestingSpec
  ( tests
  ) where

import Data.List (sort)
import Data.Maybe (isJust)
import Data.Text (Text)

import Effectful (Eff, runEff, (:>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing
  ( SpanArguments (kind)
  , SpanKind (Client, Internal)
  , SpanStatus (Ok, Unset)
  , Tracer
  , addAttribute
  , addEvent
  , defaultSpanArguments
  , setStatus
  , withSpan
  , withSpan'
  )
import Effectful.Tracing.Attribute (AttributeValue (AttrText))
import Effectful.Tracing.Internal.Types (Span, spanName)
import Effectful.Tracing.Testing
  ( childrenOf
  , descendantsOf
  , findSpan
  , findSpans
  , hasAttribute
  , hasAttributeValue
  , hasEvent
  , hasKind
  , hasStatus
  , isChildOf
  , isRoot
  , lookupAttribute
  , lookupEvent
  , newCapturedSpans
  , readCapturedSpans
  , rootSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Testing helpers"
    [ testCase "findSpan / findSpans locate spans by name" $ do
        spans <- captured
        fmap spanName (findSpan "root" spans) @?= Just "root"
        findSpan "absent" spans @?= Nothing
        -- "leaf" is opened twice, so findSpans returns both occurrences.
        length (findSpans "leaf" spans) @?= 2
        findSpans "absent" spans @?= []
    , testCase "rootSpans and isRoot agree on the single root" $ do
        spans <- captured
        fmap spanName (rootSpans spans) @?= ["root"]
        assertBool "root isRoot" (all isRoot (findSpan "root" spans))
        assertBool "db is not a root" (not (any isRoot (findSpan "db" spans)))
    , testCase "childrenOf returns direct children only" $ do
        spans <- captured
        case findSpan "root" spans of
          Just root -> sort (map spanName (childrenOf root spans)) @?= ["api", "leaf", "leaf"]
          Nothing -> assertBool "root present" False
    , testCase "descendantsOf returns the whole subtree" $ do
        spans <- captured
        case findSpan "root" spans of
          Just root -> sort (map spanName (descendantsOf root spans)) @?= ["api", "db", "leaf", "leaf"]
          Nothing -> assertBool "root present" False
    , testCase "isChildOf reflects the recorded parent" $ do
        spans <- captured
        case (findSpan "db" spans, findSpan "api" spans, findSpan "root" spans) of
          (Just db, Just api, Just root) -> do
            assertBool "db is a child of api" (db `isChildOf` api)
            assertBool "db is not a child of root" (not (db `isChildOf` root))
          _ -> assertBool "db, api, root present" False
    , testCase "attribute matchers read the captured attributes" $ do
        spans <- captured
        case findSpan "root" spans of
          Just root -> do
            lookupAttribute "service" root @?= Just (AttrText "checkout")
            lookupAttribute "absent" root @?= Nothing
            hasAttribute "service" root @?= True
            hasAttribute "absent" root @?= False
            hasAttributeValue "service" (AttrText "checkout") root @?= True
            hasAttributeValue "service" (AttrText "other") root @?= False
          Nothing -> assertBool "root present" False
    , testCase "status, event, and kind matchers" $ do
        spans <- captured
        case (findSpan "root" spans, findSpan "api" spans) of
          (Just root, Just api) -> do
            hasStatus Ok root @?= True
            hasStatus Unset api @?= True
            hasEvent "ready" root @?= True
            hasEvent "absent" root @?= False
            isJust (lookupEvent "ready" root) @?= True
            hasKind Client api @?= True
            hasKind Internal root @?= True
          _ -> assertBool "root and api present" False
    ]

-- | A small traced tree: a root with a service attribute, a "ready" event, and
-- an Ok status; a client-kind "api" child holding a "db" grandchild; and two
-- sibling "leaf" spans sharing a name.
program :: Tracer :> es => Eff es ()
program = withSpan "root" $ do
  addAttribute "service" ("checkout" :: Text)
  addEvent "ready" []
  setStatus Ok
  withSpan' "api" defaultSpanArguments {kind = Client} $
    withSpan "db" (pure ())
  withSpan "leaf" (pure ())
  withSpan "leaf" (pure ())

-- | Run 'program' through the in-memory interpreter and return the captured
-- spans.
captured :: IO [Span]
captured = runEff $ do
  buffer <- newCapturedSpans
  runTracerInMemory buffer program
  readCapturedSpans buffer
