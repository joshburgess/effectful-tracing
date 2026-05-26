{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A two-process order pipeline that exercises the messaging and database
-- bindings together, exported to a local Jaeger over OTLP.
--
-- @order-pipeline produce@ opens a @submit-order@ span per order and publishes
-- it to a RabbitMQ queue through 'Amqp.publishMsgTraced', which writes the
-- active span's @traceparent@ into the message headers.
--
-- @order-pipeline consume@ drains that queue. For each message it opens a
-- @process@ span with 'Amqp.withProcessSpan' (which reads the @traceparent@ back
-- out of the headers, so the span continues the producer's trace) and, inside
-- it, writes a row to PostgreSQL through the traced @postgresql-simple@ runner.
--
-- The result in Jaeger is one trace per order, spanning both processes:
-- @submit-order@ -> @send orders@ (producer) -> @process orders@ (consumer) ->
-- @INSERT@ (database client).
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Tracing (Tracer, addAttribute, alwaysOn, withSpan)
import Effectful.Tracing.Instrumentation.Amqp qualified as Amqp
import Effectful.Tracing.Instrumentation.PostgresqlSimple qualified as Pg
import Effectful.Tracing.Interpreter.OpenTelemetry (OtelConfig (..), runTracerOTel)
import Effectful.Tracing.SpanLimits (defaultSpanLimits)

import Database.PostgreSQL.Simple qualified as PgRaw
import Network.AMQP
  ( Ack (Ack)
  , Channel
  , Connection
  , ackEnv
  , closeConnection
  , declareQueue
  , fromURI
  , msgBody
  , msgID
  , newMsg
  , newQueue
  , openChannel
  , openConnection''
  , queueName
  )
import OpenTelemetry.Exporter.OTLP.Span (loadExporterEnvironmentVariables, otlpExporter)
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)
import OpenTelemetry.Processor.Span (SpanProcessor)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["produce"] -> runProducer
    ["consume"] -> runConsumer
    _ -> do
      hPutStrLn stderr "usage: order-pipeline (produce | consume)"
      exitFailure

-- | The queue (and, on the default exchange, the routing key) orders flow over.
queueText :: Text
queueText = "orders"

-- | Open a RabbitMQ connection from @AMQP_URI@ (or a local default), failing
-- with a clear message if the URI does not parse.
connectAmqp :: IO Connection
connectAmqp = do
  uri <- fromMaybe "amqp://guest:guest@localhost:5672" <$> lookupEnv "AMQP_URI"
  case fromURI uri of
    Left err -> fail ("invalid AMQP_URI: " <> err)
    Right opts -> openConnection'' opts

-- | The PostgreSQL connection string, from @DATABASE_URL@ or a local default.
pgConnInfo :: IO BS8.ByteString
pgConnInfo =
  BS8.pack . fromMaybe "postgresql://postgres:postgres@localhost:5432/postgres"
    <$> lookupEnv "DATABASE_URL"

-- | A batch span processor wired to the OTLP exporter, which reads
-- @OTEL_EXPORTER_OTLP_ENDPOINT@ (defaulting to @http://localhost:4318@).
-- 'runTracerOTel' force-flushes it when its scope ends, so a short-lived run
-- still exports before the process exits.
mkProcessor :: IO SpanProcessor
mkProcessor = do
  exporter <- loadExporterEnvironmentVariables >>= otlpExporter
  batchProcessor batchTimeoutConfig exporter

runProducer :: IO ()
runProducer = do
  processor <- mkProcessor
  let config =
        OtelConfig
          { spanProcessors = [processor]
          , instrumentationScope = "order-producer"
          , sampler = alwaysOn
          , spanLimits = defaultSpanLimits
          }
  conn <- connectAmqp
  chan <- openChannel conn
  _ <- declareQueue chan newQueue {queueName = queueText}
  runEff . runTracerOTel config $
    forM_ [1 .. 3 :: Int] $ \n -> do
      let orderId = "order-" <> T.pack (show n)
          body = "widget x" <> T.pack (show n)
      withSpan "submit-order" $ do
        addAttribute "order.id" orderId
        _ <-
          Amqp.publishMsgTraced
            chan
            ""
            queueText
            newMsg
              { msgID = Just orderId
              , msgBody = BL.fromStrict (encodeUtf8 body)
              }
        liftIO (putStrLn ("published " <> T.unpack orderId))
  closeConnection conn
  putStrLn "Done. Run `order-pipeline consume` to process them."

runConsumer :: IO ()
runConsumer = do
  processor <- mkProcessor
  let config =
        OtelConfig
          { spanProcessors = [processor]
          , instrumentationScope = "order-consumer"
          , sampler = alwaysOn
          , spanLimits = defaultSpanLimits
          }
  conn <- connectAmqp
  chan <- openChannel conn
  _ <- declareQueue chan newQueue {queueName = queueText}
  pgConn <- PgRaw.connectPostgreSQL =<< pgConnInfo
  ensureSchema pgConn
  putStrLn "Draining the orders queue..."
  runEff . runTracerOTel config $ drain chan pgConn 0
  PgRaw.close pgConn
  closeConnection conn

-- | Poll the queue, processing each message until five consecutive polls come
-- back empty, then stop. The @receive@ span 'Amqp.getMsgTraced' opens belongs to
-- the consumer's own (local) trace; the @process@ span 'Amqp.withProcessSpan'
-- opens continues the producer's trace, since it reads the @traceparent@ off the
-- message. That is the OpenTelemetry-recommended split: polling is consumer
-- infrastructure, processing is work caused by one specific message.
drain :: (IOE :> es, Tracer :> es) => Channel -> PgRaw.Connection -> Int -> Eff es ()
drain chan pgConn emptyPolls
  | emptyPolls >= 5 = liftIO (putStrLn "No more messages; stopping.")
  | otherwise = do
      received <- Amqp.getMsgTraced chan Ack queueText
      case received of
        Nothing -> do
          liftIO (threadDelay 500000)
          drain chan pgConn (emptyPolls + 1)
        Just (msg, env) -> do
          Amqp.withProcessSpan msg env $ do
            let orderId = fromMaybe "unknown" (msgID msg)
                body = decodeUtf8Lenient (BL.toStrict (msgBody msg))
            addAttribute "order.id" orderId
            _ <-
              Pg.execute
                pgConn
                "INSERT INTO orders (order_id, body) VALUES (?, ?)"
                (orderId, body)
            liftIO (ackEnv env)
            liftIO (putStrLn ("processed " <> T.unpack orderId))
          drain chan pgConn 0

-- | Create the @orders@ table if it does not already exist. This is plain setup,
-- not part of a traced order, so it uses the raw @postgresql-simple@ runner.
ensureSchema :: PgRaw.Connection -> IO ()
ensureSchema conn = do
  _ <-
    PgRaw.execute_
      conn
      "CREATE TABLE IF NOT EXISTS orders \
      \(order_id text NOT NULL, body text NOT NULL, \
      \processed_at timestamptz NOT NULL DEFAULT now())"
  pure ()
