# local-dev: runnable examples, no collector required

Two small programs that exercise `effectful-tracing` against its default
in-tree build (no cabal flags, no OpenTelemetry, nothing external to run). They
print to your terminal, so you can see the behavior immediately. For the
distributed, OpenTelemetry-exporting example, see
[`../servant-app`](../servant-app) instead.

The example's `cabal.project` points at the in-tree library, so both programs
build against your working copy.

## `worker`: one span per job, and choosing an interpreter at runtime

A worker processes a fixed batch of jobs, each inside its own span (with a
nested `db.fetch` child span and an event). One job throws: its span is still
finalized with an `Error` status and an `exception` event before the exception
propagates, and the worker carries on. Finally it spawns a fire-and-forget
background task with `forkLinked`, which becomes its own root trace with a link
back to the span that launched it.

Pick the interpreter with the `ET_TRACER` environment variable:

```
cabal run worker                  # pretty-print each finished trace to stderr
ET_TRACER=memory cabal run worker # capture spans in memory, print a summary
ET_TRACER=noop   cabal run worker # tracing compiles to nothing (prod default)
```

The pretty interpreter colorizes only when stderr is a terminal and renders
times as offsets from each trace's start. You should see one tree per job
(`worker.handleJob` with a `db.fetch` child), the `reconcile` job's tree marked
`status=Error`, and a separate `background.reindex` trace.

## `sampling`: a custom sampler, observed in memory

A runnable version of the cookbook's "sample 1% but keep more of what matters"
recipe. `PriorityOr1Percent` keeps any span a caller flags with
`sampling.priority = True` and otherwise defers to a 1% trace-id ratio sampler.
The program runs a batch through the in-memory interpreter and reports how many
spans of each kind survived:

```
cabal run sampling
```

All priority spans are kept (an exact count); the routine count is random but
lands near 1% of the spans started.
