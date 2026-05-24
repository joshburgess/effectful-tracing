{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Internal.Live
-- Description : Shared span-lifecycle handler for interpreters that open spans.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : internal
--
-- Every interpreter that actually opens and closes spans (in-memory,
-- pretty-print, OpenTelemetry) shares the same lifecycle: the active span is
-- __lexical__ (carried in a private @'Reader' ('Maybe' ActiveSpan)@ installed
-- by 'reinterpret', and set for a child scope with 'local' around the unlifted
-- action), and span finalization runs inside 'generalBracket' so a span is
-- closed exactly once even when its action is killed by an asynchronous
-- exception.
--
-- 'interpretTracer' captures that lifecycle once and parameterizes the only
-- thing the interpreters differ on: what to do with a completed 'Span'. The
-- sink is a plain @'Span' -> 'IO' ()@, which is all the in-memory (append to a
-- buffer), pretty-print (render a finished trace), and OpenTelemetry (hand to
-- an exporter) interpreters need.
--
-- This is an @.Internal.@ module: it carries no stability promise.
module Effectful.Tracing.Internal.Live
  ( interpretTracer
  ) where

import Control.Exception (SomeException, displayException)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
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
  , setSampled
  )
import Effectful.Tracing.Sampler
  ( Sampler (shouldSample)
  , SamplerInput (SamplerInput)
  , SamplingDecision (Drop, RecordAndSample)
  , SamplingResult (decision, extraAttributes, newTraceState)
  )

-- | The mutable, accumulating part of an in-flight span. Attributes and events
-- are stored newest-first and reversed when the span completes, so each emit is
-- an O(1) cons rather than an O(n) append.
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
  , activeDecision :: !SamplingDecision
  }

-- | Interpret 'Tracer' by opening a real span for each scoped action and
-- handing every completed, non-dropped 'Span' to the given sink.
--
-- The active span is lexical: scoped actions run inside a fresh child span
-- installed for their scope only, emit operations annotate the
-- lexically-current span (and are silent no-ops when there is none), and
-- 'GetActiveSpan' reports it. Finalization runs in 'generalBracket', so the
-- sink sees each span exactly once, with an 'Error' status if the action was
-- killed, and exceptions still propagate (the interpreter records, it does not
-- swallow).
--
-- The 'Sampler' is consulted once per span, at start. A 'Drop' decision still
-- runs the scoped action (the user's code must execute) and still establishes a
-- lexical span for nested operations, but the completed span is not handed to
-- the sink; 'RecordOnly' and 'RecordAndSample' both reach the sink. The
-- @sampled@ trace flag is set exactly when the decision is 'RecordAndSample',
-- and the sampler's extra attributes and trace-state replacement are applied to
-- the span.
interpretTracer
  :: IOE :> es
  => Sampler
  -> (Span -> IO ())
  -- ^ What to do with each completed span. Runs on the thread that closed the
  -- span; keep it cheap and non-blocking.
  -> Eff (Tracer : es) a
  -> Eff es a
interpretTracer sampler onComplete =
  reinterpret (runReader (Nothing :: Maybe ActiveSpan)) $ \env -> \case
    WithSpan name args action -> do
      parent <- ask
      active <- openSpan sampler name args parent
      Dynamic.localSeqUnlift env $ \unlift -> do
        let use _ = local (const (Just active)) (unlift action)
        (result, ()) <-
          generalBracket
            (pure ())
            (\_ exitCase -> do
                completed <- finalizeSpan active exitCase
                when (activeDecision active /= Drop) (liftIO (onComplete completed)))
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
-- a new trace at a root), consult the sampler, allocate a span id, set the
-- @sampled@ flag and any sampler-supplied attributes and trace state, record
-- the start time, and seed the builder.
openSpan
  :: IOE :> es
  => Sampler
  -> Text
  -> SpanArguments
  -> Maybe ActiveSpan
  -> Eff es ActiveSpan
openSpan sampler name args parent = do
  let parentContext = activeContext <$> parent
  (traceId, baseFlags, baseState) <- case parentContext of
    Just pc -> pure (spanContextTraceId pc, spanContextTraceFlags pc, spanContextTraceState pc)
    Nothing -> do
      traceId <- newTraceId
      pure (traceId, defaultTraceFlags, emptyTraceState)
  -- Built positionally: SamplerInput's field names (spanName, spanKind, links)
  -- collide with Span and SpanArguments selectors, so its labels are not
  -- imported here.
  result <-
    liftIO . shouldSample sampler $
      SamplerInput parentContext traceId name (kind args) (attributes args) (links args)
  spanId <- newSpanId
  let sampled = decision result == RecordAndSample
      context =
        SpanContext
          { spanContextTraceId = traceId
          , spanContextSpanId = spanId
          , spanContextTraceFlags = setSampled sampled baseFlags
          , spanContextTraceState = fromMaybe baseState (newTraceState result)
          , spanContextIsRemote = False
          }
  start <- maybe getTimestamp (pure . Timestamp) (startTime args)
  builder <-
    liftIO . newIORef $
      SpanBuilder
        { builderAttributes = reverse (attributes args <> extraAttributes result)
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
      , activeDecision = decision result
      }

-- | Finalize a span: record its end time, fold in an error status and exception
-- event if the action did not complete normally, and snapshot the builder into
-- an immutable 'Span'. Runs inside 'generalBracket', so it fires exactly once.
finalizeSpan
  :: IOE :> es
  => ActiveSpan
  -> ExitCase a
  -> Eff es Span
finalizeSpan active exitCase = do
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
  pure
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
