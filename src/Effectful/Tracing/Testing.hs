-- |
-- Module      : Effectful.Tracing.Testing
-- Description : Helpers for testing code that uses the 'Effectful.Tracing.Tracer' effect.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A one-stop module for testing your own instrumentation. It re-exports the
-- in-memory capture interpreter (run a 'Effectful.Tracing.Tracer' computation,
-- collect the completed spans) and adds pure matchers and finders over the
-- captured @['Span']@, so a test can assert on span shape, parent/child
-- structure, attributes, status, events, and kind.
--
-- The matchers are plain predicates ('Bool') and lookups ('Maybe'), with no
-- dependency on any test framework, so they compose with @tasty-hunit@,
-- @hspec@, @hedgehog@, or anything else: pair them with your framework's
-- assertion combinator.
--
-- > import Effectful (runEff)
-- > import Effectful.Tracing (SpanStatus (Ok), withSpan, addAttribute, setStatus)
-- > import Effectful.Tracing.Testing
-- > import Test.Tasty.HUnit (assertBool, (@?=))
-- >
-- > test = do
-- >   captured <- newCapturedSpans
-- >   _ <- runEff . runTracerInMemory captured $
-- >     withSpan "handler" $ do
-- >       addAttribute "http.response.status_code" (200 :: Int)
-- >       setStatus Ok
-- >       withSpan "db.query" (pure ())
-- >   spans <- readCapturedSpans captured
-- >   case (findSpan "handler" spans, findSpan "db.query" spans) of
-- >     (Just handler, Just db) -> do
-- >       assertBool "db.query is a child of handler" (db `isChildOf` handler)
-- >       assertBool "handler is a root" (isRoot handler)
-- >       hasStatus Ok handler @?= True
-- >       lookupAttribute "http.response.status_code" handler
-- >         @?= Just (AttrInt 200)
-- >     _ -> assertBool "both spans were captured" False
module Effectful.Tracing.Testing
  ( -- * Capturing spans
    -- | Re-exported from "Effectful.Tracing.Interpreter.InMemory".
    CapturedSpans
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  , runTracerInMemoryWith

    -- * Finding spans
  , findSpan
  , findSpans
  , rootSpans
  , childrenOf
  , descendantsOf

    -- * Structure
  , isRoot
  , isChildOf

    -- * Attributes
  , lookupAttribute
  , hasAttribute
  , hasAttributeValue

    -- * Status, events, and kind
  , hasStatus
  , lookupEvent
  , hasEvent
  , hasKind
  ) where

import Data.List (find)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)

import Effectful.Tracing.Attribute
  ( Attribute (attributeKey, attributeValue)
  , AttributeValue
  )
import Effectful.Tracing.Interpreter.InMemory
  ( CapturedSpans
  , childrenOf
  , findSpan
  , newCapturedSpans
  , readCapturedSpans
  , rootSpans
  , runTracerInMemory
  , runTracerInMemoryWith
  )
import Effectful.Tracing.Internal.Types
  ( Event (eventName)
  , Span
      ( spanAttributes
      , spanContext
      , spanEvents
      , spanKind
      , spanParentContext
      , spanStatus
      )
  , SpanContext (spanContextSpanId, spanContextTraceId)
  , SpanKind
  , SpanStatus
  , spanName
  )

-- | All captured spans with the given name, in capture (completion) order.
-- Use this rather than 'findSpan' when a name can repeat (a loop body, a
-- retried operation) and you want every occurrence.
findSpans :: Text -> [Span] -> [Span]
findSpans name = filter ((== name) . spanName)

-- | The spans transitively beneath the given span: its children, their
-- children, and so on. Captured spans form a tree (each has at most one
-- parent), so this terminates and visits each descendant once.
descendantsOf :: Span -> [Span] -> [Span]
descendantsOf parent spans = go (childrenOf parent spans)
  where
    go [] = []
    go (s : rest) = s : go (childrenOf s spans <> rest)

-- | Whether a span is a trace root (it has no parent context).
isRoot :: Span -> Bool
isRoot = isNothing . spanParentContext

-- | @child \`isChildOf\` parent@ holds when @child@'s recorded parent is
-- @parent@'s own context (same trace id and span id).
isChildOf :: Span -> Span -> Bool
isChildOf child parent =
  case spanParentContext child of
    Just pc ->
      spanContextSpanId pc == spanContextSpanId parentContext
        && spanContextTraceId pc == spanContextTraceId parentContext
    Nothing -> False
  where
    parentContext = spanContext parent

-- | Look up a span attribute by key, returning its typed value if present.
lookupAttribute :: Text -> Span -> Maybe AttributeValue
lookupAttribute key s =
  attributeValue <$> find ((== key) . attributeKey) (spanAttributes s)

-- | Whether the span carries an attribute with the given key (any value).
hasAttribute :: Text -> Span -> Bool
hasAttribute key = isJust . lookupAttribute key

-- | Whether the span carries an attribute with the given key /and/ exactly the
-- given value.
hasAttributeValue :: Text -> AttributeValue -> Span -> Bool
hasAttributeValue key value s = lookupAttribute key s == Just value

-- | Whether the span ended with the given status.
hasStatus :: SpanStatus -> Span -> Bool
hasStatus status s = spanStatus s == status

-- | Look up the first event on the span with the given name.
lookupEvent :: Text -> Span -> Maybe Event
lookupEvent name s = find ((== name) . eventName) (spanEvents s)

-- | Whether the span recorded an event with the given name.
hasEvent :: Text -> Span -> Bool
hasEvent name = isJust . lookupEvent name

-- | Whether the span has the given kind.
hasKind :: SpanKind -> Span -> Bool
hasKind kind s = spanKind s == kind
