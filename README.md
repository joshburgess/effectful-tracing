# effectful-tracing

[![CI](https://github.com/joshburgess/effectful-tracing/actions/workflows/ci.yml/badge.svg)](https://github.com/joshburgess/effectful-tracing/actions/workflows/ci.yml)
[![Hackage](https://img.shields.io/badge/hackage-not%20yet%20released-lightgrey.svg)](https://hackage.haskell.org/package/effectful-tracing)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

Tracing as a scoped effect for Haskell, built natively on
[`effectful`](https://hackage.haskell.org/package/effectful), with
OpenTelemetry interop via
[`hs-opentelemetry`](https://hackage.haskell.org/package/hs-opentelemetry-sdk).

A span is a scoped, higher-order effect. That makes "the current span" lexical
instead of thread-local, which removes a whole class of context-loss bugs and
keeps the API clean. The library does not reimplement the OpenTelemetry wire
format: it compiles down to `hs-opentelemetry` for real export and ships several
other interpreters (no-op, in-memory, pretty-print) for testing and development.

> Status: preparing the first release (`0.1.0.0`). The planned interpreters
> (no-op, in-memory, pretty-print, OpenTelemetry); W3C Trace Context, B3, and
> Jaeger propagation (composable, and configurable from `OTEL_` environment
> variables); sampling; span limits; async context propagation; baggage; a
> log-correlation bridge; in-test assertions; and the instrumentation helpers for
> WAI, http-client, Servant, databases (postgresql-simple, sqlite-simple,
> valiant), and message queues have all landed.

## Install

Not yet released to Hackage. (Install snippet will go here once `0.1.0.0` is
published.)

## Quick start

Write a computation against the `Tracer` effect, then discharge it. The no-op
interpreter (`runTracerNoOp`) satisfies the effect with zero tracing and no
external dependencies, so this runs as-is. Swap in the in-memory, pretty-print,
or OpenTelemetry interpreter without touching the computation.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import Effectful (Eff, runEff, (:>))
import Effectful.Tracing

-- A computation that uses tracing without committing to a backend.
compute :: Tracer :> es => Eff es Int
compute = withSpan "outer" $ do
  addAttribute "user.id" ("u123" :: Text)
  total <- withSpan "inner" $ do
    addEvent "fetching" []
    pure 42
  setStatus Ok
  pure total

main :: IO ()
main = do
  result <- runEff (runTracerNoOp compute)
  print result
```

## Seeing your traces

During development, swap the no-op interpreter for the pretty-print one to see
the trace as a tree on stderr. The computation does not change, only the
interpreter.

```haskell
import Effectful.Tracing.Interpreter.PrettyPrint
import System.IO (stderr)

main :: IO ()
main = do
  result <- runEff (runTracerPretty (defaultPrettyPrintConfig stderr) compute)
  print result
```

prints:

```
trace 4f1a9c000000000000000000000000aa (1ms)
└─ outer (1ms) status=Ok
   user.id=u123
   └─ inner (0ms) status=Ok
      event: fetching @ +0.0ms
```

(The trace id and durations vary from run to run.) For tests, the in-memory
interpreter (`Effectful.Tracing.Interpreter.InMemory`) captures completed spans
into a buffer you can assert on.

## Instrumenting a web service

A few optional helpers cover the common server seams. Each is behind a cabal flag
(off by default), so the base package never pulls in a web stack:

- `Effectful.Tracing.Instrumentation.Wai` (flag `wai`): a `Middleware` that opens
  a `server` span per request and continues an inbound distributed trace.
- `Effectful.Tracing.Instrumentation.HttpClient` (flag `http-client`): a wrapper
  that opens a `client` span and injects the trace context into outbound
  requests.
- `Effectful.Tracing.Instrumentation.Servant` (flag `servant`): a per-endpoint
  combinator plus middleware that names server spans `"{method} {route}"` with
  the matched route template recorded as `http.route`.

Enable them when depending on the package:

```cabal
build-depends: effectful-tracing
-- in cabal.project, or via --flags on the command line:
--   --flags="wai http-client"
```

On the inbound side, wrap your application with `traceMiddleware`. Because WAI
runs in `IO` but the `Tracer` effect lives in `Eff`, the middleware takes an
unlift function from effectful's `withEffToIO`. A real server handles requests
concurrently, so use a concurrent unlift strategy:

```haskell
import Effectful
import Effectful.Tracing (Tracer)
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp

runServer :: (IOE :> es, Tracer :> es) => Application -> Eff es ()
runServer app =
  withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
    Warp.run 8080 (traceMiddleware runInIO app)
```

`traceMiddleware` names each server span after the request method (`GET`,
`POST`). When your router knows the matched route template, `traceMiddlewareWith`
lets you name spans `"{method} {route}"` instead. See the cookbook recipe "Name
server spans by route, not just method".

On the outbound side, call downstream services through `httpLbsTraced`. It opens
a `client` span and writes `traceparent` / `tracestate` into the request, so the
next service continues the same trace:

```haskell
import Control.Monad.IO.Class (liftIO)
import Effectful (Eff, IOE, (:>))
import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
import Network.HTTP.Client (Manager, Response, parseRequest)
import Data.ByteString.Lazy (ByteString)

fetchWidget :: (IOE :> es, Tracer :> es) => Manager -> Eff es (Response ByteString)
fetchWidget manager = withSpan "load.widgets" $ do
  req <- liftIO (parseRequest "https://widgets.internal/widgets")
  httpLbsTraced req manager
```

Both helpers speak W3C Trace Context (`Effectful.Tracing.Propagation`), so a
`server` span opened by the middleware and a `client` span opened by the wrapper
join into one distributed trace across the hop. To make a downstream call nest
under a specific request, run that request's handler in `Eff` so the server span
is the active span when `httpLbsTraced` runs. For a complete, runnable version of
exactly this wiring, see [`examples/servant-app`](examples/servant-app), a
two-endpoint Servant service whose inbound and outbound spans join into one trace
in Jaeger.

## Instrumenting databases and message queues

The same scoped-span approach covers the database client side and message queues,
through framework-agnostic cores that are always built (no flag, no extra
dependencies):

- `Effectful.Tracing.Instrumentation.Database`: describe a call with a
  `DatabaseQuery` and run it inside `withQuerySpan`, which opens a `client` span
  named `"{operation} {collection}"` with the stable `db.*` attributes. Thin
  driver bindings layer on top behind their own flags: `postgresql-simple`,
  `sqlite-simple`, and [`valiant`](https://hackage.haskell.org/package/valiant)
  (the compile-time checked PostgreSQL library), each a drop-in for the driver's
  own runners.
- `Effectful.Tracing.Instrumentation.Messaging`: describe a publish or consume
  with a `MessagingOperation` and run it inside `withMessagingSpan`, which picks
  the span kind from the operation (`producer` / `consumer` / `client`) and
  records the `messaging.*` conventions. `injectMessageHeaders` and
  `withConsumerSpan` carry the trace across the broker through message headers.

See the cookbook recipes "Trace a database query" and "Trace a message producer
and consumer" for runnable examples.

## Exporting to OpenTelemetry

Build with the `otel` flag and discharge the effect with `runTracerOTel`
(`Effectful.Tracing.Interpreter.OpenTelemetry`). It keeps this library's ids and
sampler as the source of truth and translates each finished span into an
`hs-opentelemetry` span for the `SpanProcessor`s you supply, so you can point it
at any OTLP collector (Jaeger, Tempo, the OpenTelemetry Collector). The
[tutorial](docs/tutorial.md) walks through wiring the OTLP exporter and bringing
up a local Jaeger with `docker compose`.

## Learning more

- [`docs/tutorial.md`](docs/tutorial.md): a guided walkthrough from a trace on
  your terminal to OpenTelemetry export, in about fifteen minutes.
- [`docs/cookbook.md`](docs/cookbook.md): short recipes for everyday tasks
  (trace an existing function, sampling, connecting HTTP traces, database queries,
  message producers and consumers, workers).
- [`docs/design.md`](docs/design.md): how the library is designed, organized by
  concept (the data model, the Tracer effect, the lifecycle, sampling,
  propagation, OTel export). Start here to understand the internals.
- [`docs/design-notes.md`](docs/design-notes.md): the chronological development
  history, phase by phase, behind that design.
- [`examples/servant-app`](examples/servant-app): an end-to-end Servant service
  whose inbound and outbound spans join into one distributed trace in Jaeger.
- [`examples/local-dev`](examples/local-dev): two small programs that need no
  collector: a worker loop (one span per job, interpreter chosen at runtime,
  error recording, a linked background trace) and a custom-sampler demo.

## Supported GHC

- GHC 9.6.7
- GHC 9.8.4
- GHC 9.10.3

## License

BSD-3-Clause. See [LICENSE](LICENSE).
