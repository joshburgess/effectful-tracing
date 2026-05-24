{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Effectful.Tracing.AsyncExceptionSpec
-- Description : 'withSpan' finalizes its span even when interrupted.
--
-- Span finalization runs inside 'Effectful.Exception.generalBracket', so it
-- fires on every exit: a normal return, a synchronous exception, a 'timeout'
-- cancellation, or an asynchronous 'killThread'. These tests interrupt a
-- 'withSpan' body each of those abnormal ways and assert the span still reaches
-- the sink with its end time set, an 'Error' status, and an @exception@ event.
-- This is the guarantee callers rely on: an interrupted operation must not
-- silently drop its span or leave it open.
module Effectful.Tracing.AsyncExceptionSpec
  ( tests
  ) where

import Control.Concurrent qualified as Conc
import Control.Exception (ErrorCall (ErrorCall), SomeException)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as T

import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, forkIO, killThread, runConcurrent, threadDelay)
import Effectful.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Effectful.Exception (finally, throwIO, try)
import Effectful.Timeout (Timeout, runTimeout, timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Event (eventName)
  , Span
  , SpanStatus (Error)
  , Tracer
  , spanEndTime
  , spanEvents
  , spanStartTime
  , spanStatus
  , withSpan
  )
import Effectful.Tracing.Interpreter.InMemory
  ( findSpan
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Async-exception finalization"
    [ testCase "a synchronous exception finalizes the span and re-propagates" $ do
        spans <-
          captureCatching $
            withSpan "boom" (throwIO (ErrorCall "kaboom"))
        s <- expectSpan "boom" spans
        assertErrorWithEvent s
        assertBool
          "the original message survives in the Error status"
          (statusMessageContains "kaboom" (spanStatus s))
    , testCase "a timeout cancellation finalizes the span" $ do
        -- The window between starting the action and the timer firing must be
        -- wide enough that the span is reliably open before the cancellation
        -- arrives, even under a loaded parallel suite; the body then sleeps far
        -- longer than the timeout so the timeout always wins. A tight timeout
        -- here races the span-open and can cancel before any span exists.
        (result, spans) <-
          runTimed $
            timeout 100000 (withSpan "slow" (liftIO (Conc.threadDelay 10000000)))
        result @?= Nothing
        s <- expectSpan "slow" spans
        assertErrorWithEvent s
    , testCase "an asynchronous killThread finalizes the span" $ do
        ((), spans) <-
          runConcurrentCapture $ do
            started <- newEmptyMVar
            done <- newEmptyMVar
            tid <-
              forkIO $
                withSpan "cancelled" (putMVar started () >> threadDelay 1000000)
                  `finally` putMVar done ()
            -- Wait until the span is open, kill the thread mid-flight, then
            -- wait for the bracket cleanup (the @finally@) to have run.
            takeMVar started
            killThread tid
            takeMVar done
        s <- expectSpan "cancelled" spans
        assertErrorWithEvent s
    ]

-- | Assert the span looks like one finalized through the exception path: a
-- non-decreasing end time, an 'Error' status, and a recorded @exception@ event.
assertErrorWithEvent :: Span -> IO ()
assertErrorWithEvent s = do
  assertBool "the end time is not before the start time" (spanEndTime s >= spanStartTime s)
  assertBool "the status is Error" (isError (spanStatus s))
  assertBool
    "an exception event is recorded"
    (any ((== "exception") . eventName) (spanEvents s))

isError :: SpanStatus -> Bool
isError (Error _) = True
isError _ = False

statusMessageContains :: Text -> SpanStatus -> Bool
statusMessageContains needle (Error msg) = needle `T.isInfixOf` msg
statusMessageContains _ _ = False

-- | Run a traced program through the in-memory interpreter, swallowing any
-- synchronous exception it raises, and return the captured spans. The span is
-- emitted during the @generalBracket@ cleanup, before the exception propagates,
-- so it is already in the buffer by the time we read it.
captureCatching :: Eff '[Tracer, IOE] () -> IO [Span]
captureCatching program = runEff $ do
  captured <- newCapturedSpans
  _ <- try @SomeException (runTracerInMemory captured program)
  readCapturedSpans captured

-- | Run a program needing 'timeout', returning its result and captured spans.
runTimed :: Eff '[Tracer, Timeout, IOE] a -> IO (a, [Span])
runTimed program = runEff . runTimeout $ do
  captured <- newCapturedSpans
  result <- runTracerInMemory captured program
  spans <- readCapturedSpans captured
  pure (result, spans)

-- | Run a program needing 'Concurrent', returning its result and captured spans.
runConcurrentCapture :: Eff '[Tracer, Concurrent, IOE] a -> IO (a, [Span])
runConcurrentCapture program = runEff . runConcurrent $ do
  captured <- newCapturedSpans
  result <- runTracerInMemory captured program
  spans <- readCapturedSpans captured
  pure (result, spans)

expectSpan :: Text -> [Span] -> IO Span
expectSpan name spans =
  maybe (assertFailure ("expected a span named " <> show name)) pure (findSpan name spans)
