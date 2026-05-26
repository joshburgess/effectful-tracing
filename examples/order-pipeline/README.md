# order-pipeline: database + messaging tracing example

A small order pipeline that shows the `effectful-tracing` messaging and database
bindings cooperating across two processes to produce a single distributed trace
per order, exported to a local Jaeger over OTLP.

It is one executable with two subcommands:

- `order-pipeline produce` opens a `submit-order` span per order and publishes it
  to a RabbitMQ queue through
  [`publishMsgTraced`](../../src/Effectful/Tracing/Instrumentation/Amqp.hs),
  which writes the active span's `traceparent` into the message headers.
- `order-pipeline consume` drains the queue. For each message it opens a
  `process` span with `withProcessSpan`, which reads that `traceparent` back out
  of the headers so the span continues the producer's trace, and inside it writes
  a row to PostgreSQL through the traced `postgresql-simple` runner
  ([`Pg.execute`](../../src/Effectful/Tracing/Instrumentation/PostgresqlSimple.hs)).

Because the trace context rides in the message headers, the producer and the
consumer join into one trace even though they are separate processes (and, in a
real deployment, separate services).

## Run it

Start PostgreSQL, RabbitMQ, and Jaeger:

```
docker compose up -d
```

Wait a few seconds for RabbitMQ to finish booting, then publish some orders (the
example's `cabal.project` turns on the `otel`, `amqp`, and `postgresql-simple`
flags of the in-tree library):

```
cabal run order-pipeline -- produce
```

Then process them in the same or another terminal:

```
cabal run order-pipeline -- consume
```

The consumer drains the queue, writes each order to the `orders` table, and stops
once the queue has been empty for a few polls. You can confirm the rows landed:

```
docker compose exec postgres psql -U postgres -c 'SELECT * FROM orders;'
```

## What you see in Jaeger

Open the Jaeger UI at <http://localhost:16686>. There is one trace per order,
and it spans both the `order-producer` and `order-consumer` services:

```
submit-order        (order-producer, internal)
└─ send orders      (order-producer, producer)   messaging.system=rabbitmq
   └─ process orders (order-consumer, consumer)   messaging.operation.type=process
      └─ INSERT      (order-consumer, client)     db.system.name=postgresql
```

The `submit-order`, `send orders`, `process orders`, and `INSERT` spans share one
trace id because the `traceparent` injected on publish is continued on the
consumer side.

The `consume` side also emits standalone `receive orders` spans in the
`order-consumer` service: those are the act of polling the queue, which is
consumer infrastructure rather than work caused by any one order, so by design
they form their own short traces instead of joining a producer's.

## Configuration

The defaults match the bundled `docker-compose.yml`; override any of them with
environment variables:

- `AMQP_URI` (default `amqp://guest:guest@localhost:5672`)
- `DATABASE_URL` (default `postgresql://postgres:postgres@localhost:5432/postgres`)
- `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`)

## Tear down

```
docker compose down -v
```
