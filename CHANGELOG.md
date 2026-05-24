# Changelog

All notable changes to `effectful-tracing` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to be PVP-compliant.

## 0.1.0.0 (unreleased)

The first release: the `Tracer` effect, four interpreters (no-op, in-memory,
pretty-print, OpenTelemetry), W3C Trace Context propagation, sampling, async
context propagation, and the WAI / http-client instrumentation helpers.

### Added

- Robustness and translation property tests: a fuzz suite
  (`Effectful.Tracing.FuzzSpec`) that feeds uniformly random and
  traceparent-shaped input to `extractContext`, `traceIdFromHex`,
  `spanIdFromHex`, and `traceStateFromHeader` and asserts each is total (always
  terminates, never throws) and well-formed; and a property
  (`toImmutableSpan (property)`) checking the OpenTelemetry translation is
  lossless on trace id, span id, name, kind, status, and distinct attribute
  count for any generated span.
- Documentation and example (Phase 10): a guided [tutorial](docs/tutorial.md)
  from a pretty-printed trace to OpenTelemetry export against a local Jaeger, a
  [cookbook](docs/cookbook.md) of focused recipes (trace an existing function,
  attach structured fields, sample but keep what matters, connect inbound and
  outbound HTTP traces, instrument a long-running worker), and a runnable
  [`examples/servant-app`](examples/servant-app) Servant service whose inbound
  `server` span and outbound `client` span join into one trace in Jaeger.
- http-client tracing wrapper (Phase 9), behind the new `http-client` cabal flag
  (off by default, so the base package does not depend on `http-client`):
  `Effectful.Tracing.Instrumentation.HttpClient` provides `httpLbsTraced`, which
  runs an `http-client` request inside a `client`-kind span. It injects the
  active context as `traceparent` / `tracestate` into the outbound request (so
  the downstream hop continues this trace), records `http.method` and `http.url`
  at span start and `http.status_code` on the response (a status `>= 400` sets
  the span status to error), and relies on the shared span lifecycle to record
  any thrown exception. The API stays in `Eff es` (no unlift needed); the
  `Manager`-hook approach is intentionally omitted because the hooks run in `IO`
  with no effect context. Attributes follow the OpenTelemetry HTTP semantic
  conventions v1.20.0. Tested against a loopback Warp server that confirms
  end-to-end propagation (the server receives a `traceparent` carrying the client
  span's trace id) along with the attributes and status mapping.
- New `http-client` cabal flag gating the wrapper and its `http-client`
  dependency (`>=0.7 && <0.8`) for the library; the test suite additionally uses
  `wai` and `warp` (`>=3.3 && <3.5`) for the loopback server.
- WAI tracing middleware (Phase 9), behind the new `wai` cabal flag (off by
  default, so the base package does not depend on `wai`):
  `Effectful.Tracing.Instrumentation.Wai` provides `traceMiddleware` (and
  `traceMiddlewareWith` for custom span naming), which wraps each request in a
  `server`-kind span. It continues an inbound distributed trace by reading
  `traceparent` / `tracestate`, attaches `http.method`, `http.target`,
  `http.scheme`, and `http.flavor` at span start, records `http.status_code` on
  the response (a 5xx sets the span status to error; a 4xx does not), and lets
  the shared span lifecycle record any handler exception before it propagates.
  Attributes follow the OpenTelemetry HTTP semantic conventions v1.20.0. Because
  WAI runs in `IO`, the middleware takes an unlift function obtained with
  effectful's `withEffToIO`; a real server must use a concurrent unlift strategy.
  Tested through the in-memory interpreter (span shape, attributes, status
  mapping, remote-parent continuation, and exception handling).
- New `wai` cabal flag gating the WAI middleware and its `wai` dependency
  (`>=3.2 && <3.3`), for both the library and the test suite.
- OpenTelemetry export interpreter (Phase 8), behind the new `otel` cabal flag
  (off by default, so the base package carries no OpenTelemetry dependencies):
  `Effectful.Tracing.Interpreter.OpenTelemetry` provides `runTracerOTel`, which
  interprets `Tracer` by running the shared span lifecycle and, as each span
  finishes, translating it into an `hs-opentelemetry` `ImmutableSpan` and handing
  it to the `SpanProcessor`s in its `OtelConfig`. Pair it with an exporter and a
  processor from `hs-opentelemetry-sdk` to reach a real collector. Our trace and
  span ids and our `Sampler` run before OpenTelemetry sees the span and are
  copied verbatim into the exported span, so exported ids match the ids
  `injectContext` puts on the wire. Processors are supplied directly (the SDK
  does not expose a provider's processors) and are force-flushed when the
  interpreter's scope ends. The translation (`toImmutableSpan`) is exposed for
  testing. Note: this interpreter does not thread OpenTelemetry's in-process
  `Context`, so it will not auto-nest spans across a boundary with other
  `hs-opentelemetry`-instrumented libraries.
- New `otel` cabal flag gating the OpenTelemetry interpreter and its
  dependencies: `clock` (`>=0.8 && <0.9`) and `hs-opentelemetry-api`
  (`==0.3.1.0`) for the library, and `async` plus `hs-opentelemetry-api` for the
  test suite.
- W3C Trace Context propagation (Phase 8): `Effectful.Tracing.Propagation`
  carries a trace across a process boundary using the standard `traceparent`
  and `tracestate` headers, with no dependency on an OpenTelemetry SDK.
  `injectContext` serializes the active span's context into a header list for an
  outbound request (and emits nothing when there is no active span, so it
  composes with a base header list unconditionally); `extractContext` parses an
  inbound request's headers into a remote `SpanContext`. `withRemoteParent` (a
  new `Tracer` operation, also re-exported here) then continues that remote
  trace locally: spans opened in its scope inherit the remote trace id and
  sampled flag and record the remote span as their parent. Header lookup is
  case-insensitive, future `traceparent` versions are accepted by reading the
  first four fields, the all-zero ids and the reserved `ff` version are
  rejected, and an unparsable `tracestate` is treated as empty rather than
  failing the whole extraction (per the spec's resilience guidance). Tested with
  the W3C `traceparent` test vectors plus inject/extract round-trips through the
  in-memory interpreter.
- New library dependency on `http-types` (for the `HeaderName` type used by the
  propagation API), pinned to `>=0.12 && <0.13`.
- Async context propagation (Phase 7): `Effectful.Tracing.Concurrent` with
  span-propagating wrappers around effectful's concurrency. `forkInstrumented`,
  `asyncInstrumented`, `concurrentlyInstrumented`, and
  `forConcurrentlyInstrumented` spawn work that inherits the launching span as
  its parent, so a `withSpan` in a forked thread nests under the span that
  started it. Because the active span is a handler-local value (not a shared
  stack), effectful's environment cloning at the fork carries it to the child
  automatically, so these are thin wrappers over `forkIO` / `async` /
  `concurrently` / `forConcurrently`. `forkLinked` instead runs fire-and-forget
  work detached, starting a new root trace with a `Link` back to the caller
  ("caused by" rather than "child of"). This is backed by a new
  `withLinkedRoot` primitive (and `WithLinkedRoot` effect operation) that
  detaches the active span and stages links for the next root span. Tested
  through the in-memory interpreter (parent/sibling nesting, completion-order
  independence, exception recording and propagation, the linked-root shape, and
  a 1000-way concurrent fan-out) under a threaded runtime.
- New library dependency on the full `effectful` package (for
  `Effectful.Concurrent` and `Effectful.Concurrent.Async`), pinned to
  `==2.6.1.0` alongside `effectful-core`.
- Sampling (Phase 6): `Effectful.Tracing.Sampler` with a `Sampler`, the
  `SamplingDecision` (`Drop` / `RecordOnly` / `RecordAndSample`),
  `SamplingResult`, and `SamplerInput` data model, plus the four built-in
  samplers from the OpenTelemetry specification: `alwaysOn`, `alwaysOff`,
  `traceIdRatioBased` (a deterministic fraction keyed on the trace id, so every
  span in a trace shares one decision), and `parentBased` (inherit the parent's
  decision, fall back to a root sampler) configured via `ParentBasedConfig` /
  `defaultParentBasedConfig`. The sampler is consulted once when a span opens:
  `RecordAndSample` sets the sampled trace flag, `RecordOnly` records without
  it, and `Drop` suppresses the interpreter's sink while still running the
  scoped action. `shouldSample` is plain `IO`, so samplers are leaf decision
  functions that are easy to call and test. Both span-opening interpreters gained
  a sampler-aware entry point (`runTracerInMemoryWith`, and a `sampler` field on
  `PrettyPrintConfig`); the existing entry points default to `alwaysOn`, so
  behavior is unchanged unless a sampler is supplied.
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

### Changed

- Strict-by-default posture: enabled `StrictData` and `-funbox-strict-fields`
  across the package, so record fields are strict and unboxed unless explicitly
  marked lazy. The data model already annotated its fields strict, so this is
  belt-and-suspenders rather than a behavior change, and it keeps later
  additions strict by default. The `TraceId` / `SpanId` hex encoder now uses
  `bytestring`'s builder-based `byteStringHex` instead of building an
  intermediate `String` per byte, and the OpenTelemetry event collection is
  assembled with a strict `foldl'`.
