# effectful-tracing

[![CI](https://github.com/joshburgess/effectful-tracing/actions/workflows/ci.yml/badge.svg)](https://github.com/joshburgess/effectful-tracing/actions/workflows/ci.yml)
[![Hackage](https://img.shields.io/badge/hackage-not%20yet%20released-lightgrey.svg)](#)
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

> Status: preparing the first release (`0.1.0.0`). All the planned interpreters
> (no-op, in-memory, pretty-print, OpenTelemetry), W3C Trace Context
> propagation, sampling, async context propagation, and the WAI / http-client
> instrumentation helpers have landed. See `PROJECT_BUILD_PLAN.md` for the full
> roadmap.

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

Two optional helpers cover the common server seams. Each is behind a cabal flag
(off by default), so the base package never pulls in a web stack:

- `Effectful.Tracing.Instrumentation.Wai` (flag `wai`): a `Middleware` that opens
  a `server` span per request and continues an inbound distributed trace.
- `Effectful.Tracing.Instrumentation.HttpClient` (flag `http-client`): a wrapper
  that opens a `client` span and injects the trace context into outbound
  requests.

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
  (trace an existing function, sampling, connecting HTTP traces, workers).
- [`docs/design-notes.md`](docs/design-notes.md): why the library is built the
  way it is.
- [`examples/servant-app`](examples/servant-app): an end-to-end Servant service.

## Supported GHC

- GHC 9.10.3

## License

BSD-3-Clause. See [LICENSE](LICENSE).
