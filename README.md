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

The runnable quick start lands with the no-op and pretty-print interpreters
(Phases 3 and 5). It will look roughly like this:

```haskell
-- placeholder, not yet runnable
example :: (Tracer :> es, IOE :> es) => Eff es Int
example = withSpan "outer" $ do
  addAttribute "user.id" ("u123" :: Text)
  withSpan "inner" $ do
    addEvent "fetching" []
    pure 42
```

## Tutorial

A guided tutorial (zero to OpenTelemetry export) will live in
[`docs/tutorial.md`](docs/tutorial.md) (added in Phase 10).

## Supported GHC

- GHC 9.10.3

## License

BSD-3-Clause. See [LICENSE](LICENSE).
