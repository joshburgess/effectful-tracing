# Changelog

All notable changes to `effectful-tracing` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to be PVP-compliant.

## Unreleased

### Added

- Pretty-print interpreter (Phase 5): `runTracerPretty`, in
  `Effectful.Tracing.Interpreter.PrettyPrint`, writes a human-readable,
  tree-shaped rendering of each finished trace to a `Handle` (usually
  `stderr`) for local development. Configurable via `PrettyPrintConfig`
  (handle, color, whether to show attributes and events, and a `TimeFormat`:
  duration only, offset from trace start, or absolute). Because spans complete
  out of order, each trace is buffered in a `TVar (Map TraceId [Span])` and
  rendered as a unit the moment its root closes. The pure `renderTrace`
  formatter is exposed and is the unit of golden testing. Tests pin the layout
  with golden files (nested server/client trace, colored output, a
  relative-time variant, and a failed span) plus an end-to-end test through the
  live interpreter.
- The shared span lifecycle (lexical active span, finalize-exactly-once under
  `generalBracket`) used by every span-opening interpreter now lives in
  `Effectful.Tracing.Internal.Live`, behind a single `interpretTracer` that is
  parameterized only by a `Span -> IO ()` sink. The in-memory interpreter was
  refactored onto it with no behavior change.
- In-memory interpreter (Phase 4): `runTracerInMemory`, in
  `Effectful.Tracing.Interpreter.InMemory`, captures every completed span into
  a shared `CapturedSpans` buffer (`newCapturedSpans` / `readCapturedSpans`) so
  tests can assert on what a traced computation produced. This is the first
  interpreter that opens and closes spans, so it realizes both span decisions:
  the active span is lexical (carried in the handler's private `Reader`, so
  nested operations see their enclosing span and emits with no active span are
  silent no-ops), and span finalization runs in `generalBracket`, so a span is
  closed and emitted exactly once with an `Error` status even when killed by an
  asynchronous exception. Children inherit their parent's trace id and get a
  fresh span id; roots mint a new trace id. Query helpers `findSpan`,
  `childrenOf`, and `rootSpans` inspect the captured list. Tests cover naming,
  ordered timing, nesting, sibling structure, exception recording, async-kill
  single-close, lexical emit targeting, and a property check that captured
  spans always form a valid forest.
- No-op interpreter (Phase 3): `runTracerNoOp`, re-exported from
  `Effectful.Tracing`, discharges the `Tracer` effect with no observable
  effect: scoped actions run unchanged (exceptions propagate), emit operations
  are silent, and there is never an active span. This is the interpreter for
  components that need `Tracer` when the caller does not want tracing, and the
  baseline for the overhead benchmark. Tests cover nested-span return values,
  exception propagation, and silent emits. The `tasty-bench` benchmark
  (`bench/Main.hs`) reports the fixed per-`withSpan` cost (~15 ns, dynamic
  dispatch plus `localSeqUnlift`); spans wrapping real work stay under the 5%
  overhead target. The README quick-start now runs against `runTracerNoOp`.
- `Tracer` effect (Phase 2): tracing modeled as a dynamic `effectful` effect.
  - The effect with one higher-order operation (`WithSpan`) and first-order
    emit operations (`AddAttribute`, `AddAttributes`, `AddEvent`,
    `RecordException`, `SetStatus`, `GetActiveSpan`), in
    `Effectful.Tracing.Effect`.
  - `SpanArguments` record (`kind`, `attributes`, `links`, `startTime`) and
    `defaultSpanArguments`.
  - Smart constructors (`withSpan`, `withSpan'`, `addAttribute`,
    `addAttributes`, `addEvent`, `recordException`, `setStatus`,
    `getActiveSpan`), each with a Haddock usage example, re-exported from
    `Effectful.Tracing` with `Tracer` kept abstract.
  - `transitionStatus`, the single shared encoding of the OpenTelemetry span
    status transition rules (Ok is final; never downgrade to Unset).
  - A compile-only test proving the public API typechecks.
  - No interpreter yet: user code can be written against `Tracer` but not run.
- Core data model (Phase 1): the effect-system-independent types every
  interpreter shares.
  - `TraceId` (16 bytes) and `SpanId` (8 bytes) with fast-PRNG generation,
    byte and lowercase-hex codecs, and validity checks.
  - `Timestamp` wrapping `UTCTime`, with `getTimestamp`.
  - `AttributeValue` (scalar and homogeneous-array variants), `Attribute`, the
    `(.=)` constructor, and a `ToAttributeValue` class with instances covering
    the common scalar and list types.
  - W3C `TraceFlags` (sampled bit plus preserved reserved bits) and
    `TraceState` (validated key/value entries, capped at 32, with header
    serialization and resilient parsing).
  - `SpanContext`, `SpanKind`, `SpanStatus`, `Event`, `Link`, and the immutable
    completed-`Span` record.
  - Hedgehog generators for every public type and property tests covering hex
    round-trips, generated-id validity, trace-state round-trips and the entry
    cap, attribute coercions, and span time ordering.
- Project scaffolding (Phase 0): cabal package targeting GHC 9.10.3, a tasty
  test suite, a tasty-bench benchmark harness, hlint configuration, and a
  GitHub Actions CI workflow. No automated formatter is used. No library
  functionality yet.
