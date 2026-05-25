{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Effectful.Tracing.InMemorySpec
-- Description : Behavioural and property tests for the in-memory interpreter.
module Effectful.Tracing.InMemorySpec
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import Control.Monad.IO.Class (liftIO)
import Data.Set qualified as Set
import Data.Text (Text)
import System.Timeout (timeout)

import Effectful (Eff, IOE, runEff, (:>))
import Hedgehog (Gen, Property, assert, evalIO, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing
  ( Event (eventName)
  , Span
  , SpanStatus (Error, Ok)
  , Tracer
  , addAttribute
  , addEvent
  , attributeKey
  , setStatus
  , spanAttributes
  , spanContext
  , spanContextSpanId
  , spanContextTraceId
  , spanEndTime
  , spanEvents
  , spanName
  , spanParentContext
  , spanStartTime
  , spanStatus
  , updateName
  , withSpan
  )
import Effectful.Tracing.Interpreter.InMemory
  ( CapturedSpans
  , childrenOf
  , findSpan
  , newCapturedSpans
  , readCapturedSpans
  , rootSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "In-memory interpreter"
    [ testCase "single span is captured with name, ordered timing, and status" $ do
        spans <- captureSpans (withSpan "solo" (setStatus Ok))
        case spans of
          [s] -> do
            spanName s @?= "solo"
            spanStatus s @?= Ok
            assertBool "start <= end" (spanStartTime s <= spanEndTime s)
          _ -> assertBool "expected exactly one span" False
    , testCase "nested spans record the parent relationship" $ do
        spans <- captureSpans (withSpan "outer" (withSpan "inner" (pure ())))
        outer <- expectSpan "outer" spans
        inner <- expectSpan "inner" spans
        -- inner's parent is outer's context
        (spanContextSpanId . spanContext <$> Just outer)
          @?= (spanContextSpanId <$> spanParentContext inner)
        childrenOf outer spans @?= [inner]
        rootSpans spans @?= [outer]
    , testCase "sequential spans are siblings, not parent and child" $ do
        spans <-
          captureSpans
            (withSpan "parent" (withSpan "a" (pure ()) >> withSpan "b" (pure ())))
        parent <- expectSpan "parent" spans
        a <- expectSpan "a" spans
        b <- expectSpan "b" spans
        childrenOf parent spans @?= [a, b]
        childrenOf a spans @?= []
    , testCase "exception sets Error status, records an event, and re-raises" $ do
        (outcome, spans) <-
          withCapture $ \captured ->
            try (runEff (runTracerInMemory captured throwingSpan))
        case outcome :: Either SomeException () of
          Left _ -> pure ()
          Right () -> assertBool "expected the exception to propagate" False
        s <- expectSpan "boom" spans
        case spanStatus s of
          Error msg -> assertBool "error carries a message" (msg /= "")
          other -> assertBool ("expected Error status, got " <> show other) False
        assertBool
          "an exception event is recorded"
          (any ((== "exception") . eventName) (spanEvents s))
    , testCase "a span killed by an async exception is still closed exactly once" $ do
        (result, spans) <-
          withCapture $ \captured ->
            timeout 50_000 (runEff (runTracerInMemory captured slowSpan))
        result @?= Nothing
        case spans of
          [s] -> do
            assertBool "end time recorded" (spanStartTime s <= spanEndTime s)
            case spanStatus s of
              Error _ -> pure ()
              other -> assertBool ("expected Error status, got " <> show other) False
          _ -> assertBool "expected exactly one closed span" False
    , testCase "emit operations land on the lexically-current span" $ do
        spans <- captureSpans lexicalProgram
        outer <- expectSpan "outer" spans
        inner <- expectSpan "inner" spans
        assertBool "outer has its own attribute" (hasAttribute "o" outer)
        assertBool "outer does not have inner's attribute" (not (hasAttribute "i" outer))
        assertBool "inner has its own attribute" (hasAttribute "i" inner)
        assertBool "inner does not have outer's attribute" (not (hasAttribute "o" inner))
    , testCase "emit operations with no active span are silent no-ops" $ do
        spans <-
          captureSpans $ do
            addAttribute "orphan" ("x" :: Text)
            addEvent "orphan.event" []
            setStatus Ok
            withSpan "real" (addAttribute "k" ("v" :: Text))
        s <- expectSpan "real" spans
        length spans @?= 1
        assertBool "the real span kept its attribute" (hasAttribute "k" s)
        assertBool "no orphan attribute leaked onto the real span" (not (hasAttribute "orphan" s))
    , testCase "updateName replaces the active span's name" $ do
        spans <- captureSpans (withSpan "provisional" (updateName "GET /users/{id}"))
        case spans of
          [s] -> spanName s @?= "GET /users/{id}"
          _ -> assertBool "expected exactly one span" False
    , testCase "updateName only renames the lexically-current span" $ do
        spans <-
          captureSpans $
            withSpan "outer" $ do
              withSpan "inner" (updateName "renamed-inner")
              updateName "renamed-outer"
        outer <- expectSpan "renamed-outer" spans
        inner <- expectSpan "renamed-inner" spans
        childrenOf outer spans @?= [inner]
    , testCase "updateName with no active span is a silent no-op" $ do
        spans <-
          captureSpans $ do
            updateName "orphan"
            withSpan "real" (pure ())
        _ <- expectSpan "real" spans
        length spans @?= 1
    , testProperty "captured spans form a valid forest" prop_validForest
    ]

-- Programs under test -------------------------------------------------------

throwingSpan :: (Tracer :> es, IOE :> es) => Eff es ()
throwingSpan = withSpan "boom" $ do
  addAttribute "before.throw" ("set" :: Text)
  liftIO (throwIO (ErrorCall "deliberate failure"))

slowSpan :: (Tracer :> es, IOE :> es) => Eff es ()
slowSpan = withSpan "slow" (liftIO (threadDelay 1_000_000))

lexicalProgram :: Tracer :> es => Eff es ()
lexicalProgram = withSpan "outer" $ do
  addAttribute "o" ("outer" :: Text)
  withSpan "inner" (addAttribute "i" ("inner" :: Text))

-- Forest property -----------------------------------------------------------

-- | A span-tree shape: each node opens a span and runs its children inside it.
newtype Shape = Shape [Shape]
  deriving stock (Show)

genForest :: Gen [Shape]
genForest = Gen.list (Range.linear 0 3) (genShape 3)

genShape :: Int -> Gen Shape
genShape depth
  | depth <= 0 = pure (Shape [])
  | otherwise = Shape <$> Gen.list (Range.linear 0 3) (genShape (depth - 1))

shapeProgram :: Tracer :> es => Shape -> Eff es ()
shapeProgram (Shape children) = withSpan "node" (mapM_ shapeProgram children)

countNodes :: Shape -> Int
countNodes (Shape children) = 1 + sum (map countNodes children)

prop_validForest :: Property
prop_validForest = property $ do
  forest <- forAll genForest
  spans <- evalIO (captureSpans (mapM_ shapeProgram forest))
  -- every opened span is captured
  length spans === sum (map countNodes forest)
  -- every non-root span's parent is itself a captured span
  let identifier s = (spanContextTraceId (spanContext s), spanContextSpanId (spanContext s))
      captured = Set.fromList (map identifier spans)
      parents =
        [ (spanContextTraceId pc, spanContextSpanId pc)
        | s <- spans
        , Just pc <- [spanParentContext s]
        ]
  assert (all (`Set.member` captured) parents)

-- Helpers -------------------------------------------------------------------

-- | Run a traced program against a fresh buffer and return the captured spans.
captureSpans :: Eff '[Tracer, IOE] a -> IO [Span]
captureSpans program = snd <$> withCapture (\captured -> runEff (runTracerInMemory captured program))

-- | Provide a fresh buffer to an IO action, then return its result alongside
-- the spans captured into the buffer (read even if the action threw, as long
-- as the caller handled the exception).
withCapture :: (CapturedSpans -> IO a) -> IO (a, [Span])
withCapture k = do
  captured <- runEff newCapturedSpans
  a <- k captured
  spans <- runEff (readCapturedSpans captured)
  pure (a, spans)

expectSpan :: Text -> [Span] -> IO Span
expectSpan name spans =
  maybe (assertFailure ("expected a span named " <> show name)) pure (findSpan name spans)

hasAttribute :: Text -> Span -> Bool
hasAttribute key s = any ((== key) . attributeKey) (spanAttributes s)
