{-# LANGUAGE DataKinds #-}

-- |
-- Module      : Effectful.Tracing.Interpreter.InMemory
-- Description : An interpreter that captures completed spans in memory.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- 'runTracerInMemory' captures every completed 't:Span' into a shared buffer so
-- tests can assert on what a traced computation produced. It is the workhorse
-- for testing user code that uses 'Tracer', and the reference against which the
-- later interpreters are tested.
--
-- == How to test traced code
--
-- > import Effectful (runEff)
-- > import Effectful.Tracing
-- > import Effectful.Tracing.Interpreter.InMemory
-- >
-- > test = do
-- >   captured <- newCapturedSpans
-- >   _ <- runEff . runTracerInMemory captured $
-- >     withSpan "outer" (withSpan "inner" (pure ()))
-- >   spans <- readCapturedSpans captured
-- >   -- inner closes before outer, so it is captured first:
-- >   let Just inner = findSpan "inner" spans
-- >       Just outer = findSpan "outer" spans
-- >   pure (childrenOf outer spans == [inner])
--
-- == Design
--
-- The span lifecycle (lexical active span, finalize-exactly-once under
-- 'Effectful.Exception.generalBracket') is shared with the other span-opening interpreters and
-- lives in "Effectful.Tracing.Internal.Live". This module supplies only the
-- sink: append each completed span to a shared, write-only capture buffer.
module Effectful.Tracing.Interpreter.InMemory
  ( -- * Capturing spans
    CapturedSpans
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  , runTracerInMemoryWith

    -- * Querying captured spans
  , findSpan
  , childrenOf
  , rootSpans
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.List (find)
import Data.Maybe (isNothing)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)

import Effectful (Eff, IOE, (:>))

import Effectful.Tracing.Effect (Tracer)
import Effectful.Tracing.Internal.Live (interpretTracer)
import Effectful.Tracing.Sampler (Sampler, alwaysOn)
import Effectful.Tracing.Internal.Types
  ( Span (spanContext, spanName, spanParentContext)
  , SpanContext (spanContextSpanId, spanContextTraceId)
  )

-- | A buffer of completed spans, shared across threads. Created with
-- 'newCapturedSpans' and read with 'readCapturedSpans'.
newtype CapturedSpans = CapturedSpans (TVar (Seq Span))

-- | Allocate an empty capture buffer.
newCapturedSpans :: IOE :> es => Eff es CapturedSpans
newCapturedSpans = liftIO (CapturedSpans <$> newTVarIO Seq.empty)

-- | Read the spans captured so far, in completion order (a child span, which
-- closes before its parent, appears before the parent).
readCapturedSpans :: IOE :> es => CapturedSpans -> Eff es [Span]
readCapturedSpans (CapturedSpans buffer) = liftIO (toList <$> readTVarIO buffer)

-- | Capture completed spans into the given buffer, sampling every span
-- ('alwaysOn'). Scoped actions run inside a fresh child span; emit operations
-- annotate the lexically-current span and are silent no-ops when there is none.
runTracerInMemory
  :: IOE :> es
  => CapturedSpans
  -> Eff (Tracer : es) a
  -> Eff es a
runTracerInMemory = runTracerInMemoryWith alwaysOn

-- | Like 'runTracerInMemory', but with a caller-chosen 't:Sampler'. There is no
-- export step here, so 'Effectful.Tracing.Sampler.RecordOnly' and 'Effectful.Tracing.Sampler.RecordAndSample' both capture the
-- span; only 'Effectful.Tracing.Sampler.Drop' omits it.
runTracerInMemoryWith
  :: IOE :> es
  => Sampler
  -> CapturedSpans
  -> Eff (Tracer : es) a
  -> Eff es a
runTracerInMemoryWith sampler (CapturedSpans buffer) =
  interpretTracer sampler (\completed -> atomically (modifyTVar' buffer (|> completed)))

-- | Find the first captured span with the given name.
findSpan :: Text -> [Span] -> Maybe Span
findSpan name = find ((== name) . spanName)

-- | The captured spans whose parent is the given span.
childrenOf :: Span -> [Span] -> [Span]
childrenOf parent = filter isChild
  where
    parentContext = spanContext parent
    isChild s = case spanParentContext s of
      Just pc ->
        spanContextSpanId pc == spanContextSpanId parentContext
          && spanContextTraceId pc == spanContextTraceId parentContext
      Nothing -> False

-- | The captured spans that have no parent.
rootSpans :: [Span] -> [Span]
rootSpans = filter (isNothing . spanParentContext)
