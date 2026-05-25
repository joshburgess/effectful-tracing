# Changelog

All notable changes to `effectful-tracing` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to be PVP-compliant.

## 0.1.0.0 (unreleased)

The first release: the `Tracer` effect, four interpreters (no-op, in-memory,
pretty-print, OpenTelemetry), W3C Trace Context propagation, sampling, async
context propagation, and the WAI / http-client instrumentation helpers.

### Added

- `Effectful.Tracing.SemConv`, a small module of typed constants for the
  OpenTelemetry semantic-convention attribute keys the library emits
  (`http.request.method`, `url.full`, `http.response.status_code`, and so on).
  The WAI and http-client instrumentation and the exception event now name their
  attributes from this one place, and the keys track the stable HTTP / URL
  conventions rather than the pre-stable `http.method` / `http.url` /
  `http.status_code` names. The WAI middleware now splits the request target into
  `url.path` and `url.query` (the latter only when a query string is present),
  and reports the protocol as `network.protocol.version`.
- Support for GHC 9.6 and 9.8 alongside 9.10. The `base` lower bound is relaxed
  to `>=4.18` (with `bytestring`/`text` lower bounds widened to match), and
  `foldl'` is imported from `Data.List` on bases before 4.20, where it is not yet
  re-exported from `Prelude`. CI now runs the build-and-test job across all three
  compilers, adds a job that builds and tests with every cabal flag enabled
  (`otel`, `wai`, `http-client`, `secure-ids`), and gates Haddock on broken
  doc-links. No `cabal.project.freeze` is committed, so each compiler solves its
  own consistent dependency set.
- Two release-hardening CI jobs. A `publish-readiness` job runs `cabal check`
  (the same gate Hackage applies on upload) and then builds the library and
  tests from a `cabal sdist` tarball rather than the working tree, proving the
  source distribution ships everything needed to compile. A `lower-bounds` job
  builds and tests the default package with `--prefer-oldest` on the oldest
  supported GHC (9.6.7, base 4.18), so the declared lower bounds are exercised
  rather than assumed. The optional-instrumentation flags are excluded from the
  lower-bounds job because their heavy transitive chains (the OTel stack, and a
  Warp server in the http-client tests) have oldest published versions that
  predate the supported GHC range and fail to compile there, so minimizing them
  would test third parties' GHC compatibility rather than our bounds.
- macOS and Windows coverage in CI. The build-and-test job now runs on a
  three-OS matrix: the full GHC range (9.6, 9.8, 9.10) on Linux, and the latest
  supported GHC on macOS and Windows, where a platform-specific break (path
  handling, line endings, the temp-file based interpreter tests) is most likely
  to surface. The cabal store cache path is taken from the setup action's output
  rather than hard-coded, so it resolves correctly on every runner.
- A `bench-gate` CI job that runs the `tasty-bench` suite as a regression gate.
  The realistic-op comparison uses `bcompareWithin` with a 1.20 upper bound, so
  the benchmark process exits non-zero (failing the job) on a gross per-span
  overhead regression. The bound is deliberately loose because CI runners are
  noisy shared VMs: the gate catches order-of-magnitude regressions, while the
  tighter 5% target is tracked on a quiet machine.
- New `secure-ids` cabal flag (off by default). When enabled, trace and span
  identifiers are minted from `crypton`'s cryptographically secure system
  entropy instead of the default fast splitmix PRNG, for callers who need ids
  that are unpredictable to an attacker. The `newTraceId` / `newSpanId` surface
  is unchanged; only the byte source is swapped, and `crypton` is pulled in only
  when the flag is on.
- Expanded unit and property coverage for the pure surface that the interpreter
  tests previously only exercised indirectly: `Effectful.Tracing.TypesSpec`
  (status-transition rules, trace-state dedup/capacity/validation, trace-flags
  bit manipulation), `Effectful.Tracing.AttributeSpec` (one case per
  `ToAttributeValue` instance plus the int/float widening properties),
  `Effectful.Tracing.IdsSpec` (hex parsing, byte construction, and validity
  checks), and `Effectful.Tracing.LifecycleSpec` (remote-parent continuation,
  in-thread linked roots, explicit start times, and the status/exception
  semantics). `Effectful.Tracing.SamplerSpec` also now asserts that a sampler's
  extra attributes and replacement trace state are applied to the opened span.
- Robustness and translation property tests: a fuzz suite
  (`Effectful.Tracing.FuzzSpec`) that feeds uniformly random and
  traceparent-shaped input to `extractContext`, `traceIdFromHex`,
  `spanIdFromHex`, and `traceStateFromHeader` and asserts each is total (always
  terminates, never throws) and well-formed; and a property
  (`toImmutableSpan (property)`) checking the OpenTelemetry translation is
  lossless on trace id, span id, name, kind, status, and distinct attribute
  count for any generated span.
- Thunk-retention regression test (`Effectful.Tracing.ThunkSpec`): runs a nested
  traced computation through the in-memory interpreter and asserts with
  `nothunks` that each completed `Span` carries no unexpected thunk. The check is
  deliberately precise (strict scalar structure deeply, the intentionally
  spine-lazy attribute/event/link lists to WHNF), so it guards the lifecycle's
  WHNF guarantee without false-positiving on the lazy list tails. The
  `nothunks` dependency and its orphan instances are test-only, so the published
  package takes on no new dependency. This test is what surfaced the
  `spanParentContext` retention fixed above.
- Async-exception finalization tests (`Effectful.Tracing.AsyncExceptionSpec`):
  `withSpan` finalizes its span on every exit, not just a clean return, because
  finalization runs inside `generalBracket`. These interrupt a span body three
  ways: a synchronous exception, a `timeout` cancellation, and an asynchronous
  `killThread` of a forked thread, and assert that in each case the span still
  reaches the sink with its end time set, an `Error` status, and an `exception`
  event. The `killThread` case also exercises the active span surviving a
  `forkIO`.
- Space-leak regression guard (`effectful-tracing-space-leak`): a standalone
  test executable, separate from the tasty suite, that opens and closes 100,000
  spans through the in-memory interpreter and forces every captured span with a
  strict fold, run under a deliberately tiny maximum stack (`-K1K`). A
  thunk-accumulation regression in the span lifecycle (a lazy accumulator, a
  non-strict sink write, an un-forced field) would defer that work into an O(n)
  evaluation stack and overflow the 1K limit; the current strict lifecycle runs
  it in O(1) stack. It is kept out of the tasty suite because the property tests
  legitimately need a larger stack and so cannot share these RTS options.
- Pretty-print buffer-drain test (`Effectful.Tracing.PrettyPrintLeakSpec`): the
  pretty-print interpreter buffers each in-flight trace's spans in a
  `TVar (Map TraceId [Span])` and flushes (renders and deletes) a trace the
  moment its root span closes, so a finished trace left behind would grow that
  map without bound over a long-running process. This drives a program through a
  new buffer-observing seam (`runTracerPrettyWith`) and asserts both that
  already-closed children are held while their root is still open (the buffering
  is real) and that the map is empty once every root has closed (nothing is
  retained), while confirming each trace was rendered exactly once.
- Id generator tests (`Effectful.Tracing.IdGenSpec`): the existing id tests
  pinned the codec and validity edges but never exercised the generators
  themselves, so the `secure-ids` byte source went untested. These assert that a
  freshly generated id is valid, round-trips through hex, and that a batch of
  10,000 is collision-free. They run whichever source the library was built
  with, so the all-flags CI job (`+secure-ids`) now covers the `crypton`
  system-entropy path while the default build covers the splitmix PRNG; the test
  label names which source is under test.
- Compile-checked documentation examples: `Effectful.Tracing.CompileTest` now
  mirrors every Haskell code block in `README.md`, `docs/tutorial.md`, and
  `docs/cookbook.md` against the real API, so a renamed export or changed
  signature turns the test suite red and flags the docs as stale. The blocks are
  deliberately illustrative fragments (undefined placeholder names, scattered
  imports, bare expressions), which neither cabal-docspec (it only evaluates
  `>>>` examples, of which the project has none) nor markdown-unlit can compile
  in place; the mirrors reproduce their API usage instead, stubbing the
  placeholder types once. Examples that need a cabal flag (`wai`, `http-client`,
  `otel`) are guarded with CPP so they are checked by the all-flags CI job.
- Documentation and example (Phase 10): a guided [tutorial](docs/tutorial.md)
  from a pretty-printed trace to OpenTelemetry export against a local Jaeger, a
  [cookbook](docs/cookbook.md) of focused recipes (trace an existing function,
  attach structured fields, sample but keep what matters, connect inbound and
  outbound HTTP traces, instrument a long-running worker), and a runnable
  [`examples/servant-app`](examples/servant-app) Servant service whose inbound
  `server` span and outbound `client` span join into one trace in Jaeger.
- Two runnable examples that need no collector ([`examples/local-dev`](examples/local-dev)),
  each built in CI against the in-tree library with default flags: a `worker`
  loop with one span per job, an interpreter chosen at runtime via `ET_TRACER`
  (pretty / no-op / in-memory), an error-recording span, and a linked background
  trace; and a `sampling` program that runs the cookbook's "keep all priority
  spans, ~1% of routine spans" custom sampler through the in-memory interpreter.
  The README's supported-GHC list is also corrected to name all three tested
  compilers (9.6.7 / 9.8.4 / 9.10.3) rather than only 9.10.3.
- http-client tracing wrapper (Phase 9), behind the new `http-client` cabal flag
  (off by default, so the base package does not depend on `http-client`):
  `Effectful.Tracing.Instrumentation.HttpClient` provides `httpLbsTraced`, which
  runs an `http-client` request inside a `client`-kind span. It injects the
  active context as `traceparent` / `tracestate` into the outbound request (so
  the downstream hop continues this trace), records `http.request.method` and
  `url.full` at span start and `http.response.status_code` on the response (a
  status `>= 400` sets the span status to error), and relies on the shared span
  lifecycle to record any thrown exception. The API stays in `Eff es` (no unlift
  needed); the `Manager`-hook approach is intentionally omitted because the hooks
  run in `IO` with no effect context. Attributes follow the stable OpenTelemetry
  HTTP semantic conventions. Tested against a loopback Warp server that confirms
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
  `traceparent` / `tracestate`, attaches `http.request.method`, `url.path`,
  `url.scheme`, and `network.protocol.version` at span start (plus `url.query`
  when the request carries one), records `http.response.status_code` on the
  response (a 5xx sets the span status to error; a 4xx does not), and lets the
  shared span lifecycle record any handler exception before it propagates.
  Attributes follow the stable OpenTelemetry HTTP semantic conventions. Because
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
- `Effectful.Tracing.Propagation.B3`, an alternative propagator for
  infrastructure that speaks B3 (Zipkin, Envoy, older meshes) rather than W3C
  Trace Context. It supports both wire encodings: the single `b3` header
  (`injectContextB3`) and the legacy `X-B3-*` multi-header form
  (`injectContextB3Multi`). `extractContextB3` reads either, preferring the single
  header when present. A 64-bit B3 trace id is left-padded to the library's
  128-bit width, the sampling field (`1` / `0` / `d`) maps onto the sampled bit
  (debug treated as accept), and a deferred or absent decision defaults to
  unsampled. It is built directly against the library's own `SpanContext` like
  the W3C propagator (no SDK dependency, no new dependency, no cabal flag) and is
  tested with single- and multi-header vectors plus a fuzz totality property.
- `Effectful.Tracing.Propagation.Jaeger`, a third propagator for infrastructure
  still instrumented with native Jaeger clients. `extractContextJaeger` /
  `injectContextJaeger` read and write the single `uber-trace-id` header
  (`{trace-id}:{span-id}:{parent-span-id}:{flags}`), left-padding the
  leading-zero-stripped ids Jaeger emits back to full width, treating the
  deprecated parent field as ignored, and mapping the flags low bit onto the
  sampled decision. `extractBaggageJaeger` / `injectBaggageJaeger` carry Jaeger's
  per-item `uberctx-` baggage headers to and from the `BaggageContext`. Built
  directly against the library's own `SpanContext` like the W3C and B3
  propagators (no SDK dependency, no cabal flag; the only new dependency is
  `case-insensitive`, already in the transitive set), and tested with explicit
  vectors plus a fuzz totality property.
- `Effectful.Tracing.Testing`, a one-stop module for asserting on traces in your
  own test suite. It re-exports the in-memory capture interpreter
  (`runTracerInMemory`, `newCapturedSpans`, `readCapturedSpans`) and the existing
  finders (`findSpan`, `rootSpans`, `childrenOf`), and adds pure matchers over the
  captured spans: `findSpans` (every span with a name), `descendantsOf` (the whole
  subtree), `isRoot` / `isChildOf`, `lookupAttribute` / `hasAttribute` /
  `hasAttributeValue`, `hasStatus`, `lookupEvent` / `hasEvent`, and `hasKind`. The
  matchers are plain `Bool` / `Maybe` with no test-framework dependency, so they
  compose with `tasty-hunit`, `hspec`, `hedgehog`, or anything else.
- W3C Baggage propagation: `Effectful.Tracing.Baggage` adds ambient, key-value
  context that rides alongside a trace but is independent of span attributes. A
  dynamic `BaggageContext` effect carries it the same way the active span is
  carried (lexically scoped, propagating into forked threads), with `getBaggage`,
  `withBaggageEntry` / `localBaggage`, and the `runBaggage` / `runBaggageWith`
  interpreters; the `Baggage` / `BaggageEntry` value model and its pure operations
  (`insertBaggage`, `lookupBaggageValue`, `baggageFromList`, and friends) are
  usable outside the effect too. `Effectful.Tracing.Propagation.Baggage` is the
  `baggage`-header codec: `injectBaggage` / `extractBaggage` (and the underlying
  `renderBaggage` / `parseBaggage`) percent-encode values, carry member metadata
  verbatim, trim optional whitespace, skip malformed members, and enforce the
  180-entry cap (`maxBaggageEntries`). It is built directly against the effect
  (no SDK dependency, no new dependency, no cabal flag) and the parser is covered
  by a fuzz totality property.
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

- Strictness follow-up: closed four thunk/retention spots a fresh audit
  surfaced (the data model itself was already fully strict). `finalizeSpan`
  now forces the completed `Span` to WHNF before handing it to the sink, so a
  sink that stores it (the in-memory buffer, the pretty-print accumulator) holds
  a finished value rather than a thunk retaining the span's builder `IORef`. A
  child span's `spanParentContext` is now forced past the `Maybe`: the previous
  lazy `activeContext <$> parent` left `Just (activeContext p)` as a thunk that
  retained the parent's entire `ActiveSpan` (builder `IORef` included) inside
  every completed child span. The pretty-print interpreter forces the rebuilt
  per-trace map before `writeTVar`, and the WAI middleware projects and forces
  the response status before stashing it, so the status ref no longer pins the
  whole response (body included) until the span closes. All behavior-preserving;
  the full suite passes unchanged.
- Strict-by-default posture: enabled `StrictData` and `-funbox-strict-fields`
  across the package, so record fields are strict and unboxed unless explicitly
  marked lazy. The data model already annotated its fields strict, so this is
  belt-and-suspenders rather than a behavior change, and it keeps later
  additions strict by default. The `TraceId` / `SpanId` hex encoder now uses
  `bytestring`'s builder-based `byteStringHex` instead of building an
  intermediate `String` per byte, and the OpenTelemetry event collection is
  assembled with a strict `foldl'`.
