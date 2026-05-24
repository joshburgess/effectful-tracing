# Cookbook

Short, focused recipes for everyday tracing tasks. Each one is independent;
skip to the one you need. The [tutorial](tutorial.md) is the place to start if
you want the guided tour instead.

## Trace an existing function

You have a function and you want a span around it. Add the `Tracer` constraint
and wrap the body in `withSpan`. Nothing about what the function returns or how
callers use it changes.

```haskell
-- Before:
loadUser :: (Database :> es) => UserId -> Eff es User
loadUser uid = queryUser uid

-- After:
loadUser :: (Database :> es, Tracer :> es) => UserId -> Eff es User
loadUser uid = withSpan "loadUser" $ queryUser uid
```

If a function cannot take the constraint (it is called from a context with no
`Tracer` in the effect row), trace at the nearest caller that does have it. The
span still covers the work; it just names the caller's view of it.

The span closes when the body returns *or throws*. An exception propagating out
of `withSpan` is recorded as an event on the span and sets the span status to
`Error` automatically, so you do not need a `catch` just to mark failures.

## Attach structured fields to a span

Annotate the active span with typed attributes and timeline events. None of
these take the span as an argument: they apply to whatever span is lexically
current, and are silent no-ops when there is none.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Effectful.Tracing

handleOrder :: (Tracer :> es) => Order -> Eff es ()
handleOrder order = withSpan "handleOrder" $ do
  -- One attribute at a time.
  addAttribute "order.id" (orderId order)        -- Text
  addAttribute "order.total_cents" (totalCents order)  -- Int
  -- Or several at once with (.=), which infers the attribute type.
  addAttributes
    [ "customer.tier" .= tierName order   -- Text
    , "order.express" .= isExpress order  -- Bool
    , "order.line_count" .= lineCount order  -- Int
    ]
  -- A point on the span's timeline, with its own attributes.
  addEvent "payment.authorized" ["gateway" .= ("stripe" :: Text)]
```

Attribute values are typed: `Text`, `String`, `Bool`, `Int`, `Double`, and
homogeneous lists of those. Prefer stable, low-cardinality keys (`order.id` over
a freeform message) so backends can index and group on them.

## Sample 1% but keep more of what matters

Sampling here is *head sampling*: the decision is made once, when the span
starts, before you know whether the work will fail. So a plain head sampler
cannot literally "keep 100% of errors", because at span-start there is no error
yet. There are two honest ways to get close.

**1. Force-sample work you already know is important.** If the caller knows up
front that an operation is high-value or risky, set an initial attribute and
have a custom `Sampler` honor it, falling back to 1% otherwise. A `Sampler` is
just a record, so you can compose the built-ins:

```haskell
import Effectful.Tracing
import Effectful.Tracing.Sampler
  ( Sampler (..)
  , SamplerInput (initialAttributes)
  , SamplingDecision (RecordAndSample)
  , simpleResult
  , traceIdRatioBased
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrBool))

-- 1% of traces by default, but always sample a span whose caller flagged it
-- with `sampling.priority = True`.
priorityOr1Percent :: Sampler
priorityOr1Percent =
  Sampler
    { samplerName = "PriorityOr1Percent"
    , shouldSample = \input ->
        if flagged (initialAttributes input)
          then pure (simpleResult RecordAndSample)
          else shouldSample (traceIdRatioBased 0.01) input
    }
  where
    flagged = any (\(Attribute k v) -> k == "sampling.priority" && v == AttrBool True)
```

Callers opt a span in by starting it with that attribute:

```haskell
import Effectful.Tracing (SpanArguments (attributes), defaultSpanArguments, withSpan')

riskyCharge :: (Tracer :> es) => Eff es ()
riskyCharge =
  withSpan' "charge" defaultSpanArguments { attributes = ["sampling.priority" .= True] } $
    doTheCharge
```

**2. Keep everything cheaply, decide later.** For "keep all errors" in the
general case, the right tool is *tail sampling* in your collector, which sees
the whole finished trace. Run this library with a generous head sampler (or
`alwaysOn`) into an OpenTelemetry Collector configured with its
`tail_sampling` processor to drop the boring traces and keep every errored one.
Head sampling and tail sampling compose: head decides what to emit, the
collector decides what to retain.

Wrap your chosen sampler into an interpreter the usual way:

```haskell
runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemoryWith priorityOr1Percent captured action
  readCapturedSpans captured
```

## Connect inbound and outbound HTTP traces

To make one distributed trace span an inbound request and the outbound calls it
triggers, use the two instrumentation helpers together (cabal flags `wai` and
`http-client`). The middleware continues any inbound `traceparent` and opens a
`server` span; the client wrapper opens a `client` span *under* it and injects
`traceparent` into the next hop.

```haskell
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)

-- The request handler runs in Eff, so the server span opened by the middleware
-- is the active span while the handler runs. Any httpLbsTraced call inside it
-- therefore nests under the server span and shares its trace.
handler :: (IOE :> es, Tracer :> es) => Manager -> Eff es Response
handler manager = do
  req <- liftIO (parseRequest "http://users.internal/profile")
  profile <- httpLbsTraced req manager   -- client span, child of the server span
  buildResponse profile
```

The key is that the handler must run *inside* `Eff` (under the same unlift the
middleware used) rather than in plain `IO`, so the active span is still in scope
when the outbound call fires. If you call `httpLbsTraced` from code that has lost
the server span, it starts a fresh root trace instead. To deliberately continue
a trace received out of band (for example from a message queue header), use
`extractContext` and `withRemoteParent`:

```haskell
import Effectful.Tracing (extractContext, withRemoteParent)

consume :: (Tracer :> es) => [Header] -> Eff es a -> Eff es a
consume headers work =
  maybe id withRemoteParent (extractContext headers) work
```

## Instrument a long-running worker

A worker that loops forever should not open one giant span for its whole
lifetime; that span never closes and tells you nothing. Open one span per unit
of work instead, so each iteration is its own short trace.

```haskell
import Control.Monad (forever)

worker :: (Tracer :> es, Queue :> es) => Eff es ()
worker = forever $ do
  job <- takeJob
  -- One root span per job: it opens when the job starts and closes when the
  -- iteration ends, so each job is an independent trace you can find and time.
  withSpan "worker.handleJob" $ do
    addAttribute "job.id" (jobId job)
    process job
```

For a job that you want to *spawn* and not wait on, where nesting it under the
launching span would be misleading (the parent has long since returned), use
`forkLinked` from `Effectful.Tracing.Concurrent`. It starts the work as a new
root span with a link back to where it came from, so the causal connection is
preserved without a parent/child relationship that outlives its parent:

```haskell
import Effectful.Tracing.Concurrent (forkLinked)

enqueueBackground :: (Tracer :> es, Concurrent :> es) => Eff es ()
enqueueBackground = withSpan "request" $ do
  _ <- forkLinked (withSpan "background.reindex" doReindex)
  pure ()  -- returns immediately; the background span lives on as its own trace
```
