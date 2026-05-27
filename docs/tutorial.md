# Tutorial: from zero to OpenTelemetry export

This walks you from a first trace printed on your terminal to spans exported to a
local Jaeger, then through the features you reach for in real services: span
metadata, sampling, concurrency, and automatic HTTP instrumentation. Section 1
is a complete module; each later section adds to its imports rather than
repeating the scaffolding. Read it top to bottom and you should be productive in
about fifteen minutes.

The only prerequisite is a working GHC (9.10) and `cabal`. Docker is needed only
for the final Jaeger section.

## The mental model

A span is a timed, named unit of work. `effectful-tracing` models spans as a
scoped effect: `withSpan "name" action` opens a span, runs `action` inside it,
and closes the span when the action returns or throws. The "currently active
span" is **lexical**, it follows the structure of your code rather than a
thread-local variable, so a span opened inside another span is automatically its
child.

You write your code once against the `Tracer` effect, then choose an
*interpreter* to decide what happens to the spans: discard them (`runTracerNoOp`),
print them (`runTracerPretty`), capture them for tests (`runTracerInMemory`), or
export them to OpenTelemetry (`runTracerOTel`). The traced code never changes.

## 1. Your first trace

Start with the pretty-print interpreter. It needs no infrastructure and renders a
finished trace as a tree, which is the fastest way to see what your
instrumentation is doing.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import Effectful (Eff, runEff, (:>))
import Effectful.Tracing
import Effectful.Tracing.Interpreter.PrettyPrint (defaultPrettyPrintConfig, runTracerPretty)
import System.IO (stderr)

checkout :: Tracer :> es => Eff es Int
checkout = withSpan "checkout" $ do
  addAttribute "cart.items" (3 :: Int)
  total <- withSpan "price.total" (pure 4200)
  setStatus Ok
  pure total

main :: IO ()
main = do
  total <- runEff (runTracerPretty (defaultPrettyPrintConfig stderr) checkout)
  print total
```

Running this prints a tree like:

```
trace 4f1a9c… (0ms)
└─ checkout (0ms) status=Ok
   cart.items=3
   └─ price.total (0ms)
```

Swap `runTracerPretty (defaultPrettyPrintConfig stderr)` for `runTracerNoOp` and
the same code runs with tracing fully disabled and no dependencies. That swap,
and only that swap, is how you move between backends.

## 2. Describing what happened

Inside any span you can attach metadata to the active span. None of these
require passing the span around: they annotate whatever span is lexically
current (and are silent no-ops when there is none).

```haskell
import Control.Exception (toException, ErrorCall (ErrorCall))

annotated :: Tracer :> es => Eff es ()
annotated = withSpan "handle.order" $ do
  -- A single typed attribute.
  addAttribute "order.id" ("o-9921" :: Text)
  -- Several at once, using (.=) to build them.
  addAttributes ["http.request.method" .= ("POST" :: Text), "http.response.status_code" .= (200 :: Int)]
  -- A point-in-time event on the span's timeline.
  addEvent "inventory.reserved" ["sku" .= ("widget-1" :: Text)]
  -- Record an error (does not itself end the span).
  recordException (toException (ErrorCall "downstream slow"))
  setStatus (Error "downstream slow")
```

Attribute values are typed: `Text`, `String`, `Bool`, `Int`, `Double`, and
homogeneous lists of those. The status follows the OpenTelemetry rules (`Ok` is
final, `Error` can be set over `Unset`, and a status is never downgraded).

## 3. Sampling

In production you rarely keep every trace. A `Sampler` decides, once per span at
the moment it opens, whether to drop it, record it without marking it sampled, or
record and mark it sampled. The interpreters that open spans take a sampler.

```haskell
import Effectful.Tracing.Interpreter.InMemory (newCapturedSpans, readCapturedSpans, runTracerInMemoryWith)

-- Keep a deterministic 10% of traces.
sampledRun :: Eff '[Tracer, IOE] a -> IO [Span]
sampledRun action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemoryWith (traceIdRatioBased 0.1) captured action
  readCapturedSpans captured
```

The built-in samplers are `alwaysOn`, `alwaysOff`, `traceIdRatioBased fraction`
(a deterministic fraction keyed on the trace id, so every span in a trace shares
one decision), and `parentBased` (inherit the parent's decision, fall back to a
root sampler). `parentBased` takes a `ParentBasedConfig`; the usual one is
`defaultParentBasedConfig rootSampler`, so you write
`parentBased (defaultParentBasedConfig alwaysOn)` as in section 6. See the
cookbook for "sample 1% but keep 100% of errors".

## 4. Concurrency

Because the active span is a handler-local value rather than a thread-local, it
travels across effectful's concurrency boundary automatically. The helpers in
`Effectful.Tracing.Concurrent` make spawned work nest correctly.

```haskell
import Effectful.Concurrent (Concurrent)
import Effectful.Tracing.Concurrent (concurrentlyInstrumented)

fanOut :: (Tracer :> es, Concurrent :> es) => Eff es (Int, Int)
fanOut = withSpan "fan.out" $
  -- Both branches are children of "fan.out".
  concurrentlyInstrumented
    (withSpan "left" (pure 1))
    (withSpan "right" (pure 2))
```

`asyncInstrumented` and `forConcurrentlyInstrumented` work the same way. For
fire-and-forget work that should start its *own* trace but still record where it
came from, use `forkLinked`, which detaches into a new root span with a link back
to the launching span.

## 5. Instrumenting HTTP automatically

Two optional helpers (behind the `wai` and `http-client` cabal flags) cover the
common server seams so you do not hand-write spans for every request. Enable them
with `--flags="wai http-client"`.

On the way in, wrap your WAI application; on the way out, call downstream
services through the traced wrapper. Both speak W3C Trace Context, so a request
that arrives with a `traceparent` continues the same distributed trace, and an
outbound call propagates it to the next hop.

```haskell
import Control.Monad.IO.Class (liftIO)
import Effectful
  (IOE, Limit (Unlimited), Persistence (Persistent), UnliftStrategy (ConcUnlift), withEffToIO)
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
import Network.HTTP.Client (Manager, parseRequest)
import qualified Network.Wai.Handler.Warp as Warp

-- 'myApp :: Application' is your own WAI application; the middleware wraps it.
-- Inbound: a server span per request (use a concurrent unlift for a real server).
serve :: (IOE :> es, Tracer :> es) => Eff es ()
serve =
  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    Warp.run 8080 (traceMiddleware runInIO myApp)

-- Outbound: a client span that injects traceparent into the request.
callDownstream :: (IOE :> es, Tracer :> es) => Manager -> Eff es ()
callDownstream manager = withSpan "load.profile" $ do
  req <- liftIO (parseRequest "http://users.internal/profile")
  _ <- httpLbsTraced req manager
  pure ()
```

See the "Instrumenting a web service" section of the README for the full picture.

## 6. Exporting to Jaeger

Finally, send real spans to a collector. Build with the `otel` flag and use
`runTracerOTel`, which keeps this library's ids and sampler as the source of
truth and translates each finished span into an `hs-opentelemetry` span for the
processors you supply.

Bring up a local Jaeger with an OTLP endpoint:

```yaml
# docker-compose.yml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.57
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16686:16686"   # Jaeger UI
      - "4318:4318"     # OTLP HTTP
```

```
docker compose up -d
```

Then wire the exporter and processor from `hs-opentelemetry-sdk` /
`hs-opentelemetry-exporter-otlp` into `OtelConfig`:

```haskell
import Effectful.Tracing.Interpreter.OpenTelemetry (OtelConfig (..), runTracerOTel)
import Effectful.Tracing.SpanLimits (defaultSpanLimits)
import OpenTelemetry.Exporter.OTLP.Span (otlpExporter, loadExporterEnvironmentVariables)
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)

main :: IO ()
main = do
  exporter  <- loadExporterEnvironmentVariables >>= otlpExporter
  processor <- batchProcessor batchTimeoutConfig exporter
  let config = OtelConfig
        { spanProcessors      = [processor]
        , instrumentationScope = "checkout-service"
        , sampler             = parentBased (defaultParentBasedConfig alwaysOn)
        , spanLimits          = defaultSpanLimits
        }
  total <- runEff (runTracerOTel config checkout)
  print total
```

Point the OTLP exporter at `http://localhost:4318` (its default, or set
`OTEL_EXPORTER_OTLP_ENDPOINT`), run your program, then open the Jaeger UI at
<http://localhost:16686> and find the `checkout-service` trace. The `checkout`
span and its `price.total` child appear as a tree, with the attributes and status
you set.

That is the whole arc: the `checkout` function you wrote in section 1 never
changed. You moved it from your terminal to a real distributed-tracing backend
purely by changing the interpreter.

## Where to go next

- [`cookbook.md`](cookbook.md): focused recipes for everyday tasks.
- [`design.md`](design.md): how the library is designed, organized by concept.
- The README's "Instrumenting a web service" section for the full HTTP wiring.
