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

> Status: early development. This README tracks the current state of the
> library and is updated as each phase lands. See `PROJECT_BUILD_PLAN.md` for
> the full roadmap.

## Install

Not yet released to Hackage. (Install snippet will go here once `0.1.0.0` is
published.)

## Quick start

Write a computation against the `Tracer` effect, then discharge it. The no-op
interpreter (`runTracerNoOp`) satisfies the effect with zero tracing and no
external dependencies, so this runs as-is. Swap in the in-memory,
pretty-print, or OpenTelemetry (later phase) interpreter without touching the
computation.

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

## Tutorial

A guided tutorial (zero to OpenTelemetry export) will live in
[`docs/tutorial.md`](docs/tutorial.md) (added in Phase 10).

## Supported GHC

- GHC 9.10.3

## License

BSD-3-Clause. See [LICENSE](LICENSE).
