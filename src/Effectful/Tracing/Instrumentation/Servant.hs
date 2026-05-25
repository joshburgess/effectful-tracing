{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Servant
-- Description : Route-aware tracing for Servant servers.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- The WAI middleware in "Effectful.Tracing.Instrumentation.Wai" opens a
-- @server@-kind span /before/ the application runs, so it cannot name the span
-- after the matched route, which Servant only knows once routing has run. The
-- OpenTelemetry HTTP conventions ask for a low-cardinality server span named
-- @\"{method} {route}\"@ with the route template also recorded as
-- @http.route@. This module closes that gap.
--
-- Annotate each endpoint with the 'WithSpanName' combinator, giving the route
-- template (without the method) as a type-level string:
--
-- > type API =
-- >        WithSpanName "/users/{id}" :> "users" :> Capture "id" Int :> Get '[JSON] User
-- >   :<|> WithSpanName "/users"      :> "users" :> ReqBody '[JSON] NewUser :> Post '[JSON] User
--
-- The combinator is transparent to handlers (it does not change @ServerT@), so
-- the server value is written exactly as it would be without it. When the router
-- selects an endpoint, the combinator records its template; 'traceServantMiddleware'
-- then renames the open server span to @\"{method} {route}\"@ and sets
-- @http.route@ once the application returns.
--
-- Use 'traceServantMiddleware' in place of
-- 'Effectful.Tracing.Instrumentation.Wai.traceMiddleware'; it does everything that
-- middleware does (continues an inbound trace, records the request and response
-- following the stable HTTP semantic conventions, marks 5xx as an error) and adds
-- the route naming. Like the WAI middleware it takes an unlift @forall a. 'Eff' es a -> 'IO' a@
-- that must tolerate concurrent calls:
--
-- > import Effectful
-- > import Servant (serve)
-- >
-- > server :: (IOE :> es, Tracer :> es) => Eff es ()
-- > server = withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
-- >   Warp.run 8080 (traceServantMiddleware runInIO (serve (Proxy @API) handlers))
--
-- An endpoint with no 'WithSpanName' is still traced; its span keeps the default
-- name (the request method) and carries no @http.route@.
module Effectful.Tracing.Instrumentation.Servant
  ( -- * Route-naming combinator
    WithSpanName

    -- * Middleware
  , traceServantMiddleware
  ) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Vault.Lazy qualified as Vault
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import System.IO.Unsafe (unsafePerformIO)

import Network.HTTP.Types (Status (statusCode, statusMessage))
import Network.Wai (Middleware, requestHeaders, requestMethod, responseStatus, vault)

import Servant.API (type (:>))
import Servant.Server (HasServer (hoistServerWithContext, route), ServerT)
import Servant.Server.Internal.Delayed (addMethodCheck)
import Servant.Server.Internal.DelayedIO (withRequest)

import Effectful (Eff, IOE)
import Effectful qualified as E

import Effectful.Tracing
  ( SpanArguments (attributes, kind)
  , SpanKind (Server)
  , SpanStatus (Error)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , extractContext
  , setStatus
  , updateName
  , withRemoteParent
  , withSpan'
  )
import Effectful.Tracing.Instrumentation.Wai (requestAttributes)
import Effectful.Tracing.SemConv qualified as SemConv

-- | A phantom combinator that names the server span for the endpoint it
-- precedes. @name@ is the route template (without the HTTP method, which
-- 'traceServantMiddleware' prepends), and should be low-cardinality: use the
-- parameterized form @\"/users/{id}\"@, never the concrete path @\"/users/9921\"@.
-- It is transparent to the handler: @'ServerT' ('WithSpanName' name ':>' api) m@ is
-- just @'ServerT' api m@.
data WithSpanName (name :: Symbol)

-- | A request-scoped slot carrying the matched route template from the
-- 'WithSpanName' instance to 'traceServantMiddleware'. A 'Vault.Key' is the only
-- channel between them: the @'HasServer'@ instance cannot be handed an
-- 'IORef' directly, and the middleware seeds a fresh ref per request. Allocating
-- the key once at the top level is the established Servant\/WAI idiom for this.
routeKey :: Vault.Key (IORef (Maybe Text))
routeKey = unsafePerformIO Vault.newKey
{-# NOINLINE routeKey #-}

-- | The matched route is recorded during the method-check phase: by then the
-- path captures and HTTP method have matched, so the router has committed to this
-- endpoint, and a later failure (a 401, 406, or 400) still leaves the span named
-- after the route it was handling.
instance (HasServer api ctx, KnownSymbol name) => HasServer (WithSpanName name :> api) ctx where
  type ServerT (WithSpanName name :> api) m = ServerT api m

  route _ ctx delayed = route (Proxy :: Proxy api) ctx (addMethodCheck delayed recordRoute)
    where
      recordRoute = withRequest $ \req ->
        liftIO $ case Vault.lookup routeKey (vault req) of
          Just ref -> writeIORef ref (Just routeName)
          Nothing -> pure ()
      routeName = T.pack (symbolVal (Proxy :: Proxy name))

  hoistServerWithContext _ = hoistServerWithContext (Proxy :: Proxy api)

-- | Trace a Servant 'Network.Wai.Application', naming each server span after the
-- matched route. It opens a @server@-kind span (continuing an inbound trace when
-- the headers carry one), records the stable HTTP request and response
-- attributes, marks 5xx responses as an error, and, once the application has
-- routed to an endpoint annotated with 'WithSpanName', renames the span to
-- @\"{method} {route}\"@ and sets @http.route@.
--
-- The span starts named after the request method, so an unannotated endpoint (or
-- a request that never matches one) still produces a well-formed span; the route
-- naming only refines it.
traceServantMiddleware
  :: (IOE E.:> es, Tracer E.:> es)
  => (forall a. Eff es a -> IO a)
  -- ^ Run an @'Eff' es@ action in 'IO'. Must tolerate concurrent calls; see the
  -- module header.
  -> Middleware
traceServantMiddleware runInIO app req respond =
  runInIO (continueRemote (withSpan' method serverArgs body))
  where
    method = decodeUtf8Lenient (requestMethod req)

    continueRemote =
      maybe id withRemoteParent (extractContext (requestHeaders req))

    serverArgs =
      defaultSpanArguments
        { kind = Server
        , attributes = requestAttributes req
        }

    body = do
      routeRef <- liftIO (newIORef Nothing)
      statusRef <- liftIO (newIORef Nothing)
      let req' = req {vault = Vault.insert routeKey routeRef (vault req)}
          respond' response = do
            -- Project and force the status before storing it, so the ref does
            -- not retain the whole response (body included) until the span
            -- closes.
            let !status = responseStatus response
            writeIORef statusRef (Just status)
            respond response
      received <- liftIO (app req' respond')
      mRoute <- liftIO (readIORef routeRef)
      case mRoute of
        Nothing -> pure ()
        Just route' -> do
          updateName (method <> " " <> route')
          addAttribute SemConv.httpRoute route'
      mStatus <- liftIO (readIORef statusRef)
      case mStatus of
        Nothing -> pure ()
        Just status -> do
          addAttribute SemConv.httpResponseStatusCode (statusCode status)
          when (statusCode status >= 500) $
            setStatus (Error (decodeUtf8Lenient (statusMessage status)))
      pure received
