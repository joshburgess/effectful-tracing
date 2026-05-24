-- The instrumented wrappers carry a @Tracer :> es@ constraint as part of their
-- contract (they are meant for traced code and guarantee a tracer is in scope),
-- even though propagation is automatic and does not call any Tracer operation.
-- That makes the constraint redundant to GHC, so silence the warning here; the
-- constraint is intentional API, not an oversight. (forkLinked does use Tracer.)
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module      : Effectful.Tracing.Concurrent
-- Description : Span-propagating wrappers around effectful's concurrency.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Helpers that spawn concurrent work while propagating the current span, so a
-- @withSpan@ in a forked thread nests under the span that launched it. This is
-- the Haskell answer to the part of Rust's @tracing@ that @Instrument@ solves.
--
-- == Why these are thin wrappers
--
-- The active span is __lexical__: the live interpreter keeps it in a private
-- handler-local value, not a shared mutable stack (see
-- "Effectful.Tracing.Internal.Live"). @effectful@'s concurrency combinators
-- ("Effectful.Concurrent", "Effectful.Concurrent.Async") clone the effect
-- environment at the point of the fork, so the child thread starts with exactly
-- the active span that was in scope when it was spawned. Propagation is
-- therefore automatic, and these functions are 'Effectful.Concurrent.forkIO',
-- 'Effectful.Concurrent.Async.async', and friends with a @'Tracer' ':>' es@
-- constraint that documents intent and pins the relationship at the point of
-- the fork. Had the active span been a shared stack, the child would race the
-- parent for the stack top and this phase would be a swamp of races; it is not,
-- because the representation was chosen to avoid exactly that.
--
-- == Parent versus link
--
-- The default ('forkInstrumented', 'asyncInstrumented', and the rest) is
-- __inherit as parent__: forked spans are children of the launching span, which
-- is what you want for concurrent work that is logically part of the same unit
-- (a fan-out of requests whose results you wait on). For fire-and-forget
-- background work whose lifetime is unrelated to the caller, that parent/child
-- nesting is misleading. 'forkLinked' instead starts the work as a new root
-- trace with a __link__ back to the launching span: a "caused by" reference
-- rather than "child of".
--
-- == Gotchas
--
-- Only the helpers in this module propagate. A bare
-- @'Control.Monad.IO.Class.liftIO' ('Control.Concurrent.forkIO' ...)@ escapes
-- the effect system entirely and carries no span, and so does anything that
-- runs an action through a raw 'IO' callback (for example a third-party library
-- that takes an @IO ()@ worker). Spawn through these wrappers, or re-establish
-- context inside the thread, to keep the trace connected.
module Effectful.Tracing.Concurrent
  ( -- * Inherit the launching span as parent
    forkInstrumented
  , asyncInstrumented
  , concurrentlyInstrumented
  , forConcurrentlyInstrumented

    -- * Link instead of nest
  , forkLinked
  ) where

import Control.Concurrent (ThreadId)

import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent, forkIO)
import Effectful.Concurrent.Async (Async, async, concurrently, forConcurrently)

import Effectful.Tracing.Effect (Tracer, getActiveSpan, withLinkedRoot)
import Effectful.Tracing.Internal.Types (Link (Link))

-- | Fork a thread whose work nests under the current span. A 'withSpan' inside
-- the forked action opens a child of the span that was active at the fork; with
-- no active span it opens a root, exactly as it would in the launching thread.
forkInstrumented
  :: (Tracer :> es, Concurrent :> es)
  => Eff es ()
  -> Eff es ThreadId
forkInstrumented = forkIO

-- | Spawn an 'Async' whose span is a child of the launching span. The result is
-- awaited with the usual "Effectful.Concurrent.Async" combinators
-- (@wait@, @waitCatch@, and so on).
asyncInstrumented
  :: (Tracer :> es, Concurrent :> es)
  => Eff es a
  -> Eff es (Async a)
asyncInstrumented = async

-- | Run two actions concurrently, each as a child of the launching span, and
-- return both results once both finish. If either throws, the other is
-- cancelled and the exception is re-raised (standard @concurrently@ semantics);
-- the throwing branch's span is closed with an 'Effectful.Tracing.Error' status.
concurrentlyInstrumented
  :: (Tracer :> es, Concurrent :> es)
  => Eff es a
  -> Eff es b
  -> Eff es (a, b)
concurrentlyInstrumented = concurrently

-- | Map a tracing action over a list concurrently, each call a child of the
-- launching span.
forConcurrentlyInstrumented
  :: (Tracer :> es, Concurrent :> es)
  => [a]
  -> (a -> Eff es b)
  -> Eff es [b]
forConcurrentlyInstrumented = forConcurrently

-- | Fork fire-and-forget work that is __linked__ to, rather than nested under,
-- the current span. The forked action runs detached, so its first 'withSpan'
-- starts a new root trace; that root carries a 'Link' back to the span that was
-- active at the fork, recording the "caused by" relationship. With no active
-- span this is just 'forkInstrumented' (there is nothing to link to).
--
-- Use this for background work whose lifetime outlives the caller (a cache
-- warm, a deferred index rebuild), where threading the caller's trace through
-- would distort the parent's duration and tree.
forkLinked
  :: (Tracer :> es, Concurrent :> es)
  => Eff es ()
  -> Eff es ThreadId
forkLinked body = do
  caller <- getActiveSpan
  let links = maybe [] (\context -> [Link context []]) caller
  forkInstrumented (withLinkedRoot links body)
