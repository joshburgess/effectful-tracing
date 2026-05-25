{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Effectful.Tracing.Effect
-- Description : The @Tracer@ effect and its smart-constructor API.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- The 'Tracer' effect, modeled as a dynamic @effectful@ effect because tracing
-- has many valid interpretations (no-op, in-memory, OpenTelemetry export). The
-- only higher-order operation is 'WithSpan', which runs a scoped action inside
-- a fresh child span; the rest are first-order emit operations against the
-- currently-active span.
--
-- This module exposes the raw effect constructors so interpreters can pattern
-- match on them. End users should program against the smart constructors
-- ('withSpan', 'addAttribute', and friends), which hide @send@ and the
-- constructor types. The public "Effectful.Tracing" module re-exports the smart
-- constructors and 'Tracer' as an abstract type.
module Effectful.Tracing.Effect
  ( -- * The effect
    Tracer (..)

    -- * Span arguments
  , SpanArguments (..)
  , defaultSpanArguments

    -- * Scoping a span
  , withSpan
  , withSpan'
  , withLinkedRoot
  , withRemoteParent

    -- * Annotating the active span
  , addAttribute
  , addAttributes
  , addEvent
  , recordException
  , setStatus
  , updateName
  , getActiveSpan

    -- * Status transitions
  , transitionStatus
  ) where

import Control.Exception (SomeException)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Stack (HasCallStack)

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Effectful.Tracing.Attribute (Attribute, AttributeValue, ToAttributeValue, toAttributeValue)
import Effectful.Tracing.Internal.Types
  ( Link
  , SpanContext
  , SpanKind (Internal)
  , SpanStatus (..)
  )

-- | Tracing as a scoped effect. 'WithSpan' is higher-order: it runs the scoped
-- action @m a@ inside a child span whose parent is the lexically-current active
-- span. 'WithLinkedRoot' is also higher-order: it detaches the active span for
-- its scope (so a nested 'WithSpan' starts a new root trace) while recording
-- links to the spans that caused the work. 'WithRemoteParent' is the inbound
-- counterpart: it makes a remote span context the active parent for its scope,
-- so a nested 'WithSpan' continues that remote trace. The remaining operations
-- annotate the active span and are no-ops when there is none (see
-- "Effectful.Tracing.Effect#no-active-span").
data Tracer :: Effect where
  WithSpan :: Text -> SpanArguments -> m a -> Tracer m a
  WithLinkedRoot :: [Link] -> m a -> Tracer m a
  WithRemoteParent :: SpanContext -> m a -> Tracer m a
  AddAttribute :: Text -> AttributeValue -> Tracer m ()
  AddAttributes :: [Attribute] -> Tracer m ()
  AddEvent :: Text -> [Attribute] -> Tracer m ()
  RecordException :: SomeException -> Tracer m ()
  SetStatus :: SpanStatus -> Tracer m ()
  UpdateName :: Text -> Tracer m ()
  GetActiveSpan :: Tracer m (Maybe SpanContext)

type instance DispatchOf Tracer = Dynamic

-- | Optional parameters for a new span. A record (rather than positional
-- arguments) so new fields can be added without breaking callers, who build it
-- from 'defaultSpanArguments' with record updates.
data SpanArguments = SpanArguments
  { kind :: !SpanKind
  -- ^ The span's role in the trace. Defaults to 'Internal'.
  , attributes :: ![Attribute]
  -- ^ Attributes to attach at span start.
  , links :: ![Link]
  -- ^ Links to other spans (causal references outside the parent/child tree).
  , startTime :: !(Maybe UTCTime)
  -- ^ An explicit start time; 'Nothing' means "now" at the moment the span
  -- opens.
  }

-- | The default arguments: an 'Internal' span with no initial attributes or
-- links and an implicit "now" start time.
--
-- > withSpan' "db.query" defaultSpanArguments { kind = Client } $ do
-- >   ...
defaultSpanArguments :: SpanArguments
defaultSpanArguments =
  SpanArguments
    { kind = Internal
    , attributes = []
    , links = []
    , startTime = Nothing
    }

-- | Run an action inside a new child span with the given name and default
-- arguments. The span opens before the action runs and is closed (with its end
-- time, and 'Error' status if the action throws) when it returns or unwinds.
--
-- > total :: Tracer :> es => Eff es Int
-- > total = withSpan "compute.total" $ do
-- >   addAttribute "items" (3 :: Int)
-- >   pure 6
withSpan
  :: (HasCallStack, Tracer :> es)
  => Text
  -> Eff es a
  -> Eff es a
withSpan name = withSpan' name defaultSpanArguments

-- | 'withSpan' with explicit 't:SpanArguments'.
--
-- > fetch :: Tracer :> es => Eff es Response
-- > fetch = withSpan' "http.get" defaultSpanArguments { kind = Client } $ do
-- >   ...
withSpan'
  :: (HasCallStack, Tracer :> es)
  => Text
  -> SpanArguments
  -> Eff es a
  -> Eff es a
withSpan' name args action = send (WithSpan name args action)

-- | Run an action detached from the current trace, recording the given links as
-- "caused by" references. Inside the scope there is no active span, so the
-- first 'withSpan' opens a new __root__ span (a new trace) rather than a child
-- of the enclosing span; the links are attached to that root. This expresses a
-- causal relationship for work that is triggered by, but does not belong to,
-- the current trace, such as fire-and-forget background tasks.
--
-- "Effectful.Tracing.Concurrent" builds @forkLinked@ on this: it captures the
-- current span context as a link and forks the body inside a linked root scope.
--
-- > withLinkedRoot [Link callerContext []] $
-- >   withSpan "background.reindex" $ ...
withLinkedRoot
  :: (HasCallStack, Tracer :> es)
  => [Link]
  -> Eff es a
  -> Eff es a
withLinkedRoot links action = send (WithLinkedRoot links action)

-- | Run an action as if it were a child of the given remote span. Inside the
-- scope the active span is the remote context, so the first 'withSpan'
-- continues that trace: it inherits the remote trace id and sampled flag and
-- records the remote span as its parent. This is how an inbound request rejoins
-- a distributed trace; pair it with 'Effectful.Tracing.Propagation.extractContext'
-- to turn @traceparent@ / @tracestate@ headers into the 't:SpanContext'.
--
-- The remote span is not local and is never emitted: this only sets the parent
-- for spans opened within the scope. Emit operations issued directly in the
-- scope (outside any 'withSpan') have no local span to annotate and are
-- dropped.
--
-- > withRemoteParent inbound $
-- >   withSpan' "handle.request" defaultSpanArguments { kind = Server } $ ...
withRemoteParent
  :: (HasCallStack, Tracer :> es)
  => SpanContext
  -> Eff es a
  -> Eff es a
withRemoteParent context action = send (WithRemoteParent context action)

-- | Attach a single attribute to the active span. No-op if there is no active
-- span.
--
-- > addAttribute "user.id" ("u123" :: Text)
addAttribute
  :: (HasCallStack, Tracer :> es, ToAttributeValue v)
  => Text
  -> v
  -> Eff es ()
addAttribute key value = send (AddAttribute key (toAttributeValue value))

-- | Attach several attributes to the active span. No-op if there is no active
-- span.
--
-- > addAttributes ["http.method" .= ("GET" :: Text), "http.status" .= (200 :: Int)]
addAttributes :: (HasCallStack, Tracer :> es) => [Attribute] -> Eff es ()
addAttributes = send . AddAttributes

-- | Record a timestamped event on the active span. No-op if there is no active
-- span.
--
-- > addEvent "cache.miss" ["key" .= ("session:42" :: Text)]
addEvent :: (HasCallStack, Tracer :> es) => Text -> [Attribute] -> Eff es ()
addEvent name attrs = send (AddEvent name attrs)

-- | Record an exception as an event on the active span. This does not set the
-- span's status; pair it with 'setStatus' if the exception is fatal. No-op if
-- there is no active span.
--
-- > recordException (toException err)
recordException :: (HasCallStack, Tracer :> es) => SomeException -> Eff es ()
recordException = send . RecordException

-- | Set the active span's status, following the OpenTelemetry transition rules
-- (see 'transitionStatus'). No-op if there is no active span.
--
-- > setStatus (Error "upstream timeout")
setStatus :: (HasCallStack, Tracer :> es) => SpanStatus -> Eff es ()
setStatus = send . SetStatus

-- | Replace the active span's name. This is OpenTelemetry's @Span.updateName@:
-- useful when the final, low-cardinality name is only known after the span has
-- opened, such as a server span that learns its matched route template once the
-- routing layer has run. No-op if there is no active span.
--
-- > updateName "GET /users/{id}"
updateName :: (HasCallStack, Tracer :> es) => Text -> Eff es ()
updateName = send . UpdateName

-- | The active span's context, or 'Nothing' if there is no active span.
--
-- > parent <- getActiveSpan
getActiveSpan :: (HasCallStack, Tracer :> es) => Eff es (Maybe SpanContext)
getActiveSpan = send GetActiveSpan

-- | Combine the current span status with a proposed one, per the OpenTelemetry
-- rules:
--
-- * 'Unset' is the default and may move to either 'Ok' or 'Error'.
-- * 'Error' may be overridden by 'Ok'.
-- * 'Ok' is final: any later transition is ignored.
-- * A status is never downgraded back to 'Unset'.
--
-- Every interpreter routes @setStatus@ through this single function so the
-- semantics stay consistent.
transitionStatus
  :: SpanStatus
  -- ^ current
  -> SpanStatus
  -- ^ proposed
  -> SpanStatus
transitionStatus current proposed =
  case current of
    Ok -> Ok
    _ -> case proposed of
      Unset -> current
      _ -> proposed
