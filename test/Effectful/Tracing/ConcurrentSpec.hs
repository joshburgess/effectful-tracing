{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.ConcurrentSpec
-- Description : Tests for span propagation across forked and concurrent work.
--
-- These exercise the helpers in "Effectful.Tracing.Concurrent" through the
-- in-memory interpreter: the inheriting wrappers must make forked spans
-- children of the launching span regardless of completion order, an exception
-- in one concurrent branch must be recorded on that branch and propagate, and
-- 'forkLinked' must start a detached root that links back to the caller. A
-- stress test confirms many concurrent spans are all captured with the right
-- parent and nothing is lost.
module Effectful.Tracing.ConcurrentSpec
  ( tests
  ) where

import Control.Exception (Exception, try)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Concurrent.Async (wait)
import Effectful.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Effectful.Exception (throwIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Span (spanContext, spanLinks, spanName, spanParentContext, spanStatus)
  , SpanContext (spanContextTraceId)
  , SpanStatus (Error)
  , Tracer
  , withSpan
  )
import Effectful.Tracing.Concurrent
  ( asyncInstrumented
  , concurrentlyInstrumented
  , forConcurrentlyInstrumented
  , forkLinked
  )
import Effectful.Tracing.Internal.Types (Link (linkContext))
import Effectful.Tracing.Interpreter.InMemory
  ( CapturedSpans
  , childrenOf
  , findSpan
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Concurrent propagation"
    [ testCase "asyncInstrumented nests under the launching span" $ do
        spans <- run $
          withSpan "parent" $ do
            a <- asyncInstrumented (withSpan "child" (pure ()))
            wait a
        parent <- expectSpan "parent" spans
        child <- expectSpan "child" spans
        childrenOf parent spans @?= [child]
    , testCase "concurrentlyInstrumented makes both branches siblings under the launcher" $ do
        spans <- run $
          withSpan "parent" $
            concurrentlyInstrumented (withSpan "a" (pure ())) (withSpan "b" (pure ()))
        parent <- expectSpan "parent" spans
        assertBool
          "both branches are children of the launching span"
          (sort (map spanName (childrenOf parent spans)) == ["a", "b"])
    , testCase "completion order does not change the parent relationships" $ do
        -- "slow" finishes well after "fast", so it is captured last; the
        -- parent/child links must not depend on that order.
        spans <- run $
          withSpan "parent" $
            concurrentlyInstrumented
              (withSpan "slow" (threadDelay 20000))
              (withSpan "fast" (pure ()))
        parent <- expectSpan "parent" spans
        assertBool
          "slow and fast are both children regardless of completion order"
          (sort (map spanName (childrenOf parent spans)) == ["fast", "slow"])
    , testCase "an exception in one branch is recorded there and propagates" $ do
        captured <- runEff newCapturedSpans
        result <-
          try . runEff . runConcurrent . runTracerInMemory captured $
            withSpan "parent" $
              concurrentlyInstrumented
                (withSpan "ok" (threadDelay 50000))
                (withSpan "boom" (throwIO Boom))
        case result of
          Right _ -> assertFailure "expected the exception to propagate out of concurrentlyInstrumented"
          Left Boom -> pure ()
        spans <- runEff (readCapturedSpans captured)
        boom <- expectSpan "boom" spans
        case spanStatus boom of
          Error msg -> assertBool "error message mentions the exception" ("Boom" `T.isInfixOf` msg)
          other -> assertFailure ("expected Error status on the throwing span, got " <> show other)
    , testCase "forkLinked starts a detached root linked back to the caller" $ do
        captured <- runEff newCapturedSpans
        runEff . runConcurrent . runTracerInMemory captured $ do
          signal <- newEmptyMVar
          withSpan "caller" $ do
            _ <- forkLinked (withSpan "background" (pure ()) >> putMVar signal ())
            takeMVar signal
        spans <- runEff (readCapturedSpans captured)
        caller <- expectSpan "caller" spans
        background <- expectSpan "background" spans
        spanParentContext background @?= Nothing
        assertBool
          "the linked root is in a different trace than the caller"
          (spanContextTraceId (spanContext background) /= spanContextTraceId (spanContext caller))
        assertBool
          "the linked root carries a link back to the caller span"
          (spanContext caller `elem` map linkContext (spanLinks background))
    , testCase "1000 concurrent traced actions are all captured under the launcher" $ do
        let n = 1000
        spans <- run $
          withSpan "fanout" $
            forConcurrentlyInstrumented [1 .. n] $ \i ->
              withSpan ("task-" <> T.pack (show i)) (pure i)
        parent <- expectSpan "fanout" spans
        let kids = childrenOf parent spans
        length kids @?= n
        assertBool
          "every captured task is a child of the launcher and named distinctly"
          (sort (map spanName kids) == sort [T.pack ("task-" <> show i) | i <- [1 .. n]])
    ]

-- | Run a traced, concurrent program through the in-memory interpreter and
-- return the captured spans.
run :: Eff '[Tracer, Concurrent, IOE] a -> IO [Span]
run prog = do
  captured <- runEff newCapturedSpans
  _ <- runEff . runConcurrent . runTracerInMemory captured $ prog
  collect captured

collect :: CapturedSpans -> IO [Span]
collect = runEff . readCapturedSpans

-- | Look up a captured span by name, failing the test if it is absent.
expectSpan :: Text -> [Span] -> IO Span
expectSpan name spans =
  maybe (assertFailure ("no captured span named " <> show name)) pure (findSpan name spans)

-- | A trivial exception with a recognizable message.
data Boom = Boom
  deriving (Show)

instance Exception Boom
