{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Interpreter.InMemory
-- Description : An interpreter that captures completed spans in memory.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- 'runTracerInMemory' captures every completed 'Span' into a shared buffer so
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
-- The active span is __lexical__: it lives in the handler's private
-- @'Reader' ('Maybe' ActiveSpan)@ and is installed for a child scope with
-- 'local' around the unlifted inner action, so nested operations observe their
-- lexically-enclosing span and never a racy process-wide \"current span\". The
-- only shared mutable state is the write-only capture buffer. Span finalization
-- runs inside 'generalBracket', so a span is closed and emitted exactly once
-- even if its action is killed by an asynchronous exception.
module Effectful.Tracing.Interpreter.InMemory
  ( -- * Capturing spans
    CapturedSpans
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory

    -- * Querying captured spans
  , findSpan
  , childrenOf
  , rootSpans
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Maybe (isNothing)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.Dispatch.Dynamic qualified as Dynamic
import Effectful.Exception (ExitCase (ExitCaseAbort, ExitCaseException), generalBracket)
import Effectful.Reader.Static (Reader, ask, local, runReader)

import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrText))
import Effectful.Tracing.Effect
  ( SpanArguments (attributes, kind, links, startTime)
  , Tracer
      ( AddAttribute
      , AddAttributes
      , AddEvent
      , GetActiveSpan
      , RecordException
      , SetStatus
      , WithSpan
      )
  , transitionStatus
  )
import Effectful.Tracing.Internal.Clock (Timestamp (Timestamp), getTimestamp)
import Effectful.Tracing.Internal.Ids (newSpanId, newTraceId)
import Effectful.Tracing.Internal.Types
  ( Event (Event)
  , Link
  , Span (..)
  , SpanContext (..)
  , SpanKind
  , SpanStatus (Error, Unset)
  , defaultTraceFlags
  , emptyTraceState
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

-- | The mutable, accumulating part of an in-flight span. Attributes and events
-- are stored newest-first and reversed when the span completes.
data SpanBuilder = SpanBuilder
  { builderAttributes :: ![Attribute]
  , builderEvents :: ![Event]
  , builderStatus :: !SpanStatus
  }

-- | The lexically-active span, carried in the handler's private 'Reader'. Its
-- immutable identity travels alongside an 'IORef' to the accumulating builder
-- so emit operations can mutate the span they are nested inside.
data ActiveSpan = ActiveSpan
  { activeContext :: !SpanContext
  , activeParent :: !(Maybe SpanContext)
  , activeName :: !Text
  , activeKind :: !SpanKind
  , activeStart :: !Timestamp
  , activeLinks :: ![Link]
  , activeBuilder :: !(IORef SpanBuilder)
  }

-- | Capture completed spans into the given buffer. Scoped actions run inside a
-- fresh child span; emit operations annotate the lexically-current span and are
-- silent no-ops when there is none.
runTracerInMemory
  :: IOE :> es
  => CapturedSpans
  -> Eff (Tracer : es) a
  -> Eff es a
runTracerInMemory (CapturedSpans buffer) =
  reinterpret (runReader (Nothing :: Maybe ActiveSpan)) $ \env -> \case
    WithSpan name args action -> do
      parent <- ask
      active <- openSpan name args parent
      Dynamic.localSeqUnlift env $ \unlift -> do
        let use _ = local (const (Just active)) (unlift action)
        (result, ()) <-
          generalBracket
            (pure ())
            (\_ exitCase -> closeSpan buffer active exitCase)
            use
        pure result
    AddAttribute key value ->
      withActive $ \active ->
        liftIO (modifyIORef' (activeBuilder active) (pushAttributes [Attribute key value]))
    AddAttributes attrs ->
      withActive $ \active ->
        liftIO (modifyIORef' (activeBuilder active) (pushAttributes attrs))
    AddEvent name attrs ->
      withActive $ \active -> do
        now <- getTimestamp
        liftIO (modifyIORef' (activeBuilder active) (pushEvent (Event name now attrs)))
    RecordException err ->
      withActive $ \active -> do
        now <- getTimestamp
        liftIO (modifyIORef' (activeBuilder active) (pushEvent (exceptionEvent now err)))
    SetStatus status ->
      withActive $ \active ->
        liftIO (modifyIORef' (activeBuilder active) (applyStatus status))
    GetActiveSpan -> fmap activeContext <$> ask

-- | Run an action against the active span, or do nothing if there is none.
withActive
  :: Reader (Maybe ActiveSpan) :> es
  => (ActiveSpan -> Eff es ())
  -> Eff es ()
withActive f = ask >>= maybe (pure ()) f

-- | Build a fresh 'ActiveSpan': inherit trace identity from the parent (or mint
-- a new trace at a root), allocate a span id, record the start time, and seed
-- the builder with the initial attributes.
openSpan
  :: IOE :> es
  => Text
  -> SpanArguments
  -> Maybe ActiveSpan
  -> Eff es ActiveSpan
openSpan name args parent = do
  let parentContext = activeContext <$> parent
  (traceId, flags, state) <- case parentContext of
    Just pc -> pure (spanContextTraceId pc, spanContextTraceFlags pc, spanContextTraceState pc)
    Nothing -> do
      traceId <- newTraceId
      pure (traceId, defaultTraceFlags, emptyTraceState)
  spanId <- newSpanId
  let context =
        SpanContext
          { spanContextTraceId = traceId
          , spanContextSpanId = spanId
          , spanContextTraceFlags = flags
          , spanContextTraceState = state
          , spanContextIsRemote = False
          }
  start <- maybe getTimestamp (pure . Timestamp) (startTime args)
  builder <-
    liftIO . newIORef $
      SpanBuilder
        { builderAttributes = reverse (attributes args)
        , builderEvents = []
        , builderStatus = Unset
        }
  pure
    ActiveSpan
      { activeContext = context
      , activeParent = parentContext
      , activeName = name
      , activeKind = kind args
      , activeStart = start
      , activeLinks = links args
      , activeBuilder = builder
      }

-- | Finalize a span: record its end time, fold in an error status and exception
-- event if the action did not complete normally, snapshot the builder into an
-- immutable 'Span', and append it to the capture buffer. Runs inside
-- 'generalBracket', so it fires exactly once.
closeSpan
  :: IOE :> es
  => TVar (Seq Span)
  -> ActiveSpan
  -> ExitCase a
  -> Eff es ()
closeSpan buffer active exitCase = do
  end <- getTimestamp
  case exitCase of
    ExitCaseException err ->
      liftIO . modifyIORef' (activeBuilder active) $
        applyStatus (Error (T.pack (displayException err)))
          . pushEvent (exceptionEvent end err)
    ExitCaseAbort ->
      liftIO . modifyIORef' (activeBuilder active) $
        applyStatus (Error "span aborted")
    _ -> pure ()
  builder <- liftIO (readIORef (activeBuilder active))
  let completed =
        Span
          { spanContext = activeContext active
          , spanParentContext = activeParent active
          , spanName = activeName active
          , spanKind = activeKind active
          , spanStartTime = activeStart active
          , spanEndTime = end
          , spanAttributes = reverse (builderAttributes builder)
          , spanEvents = reverse (builderEvents builder)
          , spanLinks = activeLinks active
          , spanStatus = builderStatus builder
          }
  liftIO (atomically (modifyTVar' buffer (|> completed)))

-- | Prepend attributes to a builder (stored newest-first).
pushAttributes :: [Attribute] -> SpanBuilder -> SpanBuilder
pushAttributes attrs builder =
  builder {builderAttributes = reverse attrs <> builderAttributes builder}

-- | Prepend an event to a builder (stored newest-first).
pushEvent :: Event -> SpanBuilder -> SpanBuilder
pushEvent event builder = builder {builderEvents = event : builderEvents builder}

-- | Apply a status transition (see 'transitionStatus').
applyStatus :: SpanStatus -> SpanBuilder -> SpanBuilder
applyStatus status builder =
  builder {builderStatus = transitionStatus (builderStatus builder) status}

-- | An OpenTelemetry-style @exception@ event carrying the message.
exceptionEvent :: Timestamp -> SomeException -> Event
exceptionEvent time err =
  Event "exception" time [Attribute "exception.message" (AttrText (T.pack (displayException err)))]

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
