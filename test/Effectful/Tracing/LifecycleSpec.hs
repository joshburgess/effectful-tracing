{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.LifecycleSpec
-- Description : Tests for the shared span lifecycle in "Internal.Live".
--
-- These exercise the parts of the shared lifecycle that the per-interpreter
-- specs do not: continuing a remote trace under 'withRemoteParent', starting a
-- detached root in-thread under 'withLinkedRoot', honoring an explicit start
-- time, the 'setStatus' transition rules end to end, and the fact that
-- 'recordException' records an event without changing the status. They run
-- through the in-memory interpreter, which shares this lifecycle with the
-- pretty-print and OpenTelemetry interpreters.
module Effectful.Tracing.LifecycleSpec
  ( tests
  ) where

import Control.Exception (ErrorCall (ErrorCall), toException)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( Event (eventName)
  , Link (Link, linkContext)
  , Span
  , SpanArguments (startTime)
  , SpanContext (..)
  , SpanStatus (Error, Ok, Unset)
  , Timestamp (Timestamp)
  , Tracer
  , defaultSpanArguments
  , defaultTraceFlags
  , emptyTraceState
  , getActiveSpan
  , recordException
  , setSampled
  , setStatus
  , spanContext
  , spanEvents
  , spanLinks
  , spanParentContext
  , spanStartTime
  , spanStatus
  , spanIdFromHex
  , traceIdFromHex
  , withLinkedRoot
  , withRemoteParent
  , withSpan
  , withSpan'
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
    "Span lifecycle"
    [ testCase "withRemoteParent continues the remote trace and parents to it" $ do
        spans <- captureSpans (withRemoteParent remoteContext (withSpan "child" (pure ())))
        child <- expectSpan "child" spans
        spanContextTraceId (spanContext child) @?= spanContextTraceId remoteContext
        fmap spanContextSpanId (spanParentContext child)
          @?= Just (spanContextSpanId remoteContext)
        assertBool
          "the child's parent is marked remote"
          (fmap spanContextIsRemote (spanParentContext child) == Just True)
    , testCase "withLinkedRoot starts a new trace in-thread and links back" $ do
        spans <-
          captureSpans $
            withSpan "outer" $ do
              parent <- getActiveSpan
              case parent of
                Just ctx -> withLinkedRoot [Link ctx []] (withSpan "root" (pure ()))
                Nothing -> pure ()
        outer <- expectSpan "outer" spans
        root <- expectSpan "root" spans
        spanParentContext root @?= Nothing
        assertBool
          "the linked root is a new trace, not the outer one"
          (spanContextTraceId (spanContext root) /= spanContextTraceId (spanContext outer))
        assertBool
          "the linked root carries a link back to the outer span"
          (spanContext outer `elem` map linkContext (spanLinks root))
    , testCase "an explicit start time is used verbatim" $ do
        let fixedStart = posixSecondsToUTCTime 1000 :: UTCTime
        spans <-
          captureSpans
            (withSpan' "timed" defaultSpanArguments {startTime = Just fixedStart} (pure ()))
        s <- expectSpan "timed" spans
        spanStartTime s @?= Timestamp fixedStart
    , testCase "Ok is terminal: a later Error does not override it" $ do
        spans <- captureSpans (withSpan "s" (setStatus Ok >> setStatus (Error "late")))
        s <- expectSpan "s" spans
        spanStatus s @?= Ok
    , testCase "an Error is overridden by a later Ok" $ do
        spans <- captureSpans (withSpan "s" (setStatus (Error "early") >> setStatus Ok))
        s <- expectSpan "s" spans
        spanStatus s @?= Ok
    , testCase "recordException records an event but leaves the status Unset" $ do
        spans <-
          captureSpans
            (withSpan "s" (recordException (toException (ErrorCall "noted, not fatal"))))
        s <- expectSpan "s" spans
        spanStatus s @?= Unset
        assertBool
          "an exception event is recorded"
          (any ((== "exception") . eventName) (spanEvents s))
    ]

-- | A remote span context, as if extracted from an inbound request.
remoteContext :: SpanContext
remoteContext =
  SpanContext
    { spanContextTraceId = unsafeHex traceIdFromHex "4bf92f3577b34da6a3ce929d0e0e4736"
    , spanContextSpanId = unsafeHex spanIdFromHex "00f067aa0ba902b7"
    , spanContextTraceFlags = setSampled True defaultTraceFlags
    , spanContextTraceState = emptyTraceState
    , spanContextIsRemote = True
    }

unsafeHex :: (Text -> Maybe a) -> Text -> a
unsafeHex parse raw = fromMaybe (error "bad fixture id") (parse raw)

captureSpans :: Eff '[Tracer, IOE] a -> IO [Span]
captureSpans program = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemory captured program
  readCapturedSpans captured

expectSpan :: Text -> [Span] -> IO Span
expectSpan name spans =
  maybe (assertFailure ("expected a span named " <> show name)) pure (findSpan name spans)
