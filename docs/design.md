# Design

How `effectful-tracing` is built and why. This is the thematic overview: it
explains the library's structure as it stands, organized by concept rather than
by the order things were built. If you want the chronological "how we got here"
narrative, including decisions that were revised along the way, that lives in
[`design-notes.md`](design-notes.md).

## The core idea

A span is a timed, named unit of work. This library models a span as a
**scoped, higher-order effect** on top of [`effectful`](https://hackage.haskell.org/package/effectful):

```haskell
withSpan "checkout" $ do
  addAttribute "cart.items" (3 :: Int)
  total <- withSpan "price.total" computeTotal
  setStatus Ok
  pure total
```

`withSpan` opens a span, runs the action inside it, and closes the span when the
action returns or throws. Because the span is the *scope* of an action rather
than an entry pushed onto a thread-local stack, "the currently active span" is
**lexical**: it follows the structure of your code. A `withSpan` nested inside
another is automatically the inner child of the outer, and that parent/child
relationship survives crossing `effectful`'s concurrency boundary with no manual
context plumbing.

That single decision (lexical, not thread-local) is what removes the class of
context-loss bugs that thread-local tracing APIs are prone to, and it is the
reason the rest of the design falls out as cleanly as it does.

You write instrumentation **once** against the `Tracer` effect, then choose an
*interpreter* to decide what happens to the finished spans: discard them, capture
them for tests, print them, or export them to OpenTelemetry. The traced code does
not change when you switch.

## Layering at a glance

The library is built in three layers, each depending only on the one below it:

```
                 instrumentation helpers          (WAI, http-client)
                          │
   interpreters:  no-op · in-memory · pretty-print · OpenTelemetry
                          │
              the Tracer effect + smart constructors
                          │
        effect-system-independent data model (no effectful, no OTel)
```

The bottom layer (`Effectful.Tracing.Internal.{Ids,Types,Clock}` and
`Effectful.Tracing.Attribute`) knows nothing about `effectful` or
`hs-opentelemetry`. It is the vocabulary of tracing: identifiers, attributes,
trace flags and state, span context, and the immutable record of a completed
span. Everything above is expressed in those terms.

## The data model

All of the core types are **strict in every field** (`StrictData` and
`-funbox-strict-fields` are on package-wide). Nothing in the library relies on a
lazy field: there is no tying-the-knot and no infinite structure, so strict is
always the right default here.

### Identifiers

```haskell
newtype TraceId = TraceId ByteString  -- exactly 16 bytes
newtype SpanId  = SpanId  ByteString  -- exactly 8 bytes
```

- **Generation uses a fast PRNG by default, not a CSPRNG.** Bytes come from
  `random`'s splitmix-backed generator. This is the conventional SDK approach and
  keeps per-span allocation cheap. The `secure-ids` cabal flag swaps the byte
  source to `crypton`'s cryptographically secure system entropy for callers who
  need unpredictable ids, without changing the `newTraceId` / `newSpanId` names
  or types.
- **The all-zero id (the spec's "invalid" sentinel) is never minted.** The
  generators redraw on the astronomically unlikely all-zero result.
  `isValidTraceId` / `isValidSpanId` exist for parsed or remote ids.
- The hex codec is lowercase, matching the W3C / OpenTelemetry wire form.
  Encoding runs the input through `bytestring`'s builder-based `byteStringHex`
  (one pass, no intermediate `String`); the result is ASCII, so decoding back
  to `Text` is total.

### Attributes

```haskell
data AttributeValue
  = AttrText !Text | AttrBool !Bool | AttrInt !Int64 | AttrDouble !Double
  | AttrTextArray !(Vector Text) | AttrBoolArray !(Vector Bool)
  | AttrIntArray !(Vector Int64) | AttrDoubleArray !(Vector Double)

data Attribute = Attribute { attributeKey :: !Text, attributeValue :: !AttributeValue }
```

The eight constructors encode the OpenTelemetry rule that an attribute is a
scalar or a *homogeneous* array: a heterogeneous array is simply
unrepresentable. The `ToAttributeValue` class plus the `(.=)` helper keep
construction terse (`"http.status_code" .= (200 :: Int)`), and the instances
widen the obvious way (`String`/`Text` to `AttrText`, `Int`/`Int64` to
`AttrInt`, `Float`/`Double` to `AttrDouble`).

### Trace flags and trace state

```haskell
newtype TraceFlags = TraceFlags Word8     -- only bit 0 (sampled) is defined
newtype TraceState = TraceState [(Text, Text)]  -- ordered, most-recent first
```

`TraceFlags` preserves all eight bits on round-trip; only `sampled` (bit 0) has a
defined meaning today and the reserved bits must not be masked off.
`TraceState` enforces the W3C constraints on construction: at most 32 entries,
validated key and value grammars, and most-recently-mutated-first ordering.
`insertTraceState` returns `Nothing` on an invalid entry or when the cap would
be exceeded; the header parser drops malformed members rather than failing the
whole header (per the spec's resilience guidance), so it is total.

### Span context and the completed span

```haskell
data SpanContext = SpanContext
  { spanContextTraceId :: !TraceId, spanContextSpanId :: !SpanId
  , spanContextTraceFlags :: !TraceFlags, spanContextTraceState :: !TraceState
  , spanContextIsRemote :: !Bool }

data SpanKind   = Internal | Server | Client | Producer | Consumer
data SpanStatus = Unset | Ok | Error !Text

data Span = Span
  { spanContext :: !SpanContext, spanParentContext :: !(Maybe SpanContext)
  , spanName :: !Text, spanKind :: !SpanKind
  , spanStartTime :: !Timestamp, spanEndTime :: !Timestamp
  , spanAttributes :: ![Attribute], spanEvents :: ![Event]
  , spanLinks :: ![Link], spanStatus :: !SpanStatus }
```

`Span` is the immutable record of a *completed* span. It is the value that
crosses the boundary into an interpreter for capture or export. The mutable,
during-construction representation never escapes the interpreter layer.

## The `Tracer` effect

Tracing is a **dynamic, higher-order** `effectful` effect:

```haskell
data Tracer :: Effect where
  WithSpan         :: Text -> SpanArguments -> m a -> Tracer m a
  WithLinkedRoot   :: [Link] -> m a -> Tracer m a
  WithRemoteParent :: SpanContext -> m a -> Tracer m a
  AddAttribute     :: Text -> AttributeValue -> Tracer m ()
  AddAttributes    :: [Attribute] -> Tracer m ()
  AddEvent         :: Text -> [Attribute] -> Tracer m ()
  RecordException  :: SomeException -> Tracer m ()
  SetStatus        :: SpanStatus -> Tracer m ()
  GetActiveSpan    :: Tracer m (Maybe SpanContext)
```

Dynamic dispatch (rather than a static effect) is what lets each interpreter
supply completely different behavior for the same program. Higher-order
operations (`WithSpan` and friends take a sub-computation `m a`) are what make
the span a true scope: the interpreter runs the inner action with the new span
installed and tears it down afterward.

Users write against smart constructors (`withSpan`, `addAttribute`, ...), each
re-exported from `Effectful.Tracing` with the `Tracer` type kept abstract so the
constructors cannot be pattern-matched outside the library. `SpanArguments` is a
record (`kind`, `attributes`, `links`, `startTime`) with `defaultSpanArguments`,
so the common `withSpan "name"` stays a two-argument call and the rare cases set
only the field they care about.

### Status transitions, in one place

`setStatus` follows the OpenTelemetry rules, encoded once in a pure function that
every interpreter shares:

```haskell
transitionStatus :: SpanStatus -> SpanStatus -> SpanStatus
```

- `Unset` (the default) may move to `Ok` or `Error`.
- `Error` may be overridden by `Ok`.
- `Ok` is final: any later transition is ignored.
- A status is never downgraded back to `Unset`.

### Emitting with no active span is a silent no-op

`addAttribute`, `addAttributes`, `addEvent`, `recordException`, and `setStatus`
called outside any span are silent no-ops (matching OTel's no-op span); they
never throw, and `getActiveSpan` returns `Nothing`. This is what lets you put a
`Tracer` constraint on a function and trace it from a caller that may or may not
be inside a span.

## The two load-bearing decisions

Everything that opens spans rests on two decisions. They are the heart of the
design.

### Decision A: the active span is lexical, never a shared mutable stack

The active span is carried in the handler's **private `Reader (Maybe ActiveSpan)`**,
installed with `reinterpret` and set for a child scope with `local` around the
unlifted action. It is emphatically *not* a process- or interpreter-wide
`TVar` / `IORef` "current span" stack.

A shared mutable active-span stack is the thread-local model under another name:
it races on `forkIO` and reintroduces exactly the context-loss bug this library
exists to eliminate. Keeping the active span in the `Reader` means it is part of
the effect environment, so when `effectful` clones that environment at a fork,
the child sees the right parent automatically. The *output sink* (where finished
spans accumulate) is a genuinely separate, write-only concern and may use `STM`;
the two must not be conflated.

`GetActiveSpan` simply reads this handler-local value.

### Decision B: a span closes exactly once, even when killed

`withSpan` must be async-exception safe. Finalization (record the end time, set
`Error` on an in-flight exception, emit the immutable span) has to run even when
the scoped action is killed asynchronously by `timeout`, `cancel`, or RTS
shutdown. The interpreter wraps the inner unlifted action in `generalBracket`
with appropriate masking, so the span is finalized exactly once. "Re-raise,
don't swallow" is necessary but not sufficient: without `bracket` a cancelled
action leaks an unclosed span.

## The shared lifecycle

Three interpreters open and close real spans (in-memory, pretty-print,
OpenTelemetry). They differ in exactly one way: **what to do with a completed
span.** Everything else (Decision A and Decision B, allocating ids, consulting
the sampler, accumulating attributes and events, finalizing under
`generalBracket`) is identical, so it lives once in
`Effectful.Tracing.Internal.Live` behind a single entry point:

```haskell
interpretTracer
  :: IOE :> es
  => Sampler
  -> (Span -> IO ())   -- the sink: what to do with each completed span
  -> Eff (Tracer : es) a
  -> Eff es a
```

A plain `Span -> IO ()` sink is all any interpreter needs (append to a buffer,
render a finished trace, hand to an exporter), so the shared handler never leaks
`Eff` or its private `Reader` into the sink type. The completed `Span` is forced
to WHNF before it reaches the sink, so a sink that *stores* it holds a finished
value rather than a thunk retaining the span's internal builder.

### Buffering until the root closes

Spans complete out of order: a parent's `generalBracket` cleanup runs after all
of its children's, so the full tree of a trace is not known until the root
closes. Interpreters that render or group a whole trace (pretty-print) buffer the
spans of each in-flight trace in a `TVar (Map TraceId [Span])` keyed on trace id,
and flush the trace as a unit the moment its root span closes.

## The interpreters

| Interpreter | Module | Sink behavior |
|-------------|--------|---------------|
| `runTracerNoOp` | `Interpreter.NoOp` | none: discharges `Tracer` with no observable effect |
| `runTracerInMemory` / `runTracerInMemoryWith` | `Interpreter.InMemory` | append to a `CapturedSpans` buffer you can assert on |
| `runTracerPretty` | `Interpreter.PrettyPrint` | render each finished trace as a tree to a `Handle` |
| `runTracerOTel` | `Interpreter.OpenTelemetry` (flag `otel`) | translate to an `hs-opentelemetry` span and hand to `SpanProcessor`s |

The no-op interpreter is special: it does not use the shared lifecycle at all. It
runs scoped actions unchanged (exceptions still propagate), makes emits silent,
and never has an active span. It is the interpreter for code that needs the
`Tracer` constraint when the caller does not want tracing, and the baseline for
the overhead benchmark. The fixed per-`withSpan` cost is roughly 15 ns (dynamic
dispatch plus the `localSeqUnlift`), so spans wrapping real work stay well under
the 5% overhead target.

The in-memory interpreter is the testing workhorse: `newCapturedSpans` /
`readCapturedSpans` plus `findSpan`, `childrenOf`, and `rootSpans` let a test
assert on exactly what a traced computation produced.

The pretty-print interpreter renders a finished trace as a tree on a `Handle`
(usually `stderr`) for local development. Its layout is produced by a *pure*
`renderTrace`, which is the unit of golden testing; the live interpreter is a
thin wrapper that buffers and calls it.

## Sampling

A `Sampler` decides, once per span at the moment it opens, whether to drop it,
record it without marking it sampled, or record and mark it sampled.

```haskell
data Sampler = Sampler { samplerName :: !Text, shouldSample :: SamplerInput -> IO SamplingResult }
data SamplingDecision = Drop | RecordOnly | RecordAndSample
```

- **`shouldSample` is plain `IO`, not `Eff`.** A sampler is a leaf decision
  function: easy to call, easy to test, with no effect-row plumbing. The
  interpreter calls it once when a span opens.
- **The decision drives the sink, not the user's code.** `Drop` still runs the
  scoped action and still establishes a lexical span for nested operations; it
  only suppresses the sink call, so user code behaves identically whether or not
  it was sampled. `RecordOnly` and `RecordAndSample` both reach the sink; they
  differ only in whether the `sampled` trace-flag bit is set. That bit is the
  single source of truth for "this trace is being sampled," and it propagates to
  children and across process boundaries. The OpenTelemetry interpreter is the
  one place the two recorded decisions diverge: it records locally and exports
  only `RecordAndSample`.
- **Built-ins:** `alwaysOn`, `alwaysOff`, `traceIdRatioBased fraction` (a
  deterministic fraction keyed on the trace id, so every span in a trace shares
  one decision), and `parentBased` (inherit the parent's decision, fall back to
  a root sampler) configured via `ParentBasedConfig` / `defaultParentBasedConfig`.
- **Decisions are uniform across a trace,** which avoids the "dangling parent"
  problem (a recorded child whose parent was dropped) that would produce a broken
  tree at the collector.

The default entry points (`runTracerInMemory`, `defaultPrettyPrintConfig`)
default to `alwaysOn`, so behavior is unchanged until you supply a sampler.

## Concurrency

Because the active span is a handler-local `Reader` value (Decision A) rather
than a thread-local, it travels across `effectful`'s concurrency boundary
automatically: `effectful` clones the environment at a fork, so the child thread
sees the launching span as its parent with no extra work. That makes the
concurrency helpers in `Effectful.Tracing.Concurrent` thin wrappers over
`forkIO` / `async` / `concurrently` / `forConcurrently`:

- `forkInstrumented`, `asyncInstrumented`, `concurrentlyInstrumented`,
  `forConcurrentlyInstrumented` spawn work that inherits the launching span as
  its parent (the "child of" relationship).
- `forkLinked` is different: it runs fire-and-forget work *detached*, starting a
  new root trace with a `Link` back to the caller (the "caused by" relationship).
  This is the right shape for work whose parent has long since returned, where
  nesting under the parent would be misleading. It is backed by the
  `withLinkedRoot` primitive, which detaches the active span and stages the
  links so the next root span picks them up.

## Context propagation across processes

`Effectful.Tracing.Propagation` carries a trace across a process boundary using
the standard W3C `traceparent` and `tracestate` headers, **with no dependency on
an OpenTelemetry SDK**:

- `injectContext` serializes the active span's context into a header list for an
  outbound request, and emits nothing when there is no active span (so it
  composes with a base header list unconditionally).
- `extractContext` parses an inbound request's headers into a remote
  `SpanContext`.
- `withRemoteParent` continues that remote trace locally: spans opened in its
  scope inherit the remote trace id and sampled flag and record the remote span
  as their parent. The remote context is marked `isRemote = True`, and the
  synthetic active span standing in for it is never finalized or emitted (it is
  not ours to emit).

Parsing is **strict where it matters and lenient where the spec says to be**:
header lookup is case-insensitive, future `traceparent` versions are accepted by
reading the first four fields, the all-zero ids and the reserved `ff` version are
rejected, and an unparsable `tracestate` is treated as empty rather than failing
the whole extraction.

## OpenTelemetry export

`runTracerOTel` (behind the `otel` flag) interprets `Tracer` by running the
shared lifecycle and, as each span finishes, translating it into an
`hs-opentelemetry` `ImmutableSpan` and handing it to the `SpanProcessor`s in its
`OtelConfig`.

The defining choice is that **identity stays ours.** Our trace and span ids and
our `Sampler` run *before* OpenTelemetry sees the span, and are copied verbatim
into the exported span. The benefit is that the ids `injectContext` puts on the
wire are exactly the ids that reach the collector, so propagation and export
never disagree. The cost is that the library reimplements a small translation
layer (`toImmutableSpan :: OTel.Tracer -> Span -> Either String OTel.ImmutableSpan`)
rather than getting it free from the SDK; the `Either` is total (it only fails on
a malformed id, which our own minting never produces) and exists mainly to give
the round-trip tests something to assert on.

Two consequences worth knowing:

- **Processors are passed in directly, not pulled from a provider**, because the
  SDK does not expose a provider's processors. They are force-flushed when the
  interpreter's scope ends.
- **The interpreter does not thread OpenTelemetry's in-process `Context`,** so it
  will not auto-nest spans across a boundary with *other*
  `hs-opentelemetry`-instrumented libraries. Within this library's own spans,
  nesting is exact; mixing span trees with a second OTel-instrumented library in
  the same process is out of scope by design.

## Instrumentation helpers

Two optional helpers cover the common HTTP seams, each behind a cabal flag (off
by default) so the base package never pulls in a web stack.

### WAI middleware (`wai` flag)

`traceMiddleware` (and `traceMiddlewareWith` for custom span names) wraps each
request in a `server`-kind span. It continues an inbound distributed trace by
reading `traceparent` / `tracestate`, attaches the `http.*` request attributes at
span start, records `http.status_code` on the response (a 5xx sets the span
status to error; a 4xx does not, because a client error is not the server's
fault), and lets the shared lifecycle record any handler exception before it
propagates.

The interesting seam is that **WAI runs in `IO` but the `Tracer` effect lives in
`Eff`.** The middleware takes an unlift function obtained from `effectful`'s
`withEffToIO`; a real server handles requests concurrently, so it must use a
concurrent unlift strategy (`ConcUnlift Persistent Unlimited`). The response
status is captured by wrapping the responder, and the projected `Status` is
forced before it is stashed so the status ref does not pin the whole response
until the span closes.

On span naming: `traceMiddleware` names each span after the request *method*
(`GET`, `POST`), which is deliberately low-cardinality.
`traceMiddlewareWith` lets you name spans `"{method} {route}"` when your router
knows the matched route *template* (not the raw path, which would reintroduce the
high cardinality).

### http-client wrapper (`http-client` flag)

`httpLbsTraced` runs an `http-client` request inside a `client`-kind span. It is
a **request wrapper, not a `Manager` hook**, because the hooks run in `IO` with
no effect context, whereas the wrapper stays in `Eff es` (no unlift needed). It
injects the active context as `traceparent` / `tracestate` into the outbound
request *inside* the span (so the downstream hop continues this trace), records
`http.method` / `http.url` at start and `http.status_code` on the response (a
status `>= 400` sets the span status to error), and relies on the shared
lifecycle to record any thrown exception.

Both helpers speak W3C Trace Context, so a `server` span opened by the middleware
and a `client` span opened by the wrapper join into one distributed trace across
the hop, provided the handler runs *inside* `Eff` so the server span is active
when the outbound call fires. The attribute sets follow the OpenTelemetry HTTP
semantic conventions v1.20.0.

## Strictness posture

The library is strict by default: `StrictData` and `-funbox-strict-fields` are on
package-wide, every data field is strict, and there are no `foldl`, lazy
`WriterT`, `Data.Map.Lazy`, or unprimed `modifyIORef` patterns. The accumulating
state (per-span attribute and event lists, the trace buffers) is held in strict
records mutated with `modifyIORef'` / `modifyTVar'`.

Three completed-value handoffs are forced explicitly so a thunk does not retain
more than the value it represents:

1. `finalizeSpan` returns the completed span via `pure $!`, so a storing sink
   holds a finished `Span` rather than a thunk retaining the span's builder
   `IORef` and active-span record.
2. The pretty-print interpreter forces the rebuilt per-trace map before
   `writeTVar`.
3. The WAI middleware projects and forces the response `Status` before stashing
   it, so the ref does not pin the whole response body until the span closes.

The wire-format parsers (`extractContext`, `traceIdFromHex`, `spanIdFromHex`,
`traceStateFromHeader`) consume untrusted bytes, so their most important contract
is **totality**: on any input they terminate and return a value, never loop and
never throw. A fuzz suite asserts this directly against both uniformly random and
`traceparent`-shaped input.

## Module surface and stability

`Effectful.Tracing` is the public entry point. It re-exports the data model, the
`Tracer` effect and smart constructors (with `Tracer` kept abstract), the
sampling and propagation surface, and the no-op interpreter. The span-opening
interpreters live in their own modules:

- `Effectful.Tracing.Interpreter.InMemory`
- `Effectful.Tracing.Interpreter.PrettyPrint`
- `Effectful.Tracing.Interpreter.OpenTelemetry` (flag `otel`)
- `Effectful.Tracing.Instrumentation.Wai` (flag `wai`)
- `Effectful.Tracing.Instrumentation.HttpClient` (flag `http-client`)

`Effectful.Tracing.Internal.*` modules are exposed so power users and the bridge
can reach them, but they are not re-exported and carry no stability promise. The
heavier dependencies (OpenTelemetry, WAI, http-client) sit behind the manual
cabal flags above, all off by default, so the base package stays light.

## See also

- [`tutorial.md`](tutorial.md): a guided walkthrough from a terminal trace to
  OpenTelemetry export.
- [`cookbook.md`](cookbook.md): focused recipes for everyday tasks.
- [`design-notes.md`](design-notes.md): the chronological development history,
  phase by phase, including decisions that were later revised. This document is
  the consolidated overview of where that history landed.
