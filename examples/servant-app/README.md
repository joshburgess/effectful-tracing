# servant-app: end-to-end tracing example

A minimal [Servant](https://hackage.haskell.org/package/servant-server) service
that shows the two `effectful-tracing` instrumentation helpers cooperating to
produce a single distributed trace, exported to a local Jaeger over OTLP.

It has two endpoints:

- `GET /checkout` opens a `server` span (via `traceMiddleware`), then calls
  `GET /inventory` through `httpLbsTraced`, which opens a `client` span and
  injects a `traceparent` header.
- `GET /inventory` receives that `traceparent`, so `traceMiddleware` continues
  the same trace rather than starting a new one.

The handlers are written directly in `Eff`, so the server span the middleware
opened is the active span while the handler runs. That is what makes the
outbound `client` span nest under it. A `hoistServer` natural transformation
(`liftIO . runInIO`) bridges `Eff` handlers to Servant's `Handler`.

## Run it

Start a local Jaeger with an OTLP endpoint:

```
docker compose up -d
```

Then build and run the service (the example's `cabal.project` turns on the
`otel`, `wai`, and `http-client` flags of the in-tree library):

```
cabal run servant-app
```

In another terminal, drive a request:

```
curl localhost:8080/checkout
```

Open the Jaeger UI at <http://localhost:16686>, pick the `servant-app` service,
and find the trace. You should see one trace shaped like:

```
checkout.handler        (server)
└─ GET                  (client)   http.request.method=GET  url.full=.../inventory
   └─ inventory.handler (server)
```

`checkout.handler` carries the `checkout.cart` attribute; the `client` span
carries `http.request.method` / `url.full` / `http.response.status_code`; and `inventory.handler`
carries the `inventory.read` event. All three share one trace id because the
`traceparent` injected by `httpLbsTraced` is continued by `traceMiddleware`.

The OTLP exporter defaults to `http://localhost:4318`; override it with
`OTEL_EXPORTER_OTLP_ENDPOINT` if your collector lives elsewhere.
