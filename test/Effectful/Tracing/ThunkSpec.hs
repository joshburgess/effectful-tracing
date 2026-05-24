{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Effectful.Tracing.ThunkSpec
-- Description : Regression guard against thunk retention in completed spans.
--
-- A completed 'Span' crosses into an interpreter's sink (the in-memory buffer,
-- the pretty-print accumulator) and is held there. The shared lifecycle forces
-- that span to WHNF before handing it over (see @finalizeSpan@), so the sink
-- stores a finished value rather than a thunk that retains the span's builder
-- 'Data.IORef.IORef' and the live @ActiveSpan@. These tests assert, with
-- @nothunks@, that the spans a real traced computation produces carry no
-- unexpected thunk.
--
-- The check is deliberately precise rather than a blanket deep check. The
-- result attribute/event/link lists are built with 'reverse' and are
-- intentionally spine-lazy, so a deep walk would report thunks in their tails
-- that are not leaks. We therefore check the strict scalar structure of the
-- span deeply and the container fields to WHNF, which is exactly what the
-- lifecycle guarantees. The @NoThunks@ instances below live here, not in the
-- library, so the published package takes on no @nothunks@ dependency.
module Effectful.Tracing.ThunkSpec
  ( tests
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

import NoThunks.Class (NoThunks (noThunks, showTypeOf, wNoThunks), OnlyCheckWhnf (OnlyCheckWhnf), allNoThunks)

import Effectful (Eff, IOE, runEff, (:>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)

import Effectful.Tracing
  ( Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , setStatus
  , withSpan
  , (.=)
  )
import Effectful.Tracing.Internal.Ids (SpanId, TraceId)
import Effectful.Tracing.Internal.Types
  ( Span (..)
  , SpanContext (..)
  , SpanKind (..)
  , SpanStatus (..)
  , TraceFlags
  , TraceState
  )
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

-- The id and flag leaves are strict and opaque; checking them to WHNF is
-- enough (and avoids reaching into @bytestring@ / @text@ internals).
deriving via OnlyCheckWhnf TraceId instance NoThunks TraceId

deriving via OnlyCheckWhnf SpanId instance NoThunks SpanId

deriving via OnlyCheckWhnf TraceFlags instance NoThunks TraceFlags

deriving via OnlyCheckWhnf TraceState instance NoThunks TraceState

deriving stock instance Generic SpanContext

deriving anyclass instance NoThunks SpanContext

deriving stock instance Generic SpanKind

deriving anyclass instance NoThunks SpanKind

deriving stock instance Generic SpanStatus

deriving anyclass instance NoThunks SpanStatus

-- | Check the span itself and its strict scalar fields deeply; check the
-- intentionally spine-lazy container fields (and the timestamps) to WHNF.
--
-- Each field is bound with a bang before being handed to @nothunks@. Record
-- selectors are lazy, so @noThunks ctx (spanContext s)@ would otherwise inspect
-- the /selector application/ itself (an unevaluated thunk) and report a false
-- positive. The fields are strict, so forcing the projection to WHNF is a
-- no-op semantically and leaves any genuine nested thunk below WHNF intact for
-- the deep checks to find.
instance NoThunks Span where
  showTypeOf _ = "Span"
  wNoThunks ctx s = noThunks ctx (OnlyCheckWhnf s)
  noThunks ctx s =
    allNoThunks
      [ noThunks ctx (OnlyCheckWhnf s)
      , noThunks ("spanContext" : ctx) sContext
      , noThunks ("spanParentContext" : ctx) sParent
      , noThunks ("spanName" : ctx) sName
      , noThunks ("spanKind" : ctx) sKind
      , noThunks ("spanStartTime" : ctx) (OnlyCheckWhnf sStart)
      , noThunks ("spanEndTime" : ctx) (OnlyCheckWhnf sEnd)
      , noThunks ("spanAttributes" : ctx) (OnlyCheckWhnf sAttrs)
      , noThunks ("spanEvents" : ctx) (OnlyCheckWhnf sEvents)
      , noThunks ("spanLinks" : ctx) (OnlyCheckWhnf sLinks)
      , noThunks ("spanStatus" : ctx) sStatus
      ]
    where
      !sContext = spanContext s
      !sParent = spanParentContext s
      !sName = spanName s
      !sKind = spanKind s
      !sStart = spanStartTime s
      !sEnd = spanEndTime s
      !sAttrs = spanAttributes s
      !sEvents = spanEvents s
      !sLinks = spanLinks s
      !sStatus = spanStatus s

-- | A traced computation that exercises every span field kind: scalar and array
-- attributes, an event, a status, and a nested child span.
program :: (Tracer :> es) => Eff es ()
program =
  withSpan "root" $ do
    addAttribute "service" ("checkout" :: Text)
    addAttribute "items" (3 :: Int)
    addAttributes
      [ "tags" .= (["fast", "cart"] :: [Text])
      , "codes" .= ([200, 404] :: [Int])
      ]
    addEvent "cache.miss" ["key" .= ("session:42" :: Text)]
    withSpan "child" $ do
      addAttribute "db.rows" (12 :: Int)
      setStatus Ok
    setStatus Ok

tests :: TestTree
tests =
  testGroup
    "Thunk retention"
    [ testCase "completed spans carry no unexpected thunk" $ do
        spans <- captureSpans program
        case spans of
          [] -> assertFailure "expected the traced computation to produce spans"
          _ -> mapM_ assertNoThunks spans
    ]

-- | Run a traced program through the in-memory interpreter and return the
-- captured spans.
captureSpans :: Eff '[Tracer, IOE] a -> IO [Span]
captureSpans p = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemory captured p
  readCapturedSpans captured

assertNoThunks :: Span -> IO ()
assertNoThunks s = do
  result <- noThunks [] s
  case result of
    Nothing -> pure ()
    Just info -> assertFailure ("unexpected thunk in completed span: " <> show info)
