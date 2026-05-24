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
import Effectful (runEff)
import Effectful.Tracing.Interpreter.InMemory
  (newCapturedSpans, readCapturedSpans, runTracerInMemoryWith)

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
import Control.Monad.IO.Class (liftIO)
import Effectful (Eff, IOE, (:>))
import Effectful.Tracing (Tracer)
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
import Network.HTTP.Client (Manager, parseRequest)

-- 'Response' and 'buildResponse' are your application's own response type and
-- builder; 'httpLbsTraced' returns an 'http-client' 'Response' you map into them.
--
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
import Network.HTTP.Types (Header)

consume :: (Tracer :> es) => [Header] -> Eff es a -> Eff es a
consume headers work =
  maybe id withRemoteParent (extractContext headers) work
```

## Interoperate with B3 (Zipkin) headers

When the other side of a hop speaks B3 rather than W3C Trace Context (Zipkin,
Envoy, older meshes), swap in the B3 propagator from
`Effectful.Tracing.Propagation.B3`. It mirrors the W3C functions: `extractContextB3`
reads either the single `b3` header or the legacy `X-B3-*` multi-header form (the
single header wins when both are present), and `injectContextB3` writes the single
header (`injectContextB3Multi` writes the multi-header form).

```haskell
import Effectful (Eff, (:>))
import Effectful.Tracing (Tracer, withRemoteParent)
import Effectful.Tracing.Propagation.B3 (extractContextB3, injectContextB3)
import Network.HTTP.Types (Header)

-- inbound: continue a B3 caller's trace
b3Consume :: (Tracer :> es) => [Header] -> Eff es a -> Eff es a
b3Consume headers =
  maybe id withRemoteParent (extractContextB3 headers)

-- outbound: forward the active span as a single b3 header
b3Forward :: (Tracer :> es) => Eff es [Header]
b3Forward = injectContextB3
```

## Carry application context as baggage

When you want a value to ride along with the trace and be readable by every
downstream service (a tenant id, a request priority, an experiment bucket), use
**baggage** rather than a span attribute. Baggage is ambient: it is in scope for
everything that runs within it, not attached to one span, and it propagates
across hops through the `baggage` header. The `Effectful.Tracing.Baggage` effect
holds it; `Effectful.Tracing.Propagation.Baggage` renders and parses the header.

```haskell
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Baggage
  (BaggageContext, getBaggage, lookupBaggageValue, runBaggageWith, withBaggageEntry)
import Effectful.Tracing.Propagation.Baggage (extractBaggage, injectBaggage)
import Network.HTTP.Types (Header)

-- inbound: seed the ambient baggage from the request and discharge the effect,
-- so everything in 'work' runs with that baggage in scope
serveWithBaggage :: [Header] -> Eff (BaggageContext : es) a -> Eff es a
serveWithBaggage headers = runBaggageWith (extractBaggage headers)

-- read a baggage value anywhere in scope, with no plumbing through arguments
priorityOf :: (BaggageContext :> es) => Eff es (Maybe Text)
priorityOf = lookupBaggageValue "request.priority" <$> getBaggage

-- add an entry for a sub-scope, and forward all baggage to the next hop
handle :: (BaggageContext :> es, Tracer :> es) => Eff es [Header]
handle = withBaggageEntry "request.priority" "high" $ withSpan "handle" $
  injectBaggage   -- the outbound `baggage` header, carrying "request.priority"
```

Note `runBaggageWith` (or `runBaggage` to start empty) must wrap the computation
to discharge the `BaggageContext` effect, just as an interpreter discharges
`Tracer`. Baggage and span attributes are independent: putting a key in baggage
does not attach it to any span. Copy it onto a span explicitly with
`addAttribute` if you also want it recorded there.

## Name server spans by route, not just method

`traceMiddleware` names each server span after the request method (`GET`,
`POST`), which is deliberately low-cardinality. When your routing layer knows the
matched route template, `traceMiddlewareWith` lets you name spans
`"{method} {route}"`, which is far more useful in a trace list. Pass a route
*template* (`/users/{id}`), not the raw path (`/users/9921`), or you reintroduce
the high cardinality you were avoiding.

```haskell
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient)
import Effectful.Tracing.Instrumentation.Wai (traceMiddlewareWith)
import Network.Wai (Request, rawPathInfo, requestMethod)

-- Illustrative: this uses the raw path. In a real app, pass the matched route
-- template from your router instead of 'rawPathInfo'.
nameByRoute :: Request -> Text
nameByRoute req =
  decodeUtf8Lenient (requestMethod req) <> " " <> decodeUtf8Lenient (rawPathInfo req)

-- Then wrap your app with `traceMiddlewareWith nameByRoute runInIO app`.
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

## Assert on traces in your tests

To check that your own instrumentation emits the spans you expect, run the code
under the in-memory interpreter and assert on the captured spans.
`Effectful.Tracing.Testing` bundles the capture interpreter together with pure
matchers (`findSpan`, `childrenOf`, `isChildOf`, `hasStatus`, `lookupAttribute`,
and friends), so you do not have to reach into the internals. The matchers are
plain `Bool` / `Maybe`, so they pair with whatever assertion library you use.

```haskell
import Effectful (runEff)
import Effectful.Tracing (SpanStatus (Ok), addAttribute, setStatus, withSpan)
import Effectful.Tracing.Attribute (AttributeValue (AttrInt))
import Effectful.Tracing.Testing
  ( findSpan
  , hasStatus
  , isChildOf
  , isRoot
  , lookupAttribute
  , newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )
import Test.Tasty.HUnit (assertBool, (@?=))

-- A test that the handler opens a root span with an Ok status and a child
-- "db.query" span carrying the row count.
checkHandlerTrace :: IO ()
checkHandlerTrace = do
  spans <- runEff $ do
    captured <- newCapturedSpans
    runTracerInMemory captured $
      withSpan "handler" $ do
        setStatus Ok
        withSpan "db.query" (addAttribute "db.rows" (1 :: Int))
    readCapturedSpans captured
  case (findSpan "handler" spans, findSpan "db.query" spans) of
    (Just handler, Just db) -> do
      assertBool "handler is a root" (isRoot handler)
      assertBool "db.query is a child of handler" (db `isChildOf` handler)
      hasStatus Ok handler @?= True
      lookupAttribute "db.rows" db @?= Just (AttrInt 1)
    _ -> assertBool "both spans were captured" False
```

## Customize the pretty-printed output

`defaultPrettyPrintConfig` shows attributes and events, no color, and durations
only. `PrettyPrintConfig` is a plain record, so override the fields you want.
There is no terminal auto-detection: set `useColor` yourself, for example from
`hIsTerminalDevice`.

```haskell
import Effectful (runEff)
import Effectful.Tracing.Interpreter.PrettyPrint
  (PrettyPrintConfig (..), TimeFormat (RelativeToTraceStart), defaultPrettyPrintConfig, runTracerPretty)
import System.IO (hIsTerminalDevice, stderr)

-- Colorize only when stderr is a terminal, show offsets from the trace start,
-- and hide events to keep the tree compact.
run action = do
  color <- hIsTerminalDevice stderr
  let config =
        (defaultPrettyPrintConfig stderr)
          { useColor = color
          , showEvents = False
          , timeFormat = RelativeToTraceStart
          }
  runEff (runTracerPretty config action)
```

`TimeFormat` is one of `DurationOnly` (the default), `RelativeToTraceStart`
(`+12ms (8ms)`), or `Absolute` (wall-clock start plus duration).
