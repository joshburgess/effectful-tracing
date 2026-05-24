{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.PrettyPrintLeakSpec
-- Description : The pretty-print interpreter's in-flight buffer drains to empty.
--
-- The pretty-print interpreter buffers the spans of each in-flight trace in a
-- @'TVar' ('Map' 'TraceId' ['Span'])@ and flushes a trace (rendering it and
-- deleting its entry) the moment its root span closes. If a finished trace were
-- ever left behind, that map would grow without bound over the lifetime of a
-- long-running process: a slow memory leak.
--
-- This test drives a program through the buffer-observing seam
-- ('runTracerPrettyWith') and checks two things: while a root span is still open
-- its already-closed children are held in the buffer (so the buffering is real,
-- not a no-op), and once every root has closed the buffer is empty again (so
-- nothing is retained). It also confirms every trace was actually rendered.
module Effectful.Tracing.PrettyPrintLeakSpec
  ( tests
  ) where

import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.ByteString.Lazy qualified as BL

import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Internal.Ids (TraceId)
import Effectful.Tracing.Internal.Types (Span)
import Effectful.Tracing.Interpreter.PrettyPrint
  ( defaultPrettyPrintConfig
  , runTracerPrettyWith
  )

tests :: TestTree
tests =
  testGroup
    "Pretty-print interpreter buffer"
    [ testCase "the in-flight buffer accumulates and then drains to empty" $ do
        (mid, finalSize, headerCount) <- runWithBuffer
        -- While "root-1" is open, its two already-closed children are buffered
        -- under one trace id, so the buffer holds one trace of two spans.
        mid @?= (1, 2)
        -- Once every root has closed, the buffer retains nothing.
        finalSize @?= 0
        -- All three independent root traces were flushed (rendered) exactly once.
        headerCount @?= 3
    ]

-- | Run a program with three independent root traces through the
-- buffer-observing interpreter seam, returning: the buffer snapshot taken while
-- the first root is still open (number of in-flight traces, total spans
-- buffered across them), the buffer size after the whole program finishes, and
-- the number of rendered trace headers in the output.
runWithBuffer :: IO ((Int, Int), Int, Int)
runWithBuffer =
  withSystemTempFile "pretty-leak.txt" $ \path h -> do
    traces <- newTVarIO Map.empty
    mid <- runEff (runTracerPrettyWith traces (defaultPrettyPrintConfig h) (program traces))
    finalSize <- Map.size <$> readTVarIO traces
    hClose h
    rendered <- TE.decodeUtf8 . BL.toStrict <$> BL.readFile path
    let headerCount = length (filter ("trace " `T.isPrefixOf`) (T.lines rendered))
    pure (mid, finalSize, headerCount)

-- | Three root traces. The first opens two children that close (and so are
-- buffered) before the root does; in that window we snapshot the buffer. The
-- next two roots simply exercise another insert/delete cycle each.
program :: TVar (Map TraceId [Span]) -> Eff '[Tracer, IOE] (Int, Int)
program traces = do
  mid <- withSpan "root-1" $ do
    withSpan "child-a" (pure ())
    withSpan "child-b" (pure ())
    -- Both children have closed and been buffered under root-1's trace id;
    -- root-1 is still open, so nothing has been flushed. Snapshot the buffer.
    snapshot <- liftIO (readTVarIO traces)
    pure (Map.size snapshot, sum (map length (Map.elems snapshot)))
  withSpan "root-2" (withSpan "only-child" (pure ()))
  withSpan "root-3" (pure ())
  pure mid
