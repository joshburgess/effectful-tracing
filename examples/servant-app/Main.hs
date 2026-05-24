{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | A tiny two-endpoint Servant service that demonstrates both instrumentation
-- helpers producing one connected distributed trace, exported to a local Jaeger
-- over OTLP.
--
-- @GET \/checkout@ opens a @server@ span (via 'traceMiddleware'), then makes an
-- outbound call to @GET \/inventory@ through 'httpLbsTraced' (a @client@ span).
-- The outbound call carries a @traceparent@, so the middleware continues the
-- same trace when it handles @\/inventory@. The result in Jaeger is a single
-- trace: @checkout.handler@ -> the @client@ span -> @inventory.handler@.
module Main (main) where

import Control.Monad.IO.Class (liftIO)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)

import Effectful
  ( Eff
  , IOE
  , Limit (Unlimited)
  , Persistence (Persistent)
  , UnliftStrategy (ConcUnlift)
  , runEff
  , withEffToIO
  , (:>)
  )
import Effectful.Tracing
  ( Tracer
  , addAttribute
  , addEvent
  , alwaysOn
  , withSpan
  )
import Effectful.Tracing.Instrumentation.HttpClient (httpLbsTraced)
import Effectful.Tracing.Instrumentation.Wai (traceMiddleware)
import Effectful.Tracing.Interpreter.OpenTelemetry (OtelConfig (..), runTracerOTel)

import Network.HTTP.Client (Manager, defaultManagerSettings, newManager, parseRequest)
import Network.Wai.Handler.Warp qualified as Warp
import OpenTelemetry.Exporter.OTLP.Span (loadExporterEnvironmentVariables, otlpExporter)
import OpenTelemetry.Processor.Batch.Span (batchProcessor, batchTimeoutConfig)
import Servant
  ( Get
  , JSON
  , ServerT
  , hoistServer
  , serve
  , type (:<|>) ((:<|>))
  )
import Servant qualified

-- @Servant.:>@ is qualified so it does not clash with effectful's @(:>)@, which
-- this module uses unqualified in effect-row constraints.
type Api =
  "checkout" Servant.:> Get '[JSON] Text
    :<|> "inventory" Servant.:> Get '[JSON] [Text]

api :: Proxy Api
api = Proxy

-- | Handlers written directly in @Eff@: the active server span opened by the
-- middleware is in scope, so the outbound call nests under it.
server :: (Tracer :> es, IOE :> es) => Manager -> ServerT Api (Eff es)
server manager = checkout :<|> inventory
  where
    checkout = withSpan "checkout.handler" $ do
      addAttribute "checkout.cart" ("cart-42" :: Text)
      req <- liftIO (parseRequest "http://localhost:8080/inventory")
      _ <- httpLbsTraced req manager
      pure "checkout complete"
    inventory = withSpan "inventory.handler" $ do
      addEvent "inventory.read" []
      pure ["widget", "gadget"]

main :: IO ()
main = do
  exporter <- loadExporterEnvironmentVariables >>= otlpExporter
  processor <- batchProcessor batchTimeoutConfig exporter
  manager <- newManager defaultManagerSettings
  let config =
        OtelConfig
          { spanProcessors = [processor]
          , instrumentationScope = "servant-app"
          , sampler = alwaysOn
          }
  runEff . runTracerOTel config $
    withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
      let waiApp =
            traceMiddleware
              runInIO
              (serve api (hoistServer api (liftIO . runInIO) (server manager)))
      putStrLn "Serving on http://localhost:8080 (try: curl localhost:8080/checkout)"
      Warp.run 8080 waiApp
