{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Effectful.Tracing.CompileTest
-- Description : Compile-only checks that the public API and the documented
--               examples still typecheck.
--
-- Two compile-only checks, both of which turn the test suite red if the public
-- surface stops typechecking. Neither runs.
--
-- * @smart-constructor API typechecks@ pins the core emit/lifecycle surface to
--   a concrete effect stack.
-- * @documentation examples typecheck@ mirrors the code blocks in @README.md@,
--   @docs/tutorial.md@, and @docs/cookbook.md@. Those blocks are deliberately
--   pedagogical fragments (undefined placeholder names, scattered imports, bare
--   expressions), so they cannot be compiled in place by cabal-docspec or
--   markdown-unlit. Instead each is reproduced here against the real API: a
--   renamed export or changed signature breaks this module, flagging the docs
--   as stale. The placeholder types and effects are stubbed once below. This
--   checks the API shapes the docs use, not the literal doc bytes, so prose
--   edits that change a call still need the matching mirror updated here.
module Effectful.Tracing.CompileTest
  ( tests
  ) where

import Control.Exception (ErrorCall (ErrorCall), toException)
import Data.Text (Text)

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, runEff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Dispatch.Dynamic (send)
import Network.HTTP.Types (Header)
import System.IO (hIsTerminalDevice, stderr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing
  ( Span
  , SpanArguments (attributes, kind)
  , SpanContext
  , SpanKind (Client)
  , SpanStatus (Error, Ok)
  , Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , alwaysOn
  , defaultParentBasedConfig
  , defaultSpanArguments
  , extractContext
  , getActiveSpan
  , parentBased
  , recordException
  , setStatus
  , traceIdRatioBased
  , withRemoteParent
  , withSpan
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrBool, AttrInt))
import Effectful.Tracing.EnvConfig
  ( EnvConfig (resourceAttributes, serviceName, traceContextPropagators, tracesSampler)
  , readEnvConfig
  )
import Effectful.Tracing.Baggage
  ( BaggageContext
  , getBaggage
  , lookupBaggageValue
  , runBaggageWith
  , withBaggageEntry
  )
import Control.Monad.IO.Class (liftIO)
import Effectful.Tracing.Instrumentation.Database
  ( DatabaseQuery (queryCollection, queryOperation, queryText)
  , databaseQuery
  , withQuerySpan
  )
import Effectful.Tracing.Instrumentation.Messaging
  ( MessagingOperation (messagingDestination)
  , MessagingOperationType (Process, Send)
  , injectMessageHeaders
  , messagingOperation
  , withConsumerSpan
  , withMessagingSpan
  )
import Effectful.Tracing.Propagation.B3 (extractContextB3, injectContextB3)
import Effectful.Tracing.Propagation.Baggage (extractBaggage, injectBaggage)
import Effectful.Tracing.Propagation.Composite
  ( BaggagePropagator
  , TraceContextPropagator
  , b3Single
  , extractBaggageAll
  , extractContextFirst
  , injectBaggageAll
  , injectContextAll
  , jaegerBaggage
  , w3cBaggage
  , w3cTraceContext
  )
import Effectful.Tracing.Log (activeCorrelationFields)
import Effectful.Tracing.Propagation.Jaeger
  ( extractBaggageJaeger
  , extractContextJaeger
  , injectContextJaeger
  )
import Effectful.Tracing.Testing
  ( findSpan
  , hasStatus
  , isChildOf
  , isRoot
  , lookupAttribute
  , runTracerInMemory
  )
import Effectful.Tracing.Concurrent (concurrentlyInstrumented, forkLinked)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemoryWith
  , runTracerInMemoryWithLimits
  )
import Effectful.Tracing.Interpreter.NoOp (runTracerNoOp)
import Effectful.Tracing.Interpreter.PrettyPrint
  ( PrettyPrintConfig (showEvents, timeFormat, useColor)
  , TimeFormat (RelativeToTraceStart)
  , defaultPrettyPrintConfig
  , runTracerPretty
  )
import Effectful.Tracing.Sampler
  ( Sampler (Sampler, samplerName, shouldSample)
  , SamplerInput (initialAttributes)
  , SamplingDecision (RecordAndSample)
  , simpleResult
  )
import Effectful.Tracing.SpanLimits
  ( SpanLimits (attributeValueLengthLimit, eventCountLimit)
  , defaultSpanLimits
  )

#ifdef WAI
import Data.Text.Encoding (decodeUtf8Lenient)
import Network.Wai (Application, Request, rawPathInfo, requestMethod)
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware, traceMiddlewareWith)
#endif

#ifdef HTTP_CLIENT
import Network.HTTP.Client (Manager, Response, parseRequest)
import Data.ByteString.Lazy (ByteString)
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
#endif

#ifdef POSTGRESQL_SIMPLE
import Database.PostgreSQL.Simple (Connection, Only (..))
import Effectful.Tracing.Instrumentation.PostgresqlSimple qualified as Pg
#endif

#ifdef SQLITE_SIMPLE
import Database.SQLite.Simple qualified as SqliteDb
import Effectful.Tracing.Instrumentation.SqliteSimple qualified as Sqlite
#endif

#ifdef VALIANT
import Data.Int (Int64)
import Valiant (Statement, mkStatement)
import Valiant.Effectful (Valiant)
import Effectful.Tracing.Instrumentation.Valiant qualified as ValiantT
#endif

#ifdef SERVANT
import Data.Proxy (Proxy (Proxy))
#ifndef WAI
import Network.Wai (Application)
#endif
import Servant (Capture, Get, PlainText, Server, serve, type (:<|>) ((:<|>)))
import Servant qualified as Sv
import Effectful.Tracing.Instrumentation.Servant (WithSpanName, traceServantMiddleware)
#endif

#ifdef OTEL
import Effectful.Tracing.Interpreter.OpenTelemetry (OtelConfig (..), runTracerOTel)
#endif

tests :: TestTree
tests =
  testGroup
    "Compile-only checks"
    [ testCase "smart-constructor API typechecks" (compiles @?= ())
    , testCase "documentation examples typecheck" (docExamples @?= ())
    ]

-- | Forcing the example programs to a concrete effect stack references them
-- (so @-Wunused-top-binds@ stays quiet) and pins their otherwise-polymorphic
-- types, without running them.
compiles :: ()
compiles =
  (nestedSpans :: Eff '[Tracer, IOE] Int)
    `seq` (spanWithArguments :: Eff '[Tracer] ())
    `seq` ()

-- | Nested spans with attribute, event, and status annotations.
nestedSpans :: Tracer :> es => Eff es Int
nestedSpans = withSpan "outer" $ do
  addAttribute "user.id" ("u123" :: Text)
  result <- withSpan "inner" $ do
    addEvent "fetching" []
    pure (42 :: Int)
  setStatus Ok
  pure result

-- | Exercises 'withSpan'' with explicit arguments, the remaining emit
-- operations, and 'getActiveSpan'.
spanWithArguments :: Tracer :> es => Eff es ()
spanWithArguments =
  withSpan' "http.get" defaultSpanArguments {kind = Client} $ do
    addAttributes ["http.method" .= ("GET" :: Text), "http.status_code" .= (200 :: Int)]
    recordException (toException (userError "transient"))
    setStatus (Error "upstream timeout")
    active <- getActiveSpan
    case active :: Maybe SpanContext of
      Nothing -> pure ()
      Just _ -> pure ()

-- ---------------------------------------------------------------------------
-- Documentation examples
--
-- One binding per code block in the docs, named for its source. References to
-- application-specific types and effects (a database, a job queue, an order
-- record) are stubbed once here so the library calls keep their documented
-- shapes.
-- ---------------------------------------------------------------------------

-- | References every doc mirror at a concrete type so the block must typecheck.
-- Flag-gated interpreters and instrumentation are folded in conditionally.
docExamples :: ()
docExamples =
  (cbLoadUser :: UserId -> Eff '[Database, Tracer] User)
    `seq` (cbHandleOrder :: Order -> Eff '[Tracer] ())
    `seq` (cbPublishOrder :: Eff '[Tracer] [(Text, Text)])
    `seq` (cbConsumeOrder :: [(Text, Text)] -> Eff '[Tracer] () -> Eff '[Tracer] ())
    `seq` samplerName cbPriorityOr1Percent
    `seq` (cbRiskyCharge :: Eff '[Tracer] ())
    `seq` (cbPrioritySampledRun :: Eff '[Tracer, IOE] () -> IO [Span])
    `seq` (cbConsume :: [Header] -> Eff '[Tracer] () -> Eff '[Tracer] ())
    `seq` (cbB3Consume :: [Header] -> Eff '[Tracer] () -> Eff '[Tracer] ())
    `seq` (cbB3Forward :: Eff '[Tracer] [Header])
    `seq` (cbJaegerConsume :: [Header] -> Eff '[BaggageContext, Tracer] () -> Eff '[Tracer] ())
    `seq` (cbJaegerForward :: Eff '[Tracer] [Header])
    `seq` (cbCompositeConsume :: [Header] -> Eff '[Tracer] () -> Eff '[Tracer] ())
    `seq` (cbCompositeForward :: Eff '[Tracer] [Header])
    `seq` (cbCompositeServe :: [Header] -> Eff '[BaggageContext] () -> Eff '[] ())
    `seq` (cbCompositeBaggageForward :: Eff '[BaggageContext] [Header])
    `seq` (cbEnvConfigMain :: IO ())
    `seq` (cbServeWithBaggage :: [Header] -> Eff '[BaggageContext, Tracer] () -> Eff '[Tracer] ())
    `seq` (cbPriorityOf :: Eff '[BaggageContext] (Maybe Text))
    `seq` (cbHandleBaggage :: Eff '[BaggageContext, Tracer] [Header])
    `seq` (cbCheckHandlerTrace :: IO ())
    `seq` (cbLogEvent :: (Text -> [(Text, Text)] -> Eff '[Tracer] ()) -> Text -> Eff '[Tracer] ())
    `seq` (cbHandleRequest :: (Text -> [(Text, Text)] -> Eff '[Tracer] ()) -> Eff '[Tracer] ())
    `seq` (cbFetchActiveUsers :: Eff '[Tracer, IOE] [(Int, Text)])
    `seq` (cbWorker :: Eff '[Queue, Tracer] ())
    `seq` (cbEnqueueBackground :: Eff '[Tracer, Concurrent] ())
    `seq` (cbPrettyRun :: Eff '[Tracer, IOE] () -> IO ())
    `seq` (cbBoundedRun :: Eff '[Tracer, IOE] () -> IO [Span])
    `seq` (tutCheckout :: Eff '[Tracer] Int)
    `seq` (tutAnnotated :: Eff '[Tracer] ())
    `seq` (tutSampledRun :: Eff '[Tracer, IOE] () -> IO [Span])
    `seq` (tutFanOut :: Eff '[Tracer, Concurrent] (Int, Int))
    `seq` (readmeCompute :: Eff '[Tracer] Int)
    `seq` (readmeNoOpMain :: IO ())
    `seq` (readmePrettyMain :: IO ())
    `seq` stubConstructors
    `seq` waiExamples
    `seq` httpClientExamples
    `seq` postgresqlSimpleExamples
    `seq` sqliteSimpleExamples
    `seq` valiantExamples
    `seq` servantExamples
    `seq` otelExamples
    `seq` ()

-- Stub application types/effects the docs reference.

-- | The docs use only the field selectors of the stub types, never their
-- constructors, so reference the constructors here to keep @-Wunused-top-binds@
-- quiet. Never evaluated beyond WHNF.
stubConstructors :: (UserId, User, Job, Order)
stubConstructors = (UserId "", User, Job "", Order "" 0 "" False 0)

newtype UserId = UserId Text

data User = User

newtype Job = Job {jobId :: Text}

data Order = Order
  { orderId :: Text
  , totalCents :: Int
  , tierName :: Text
  , isExpress :: Bool
  , lineCount :: Int
  }

data Database :: Effect where
  QueryUser :: UserId -> Database m User

type instance DispatchOf Database = Dynamic

queryUser :: Database :> es => UserId -> Eff es User
queryUser = send . QueryUser

data Queue :: Effect where
  TakeJob :: Queue m Job

type instance DispatchOf Queue = Dynamic

takeJob :: Queue :> es => Eff es Job
takeJob = send TakeJob

-- cookbook: "Trace an existing function"
cbLoadUser :: (Database :> es, Tracer :> es) => UserId -> Eff es User
cbLoadUser uid = withSpan "loadUser" $ queryUser uid

-- cookbook: "Attach structured fields"
cbHandleOrder :: Tracer :> es => Order -> Eff es ()
cbHandleOrder order = withSpan "handleOrder" $ do
  addAttribute "order.id" (orderId order)
  addAttribute "order.total_cents" (totalCents order)
  addAttributes
    [ "customer.tier" .= tierName order
    , "order.express" .= isExpress order
    , "order.line_count" .= lineCount order
    ]
  addEvent "payment.authorized" ["gateway" .= ("stripe" :: Text)]

-- cookbook: "Trace a message producer and consumer" (producer)
cbPublishOrder :: (Tracer :> es) => Eff es [(Text, Text)]
cbPublishOrder =
  withMessagingSpan
    (messagingOperation "kafka" Send) {messagingDestination = Just "orders"}
    injectMessageHeaders

-- cookbook: "Trace a message producer and consumer" (consumer)
cbConsumeOrder :: (Tracer :> es) => [(Text, Text)] -> Eff es a -> Eff es a
cbConsumeOrder headers =
  withConsumerSpan headers (messagingOperation "kafka" Process) {messagingDestination = Just "orders"}

-- cookbook: "Sample but keep what matters" (custom sampler)
cbPriorityOr1Percent :: Sampler
cbPriorityOr1Percent =
  Sampler
    { samplerName = "PriorityOr1Percent"
    , shouldSample = \input ->
        if flagged (initialAttributes input)
          then pure (simpleResult RecordAndSample)
          else shouldSample (traceIdRatioBased 0.01) input
    }
  where
    flagged = any (\(Attribute k v) -> k == "sampling.priority" && v == AttrBool True)

-- cookbook: "Sample but keep what matters" (flag a span)
cbRiskyCharge :: Tracer :> es => Eff es ()
cbRiskyCharge =
  withSpan' "charge" defaultSpanArguments {attributes = ["sampling.priority" .= True]} $
    pure ()

-- cookbook: "Sample but keep what matters" (run with the custom sampler)
cbPrioritySampledRun :: Eff '[Tracer, IOE] a -> IO [Span]
cbPrioritySampledRun action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemoryWith cbPriorityOr1Percent captured action
  readCapturedSpans captured

-- cookbook: "Connect inbound and outbound HTTP traces" (continue a remote parent)
cbConsume :: Tracer :> es => [Header] -> Eff es a -> Eff es a
cbConsume headers =
  maybe id withRemoteParent (extractContext headers)

-- cookbook: "Interoperate with B3 (Zipkin) headers" (continue a B3 remote parent)
cbB3Consume :: Tracer :> es => [Header] -> Eff es a -> Eff es a
cbB3Consume headers =
  maybe id withRemoteParent (extractContextB3 headers)

-- cookbook: "Interoperate with B3 (Zipkin) headers" (forward as a single b3 header)
cbB3Forward :: Tracer :> es => Eff es [Header]
cbB3Forward = injectContextB3

-- cookbook: "Interoperate with Jaeger (uber-trace-id) headers" (continue + baggage)
cbJaegerConsume :: Tracer :> es => [Header] -> Eff (BaggageContext : es) a -> Eff es a
cbJaegerConsume headers =
  runBaggageWith (extractBaggageJaeger headers)
    . maybe id withRemoteParent (extractContextJaeger headers)

-- cookbook: "Interoperate with Jaeger (uber-trace-id) headers" (forward uber-trace-id)
cbJaegerForward :: Tracer :> es => Eff es [Header]
cbJaegerForward = injectContextJaeger

-- cookbook: "Combine several propagators" (the configured trace-context list)
cbPropagators :: [TraceContextPropagator]
cbPropagators = [w3cTraceContext, b3Single]

-- cookbook: "Combine several propagators" (continue the first matching format)
cbCompositeConsume :: Tracer :> es => [Header] -> Eff es a -> Eff es a
cbCompositeConsume headers =
  maybe id withRemoteParent (extractContextFirst cbPropagators headers)

-- cookbook: "Combine several propagators" (emit every configured format)
cbCompositeForward :: Tracer :> es => Eff es [Header]
cbCompositeForward = injectContextAll cbPropagators

-- cookbook: "Combine several propagators" (merge baggage from every format)
cbCompositeServe :: [Header] -> Eff (BaggageContext : es) a -> Eff es a
cbCompositeServe headers =
  runBaggageWith (extractBaggageAll cbBaggagePropagators headers)

-- cookbook: "Combine several propagators" (forward baggage in every format)
cbCompositeBaggageForward :: BaggageContext :> es => Eff es [Header]
cbCompositeBaggageForward = injectBaggageAll cbBaggagePropagators

-- cookbook: "Combine several propagators" (the configured baggage list)
cbBaggagePropagators :: [BaggagePropagator]
cbBaggagePropagators = [w3cBaggage, jaegerBaggage]

-- cookbook: "Configure tracing from OTEL_ environment variables"
cbEnvConfigMain :: IO ()
cbEnvConfigMain = do
  env <- readEnvConfig
  let _name = serviceName env
      _attrs = resourceAttributes env
      _propagators = traceContextPropagators env
      _sampler = tracesSampler env
  pure ()

-- cookbook: "Stamp logs with the active trace and span"
cbLogEvent :: Tracer :> es => (Text -> [(Text, Text)] -> Eff es ()) -> Text -> Eff es ()
cbLogEvent emit message = do
  fields <- activeCorrelationFields
  emit message fields

cbHandleRequest :: Tracer :> es => (Text -> [(Text, Text)] -> Eff es ()) -> Eff es ()
cbHandleRequest emit = withSpan "handle" $ cbLogEvent emit "handling request"

-- cookbook: "Trace a database query" (framework-agnostic withQuerySpan)
cbFetchActiveUsers :: (IOE :> es, Tracer :> es) => Eff es [(Int, Text)]
cbFetchActiveUsers =
  withQuerySpan
    (databaseQuery "postgresql")
      { queryText = Just "SELECT id, name FROM users WHERE active = $1"
      , queryOperation = Just "SELECT"
      , queryCollection = Just "users"
      }
    (liftIO rawSelectActiveUsers)

-- | Stands in for a driver's own query call in the database cookbook mirror;
-- only forced to WHNF, never run.
rawSelectActiveUsers :: IO [(Int, Text)]
rawSelectActiveUsers = error "compile-only: doc mirror is never run"

-- cookbook: "Carry application context as baggage" (seed inbound baggage)
cbServeWithBaggage :: [Header] -> Eff (BaggageContext : es) a -> Eff es a
cbServeWithBaggage headers = runBaggageWith (extractBaggage headers)

-- cookbook: "Carry application context as baggage" (read a value in scope)
cbPriorityOf :: BaggageContext :> es => Eff es (Maybe Text)
cbPriorityOf = lookupBaggageValue "request.priority" <$> getBaggage

-- cookbook: "Carry application context as baggage" (scope an entry, forward it)
cbHandleBaggage :: (BaggageContext :> es, Tracer :> es) => Eff es [Header]
cbHandleBaggage = withBaggageEntry "request.priority" "high" $ withSpan "handle" injectBaggage

-- cookbook: "Assert on traces in your tests"
cbCheckHandlerTrace :: IO ()
cbCheckHandlerTrace = do
  spans <- runEff $ do
    captured <- newCapturedSpans
    runTracerInMemory captured $
      withSpan "handler" $ do
        setStatus Ok
        withSpan "db.query" (addAttribute "db.rows" (1 :: Int))
    readCapturedSpans captured
  case (findSpan "handler" spans, findSpan "db.query" spans) of
    (Just handler, Just db) -> do
      isRoot handler @?= True
      (db `isChildOf` handler) @?= True
      hasStatus Ok handler @?= True
      lookupAttribute "db.rows" db @?= Just (AttrInt 1)
    _ -> pure ()

-- cookbook: "Instrument a long-running worker"
cbWorker :: (Tracer :> es, Queue :> es) => Eff es ()
cbWorker = do
  job <- takeJob
  withSpan "worker.handleJob" $ do
    addAttribute "job.id" (jobId job)
    pure ()

-- cookbook: "Instrument a long-running worker" (linked background work)
cbEnqueueBackground :: (Tracer :> es, Concurrent :> es) => Eff es ()
cbEnqueueBackground = withSpan "request" $ do
  _ <- forkLinked (withSpan "background.reindex" (pure ()))
  pure ()

-- cookbook: pretty-print configuration
cbPrettyRun :: Eff '[Tracer, IOE] a -> IO a
cbPrettyRun action = do
  color <- hIsTerminalDevice stderr
  let config =
        (defaultPrettyPrintConfig stderr)
          { useColor = color
          , showEvents = False
          , timeFormat = RelativeToTraceStart
          }
  runEff (runTracerPretty config action)

-- cookbook: "Bound what a span records"
cbBoundedRun :: Eff '[Tracer, IOE] a -> IO [Span]
cbBoundedRun action = runEff $ do
  captured <- newCapturedSpans
  let limits = defaultSpanLimits {attributeValueLengthLimit = Just 1024, eventCountLimit = Just 64}
  _ <- runTracerInMemoryWithLimits limits alwaysOn captured action
  readCapturedSpans captured

-- tutorial: first traced computation
tutCheckout :: Tracer :> es => Eff es Int
tutCheckout = withSpan "checkout" $ do
  addAttribute "cart.items" (3 :: Int)
  total <- withSpan "price.total" (pure 4200)
  setStatus Ok
  pure total

-- tutorial: annotating a span
tutAnnotated :: Tracer :> es => Eff es ()
tutAnnotated = withSpan "handle.order" $ do
  addAttribute "order.id" ("o-9921" :: Text)
  addAttributes ["http.method" .= ("POST" :: Text), "http.status_code" .= (200 :: Int)]
  addEvent "inventory.reserved" ["sku" .= ("widget-1" :: Text)]
  recordException (toException (ErrorCall "downstream slow"))
  setStatus (Error "downstream slow")

-- tutorial: deterministic ratio sampling
tutSampledRun :: Eff '[Tracer, IOE] a -> IO [Span]
tutSampledRun action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemoryWith (traceIdRatioBased 0.1) captured action
  readCapturedSpans captured

-- tutorial: concurrent fan-out under one parent
tutFanOut :: (Tracer :> es, Concurrent :> es) => Eff es (Int, Int)
tutFanOut = withSpan "fan.out" $
  concurrentlyInstrumented
    (withSpan "left" (pure 1))
    (withSpan "right" (pure 2))

-- README: tracing without committing to a backend
readmeCompute :: Tracer :> es => Eff es Int
readmeCompute = withSpan "outer" $ do
  addAttribute "user.id" ("u123" :: Text)
  total <- withSpan "inner" $ do
    addEvent "fetching" []
    pure 42
  setStatus Ok
  pure total

-- README: no-op interpreter
readmeNoOpMain :: IO ()
readmeNoOpMain = do
  result <- runEff (runTracerNoOp readmeCompute)
  print result

-- README: pretty-print interpreter
readmePrettyMain :: IO ()
readmePrettyMain = do
  result <- runEff (runTracerPretty (defaultPrettyPrintConfig stderr) readmeCompute)
  print result

-- WAI middleware examples (only when built with +wai).
waiExamples :: ()
#ifdef WAI
waiExamples =
  (cbRouteName :: Request -> Text)
    `seq` (waiWrap stubRunInIO stubApp :: Application)
    `seq` (waiWrapNamed stubRunInIO stubApp :: Application)
    `seq` ()
  where
    -- Stubs let the rank-2 mirrors be referenced as a plain 'Application'; both
    -- are only forced to WHNF (a partial application), so neither is evaluated.
    stubRunInIO :: Eff '[IOE, Tracer] a -> IO a
    stubRunInIO = error "compile-only: doc mirror is never run"
    stubApp :: Application
    stubApp = error "compile-only: doc mirror is never run"

-- cookbook: name a server span after the matched route
cbRouteName :: Request -> Text
cbRouteName req =
  decodeUtf8Lenient (requestMethod req) <> " " <> decodeUtf8Lenient (rawPathInfo req)

-- README / tutorial: wrap a WAI app with the tracing middleware
waiWrap :: (IOE :> es, Tracer :> es) => (forall a. Eff es a -> IO a) -> Application -> Application
waiWrap runInIO app = traceMiddleware runInIO app

-- cookbook: middleware with a custom span name
waiWrapNamed :: (IOE :> es, Tracer :> es) => (forall a. Eff es a -> IO a) -> Application -> Application
waiWrapNamed runInIO app = traceMiddlewareWith cbRouteName runInIO app
#else
waiExamples = ()
#endif

-- http-client examples (only when built with +http-client).
httpClientExamples :: ()
#ifdef HTTP_CLIENT
httpClientExamples =
  (cbFetchProfile :: Manager -> Eff '[Tracer, IOE] (Response ByteString))
    `seq` ()

-- README / cookbook / tutorial: traced outbound request
cbFetchProfile :: (IOE :> es, Tracer :> es) => Manager -> Eff es (Response ByteString)
cbFetchProfile manager = withSpan "load.profile" $ do
  req <- liftIO (parseRequest "http://users.internal/profile")
  httpLbsTraced req manager
#else
httpClientExamples = ()
#endif

-- postgresql-simple examples (only when built with +postgresql-simple).
postgresqlSimpleExamples :: ()
#ifdef POSTGRESQL_SIMPLE
postgresqlSimpleExamples =
  (cbActiveUserNames :: Connection -> Eff '[Tracer, IOE] [Only Text])
    `seq` ()

-- cookbook: traced postgresql-simple query
cbActiveUserNames :: (IOE :> es, Tracer :> es) => Connection -> Eff es [Only Text]
cbActiveUserNames conn =
  Pg.query conn "SELECT name FROM users WHERE active = ?" (Only True)
#else
postgresqlSimpleExamples = ()
#endif

-- sqlite-simple examples (only when built with +sqlite-simple).
sqliteSimpleExamples :: ()
#ifdef SQLITE_SIMPLE
sqliteSimpleExamples =
  (cbSqliteActiveUserNames :: SqliteDb.Connection -> Eff '[Tracer, IOE] [SqliteDb.Only Text])
    `seq` (cbSqliteSeedUsers :: SqliteDb.Connection -> Eff '[Tracer, IOE] ())
    `seq` ()

-- cookbook: traced sqlite-simple query
cbSqliteActiveUserNames :: (IOE :> es, Tracer :> es) => SqliteDb.Connection -> Eff es [SqliteDb.Only Text]
cbSqliteActiveUserNames conn =
  Sqlite.query conn "SELECT name FROM users WHERE active = ?" (SqliteDb.Only True)

-- cookbook: traced sqlite-simple batch insert
cbSqliteSeedUsers :: (IOE :> es, Tracer :> es) => SqliteDb.Connection -> Eff es ()
cbSqliteSeedUsers conn =
  Sqlite.executeMany conn "INSERT INTO users (name) VALUES (?)" [SqliteDb.Only ("a" :: Text), SqliteDb.Only "b"]
#else
sqliteSimpleExamples = ()
#endif

-- valiant examples (only when built with +valiant).
valiantExamples :: ()
#ifdef VALIANT
valiantExamples =
  (cbValiantActiveUsers :: Eff '[Valiant, Tracer] [Text])
    `seq` (cbValiantSeedUsers :: Eff '[Valiant, Tracer] Int64)
    `seq` ()

-- cookbook: traced valiant query
cbValiantActiveUsers :: (Valiant :> es, Tracer :> es) => Eff es [Text]
cbValiantActiveUsers = ValiantT.fetchAllEff listActiveUsers ()

-- cookbook: traced valiant batch insert
cbValiantSeedUsers :: (Valiant :> es, Tracer :> es) => Eff es Int64
cbValiantSeedUsers = ValiantT.executeBatchEff insertUser ["a", "b"]

-- | Stand-in statements for the valiant mirror. The plugin would normally
-- build these from validated SQL; 'mkStatement' constructs them directly so
-- the mirror needs no plugin or database. Never run.
listActiveUsers :: Statement () Text
listActiveUsers = mkStatement "SELECT name FROM users WHERE active = true" [] ["name"] "inline"

insertUser :: Statement Text ()
insertUser = mkStatement "INSERT INTO users (name) VALUES ($1)" [25] [] "inline"
#else
valiantExamples = ()
#endif

-- servant examples (only when built with +servant).
servantExamples :: ()
#ifdef SERVANT
servantExamples =
  (servantServer :: Server ServantApi)
    `seq` (servantWrap stubRunInIOS (serve (Proxy :: Proxy ServantApi) servantServer) :: Application)
    `seq` ()
  where
    stubRunInIOS :: Eff '[IOE, Tracer] a -> IO a
    stubRunInIOS = error "compile-only: doc mirror is never run"

-- cookbook: name server spans from the matched route with Servant
type ServantApi =
  WithSpanName "/users/{id}" Sv.:> "users" Sv.:> Capture "id" Int Sv.:> Get '[PlainText] Text
    :<|> WithSpanName "/health" Sv.:> "health" Sv.:> Get '[PlainText] Text

servantServer :: Server ServantApi
servantServer = (\_ -> pure "user") :<|> pure "ok"

servantWrap
  :: (IOE :> es, Tracer :> es)
  => (forall a. Eff es a -> IO a)
  -> Application
  -> Application
servantWrap runInIO app = traceServantMiddleware runInIO app
#else
servantExamples = ()
#endif

-- OpenTelemetry export example (only when built with +otel). The exporter and
-- batch processor in the doc come from the SDK packages, which are not test
-- dependencies; the library surface (the 'OtelConfig' record and
-- 'runTracerOTel') is what this mirror pins, with an empty processor list.
otelExamples :: ()
#ifdef OTEL
otelExamples =
  (tutOtelRun :: Eff '[Tracer, IOE] Int -> IO Int)
    `seq` ()

tutOtelRun :: Eff '[Tracer, IOE] a -> IO a
tutOtelRun action = do
  let config =
        OtelConfig
          { spanProcessors = []
          , instrumentationScope = "checkout-service"
          , sampler = parentBased (defaultParentBasedConfig alwaysOn)
          , spanLimits = defaultSpanLimits
          }
  runEff (runTracerOTel config action)
#else
otelExamples = parentBased (defaultParentBasedConfig alwaysOn) `seq` ()
#endif
