{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.DatabaseSpec
-- Description : Tests for the framework-agnostic database span helpers.
--
-- These exercise the pure helpers ('inferOperationName', 'querySpanName',
-- 'queryAttributes') directly and run 'withQuerySpan' through the in-memory
-- interpreter, asserting the emitted span is @client@-kind, named by the
-- convention, and carries exactly the @db.*@ attributes for the fields that were
-- set. No live database is involved: the @postgresql-simple@ wrappers are thin
-- delegations to this core, which is what needs covering.
module Effectful.Tracing.Instrumentation.DatabaseSpec
  ( tests
  ) where

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Attribute (Attribute (attributeKey, attributeValue), AttributeValue (AttrText))
import Effectful.Tracing.Instrumentation.Database
  ( DatabaseQuery (queryCollection, queryNamespace, queryOperation, queryText)
  , databaseQuery
  , inferOperationName
  , queryAttributes
  , querySpanName
  , withQuerySpan
  )
import Effectful.Tracing.Internal.Types (Span, SpanKind (Client), spanAttributes, spanKind, spanName)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Instrumentation.Database"
    [ testGroup "inferOperationName" inferOperationCases
    , testGroup "querySpanName" spanNameCases
    , testGroup "queryAttributes" attributeCases
    , testGroup "withQuerySpan" withQuerySpanCases
    ]

inferOperationCases :: [TestTree]
inferOperationCases =
  [ testCase "upper-cases the leading keyword" $
      inferOperationName "select * from users" @?= Just "SELECT"
  , testCase "keeps an already-upper keyword" $
      inferOperationName "INSERT INTO orders VALUES (?)" @?= Just "INSERT"
  , testCase "ignores leading whitespace" $
      inferOperationName "  \n  delete from sessions" @?= Just "DELETE"
  , testCase "blank statement yields Nothing" $
      inferOperationName "   " @?= Nothing
  , testCase "empty statement yields Nothing" $
      inferOperationName "" @?= Nothing
  ]

spanNameCases :: [TestTree]
spanNameCases =
  [ testCase "operation and collection" $
      querySpanName
        (databaseQuery "postgresql") {queryOperation = Just "SELECT", queryCollection = Just "users"}
        @?= "SELECT users"
  , testCase "operation only" $
      querySpanName (databaseQuery "postgresql") {queryOperation = Just "SELECT"} @?= "SELECT"
  , testCase "falls back to the system name" $
      querySpanName (databaseQuery "postgresql") @?= "postgresql"
  , testCase "collection without operation falls back to the system name" $
      querySpanName (databaseQuery "postgresql") {queryCollection = Just "users"} @?= "postgresql"
  ]

attributeCases :: [TestTree]
attributeCases =
  [ testCase "system only when nothing else is set" $
      keys (databaseQuery "postgresql") @?= ["db.system.name"]
  , testCase "includes every set optional field in convention order" $
      keys
        (databaseQuery "postgresql")
          { queryText = Just "SELECT 1"
          , queryOperation = Just "SELECT"
          , queryCollection = Just "users"
          , queryNamespace = Just "app"
          }
        @?= [ "db.system.name"
            , "db.query.text"
            , "db.operation.name"
            , "db.collection.name"
            , "db.namespace"
            ]
  , testCase "omits unset optional fields" $
      keys (databaseQuery "postgresql") {queryOperation = Just "SELECT"}
        @?= ["db.system.name", "db.operation.name"]
  , testCase "records the system name value" $
      lookup "db.system.name" (pairs (databaseQuery "mysql")) @?= Just (AttrText "mysql")
  ]
  where
    keys = map attributeKey . queryAttributes
    pairs = map (\a -> (attributeKey a, attributeValue a)) . queryAttributes

withQuerySpanCases :: [TestTree]
withQuerySpanCases =
  [ testCase "emits a client-kind span named by the convention" $ do
      spans <-
        run $
          withQuerySpan
            (databaseQuery "postgresql") {queryOperation = Just "SELECT", queryCollection = Just "users"}
            (pure ())
      case spans of
        [s] -> do
          spanName s @?= "SELECT users"
          spanKind s @?= Client
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  , testCase "annotates the span with the db.* attributes" $ do
      spans <-
        run $
          withQuerySpan
            (databaseQuery "postgresql") {queryText = Just "SELECT 1", queryOperation = Just "SELECT"}
            (pure ())
      case spans of
        [s] ->
          map attributeKey (spanAttributes s)
            @?= ["db.system.name", "db.query.text", "db.operation.name"]
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  , testCase "nests under an enclosing span" $ do
      spans <- run (withSpan "outer" (withQuerySpan (databaseQuery "postgresql") (pure ())))
      map spanName spans @?= ["postgresql", "outer"]
  ]

-- | Run a 'Tracer' computation through the in-memory interpreter, returning the
-- captured spans (innermost first, as the interpreter records them on close).
run :: Eff '[Tracer, IOE] a -> IO [Span]
run action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemory captured action
  readCapturedSpans captured
