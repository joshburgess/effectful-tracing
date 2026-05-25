{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Effectful.Tracing.Propagation.Composite
-- Description : Combine several propagators into one inject\/extract pass.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A real deployment rarely speaks exactly one wire format. A service may emit
-- W3C @traceparent@ for its own backend while still honouring inbound B3 headers
-- from a mesh, or run alongside legacy Jaeger clients during a migration.
-- OpenTelemetry models this with a __composite propagator__: a list of
-- single-format propagators that all run on inject (every format is written) and
-- are tried in order on extract (the first that parses wins).
--
-- This module packages each single-format propagator from
-- "Effectful.Tracing.Propagation", "Effectful.Tracing.Propagation.B3", and
-- "Effectful.Tracing.Propagation.Jaeger" as a first-class value
-- ('TraceContextPropagator' for the span context, 'BaggagePropagator' for
-- baggage), and provides the combinators that fan a list of them out on the way
-- out ('injectContextAll', 'injectBaggageAll') and collapse them on the way in
-- ('extractContextFirst', 'extractBaggageAll').
--
-- > -- write W3C and B3, accept either inbound
-- > let propagators = [w3cTraceContext, b3Single]
-- >
-- > -- server side: continue whichever format the caller used
-- > handle req = case extractContextFirst propagators (requestHeaders req) of
-- >   Just parent -> withRemoteParent parent (withSpan "handle" (serve req))
-- >   Nothing     -> withSpan "handle" (serve req)
-- >
-- > -- client side: emit every configured format
-- > call = withSpan "call.downstream" $ do
-- >   headers <- injectContextAll propagators
-- >   liftIO (httpGet url (baseHeaders <> headers))
--
-- Each standard propagator is tagged with the token name OpenTelemetry's
-- @OTEL_PROPAGATORS@ environment variable uses for it (@tracecontext@, @baggage@,
-- @b3@, @b3multi@, @jaeger@), and 'traceContextByToken' \/ 'baggageByToken' resolve
-- a token to its propagator. This is the foundation environment-variable
-- configuration builds on.
--
-- Like the underlying propagators, this works directly against the library's own
-- context under any interpreter, with no dependency on an OpenTelemetry SDK.
module Effectful.Tracing.Propagation.Composite
  ( -- * Trace-context propagators
    TraceContextPropagator (..)
  , w3cTraceContext
  , b3Single
  , b3Multi
  , jaegerTraceContext
  , traceContextByToken

    -- * Baggage propagators
  , BaggagePropagator (..)
  , w3cBaggage
  , jaegerBaggage
  , baggageByToken

    -- * Combining propagators
  , injectContextAll
  , extractContextFirst
  , injectBaggageAll
  , extractBaggageAll
  ) where

import Data.ByteString (ByteString)
import Data.Foldable (asum)
import Data.Text (Text)
import Network.HTTP.Types.Header (HeaderName)

import Effectful (Eff, (:>))

import Effectful.Tracing.Baggage
  ( Baggage
  , BaggageContext
  , baggageFromList
  , baggageToList
  )
import Effectful.Tracing.Effect (Tracer)
import Effectful.Tracing.Internal.Types (SpanContext)
import Effectful.Tracing.Propagation (extractContext, injectContext)
import Effectful.Tracing.Propagation.B3
  ( extractContextB3
  , injectContextB3
  , injectContextB3Multi
  )
import Effectful.Tracing.Propagation.Baggage (extractBaggage, injectBaggage)
import Effectful.Tracing.Propagation.Jaeger
  ( extractBaggageJaeger
  , extractContextJaeger
  , injectBaggageJaeger
  , injectContextJaeger
  )

-- | A single span-context propagator captured as a value: its
-- @OTEL_PROPAGATORS@ token name, its outbound 'inject', and its inbound
-- 'extract'. The standard ones are 'w3cTraceContext', 'b3Single', 'b3Multi', and
-- 'jaegerTraceContext'; construct your own to plug in a custom header scheme.
data TraceContextPropagator = TraceContextPropagator
  { traceContextName :: !Text
  -- ^ The @OTEL_PROPAGATORS@ token this propagator is configured by.
  , inject :: forall es. Tracer :> es => Eff es [(HeaderName, ByteString)]
  -- ^ Serialize the active span's context as outbound headers (@[]@ when there
  -- is no active span).
  , extract :: [(HeaderName, ByteString)] -> Maybe SpanContext
  -- ^ Parse a remote context from inbound headers, or 'Nothing' if this format
  -- is absent or malformed.
  }

-- | A single baggage propagator captured as a value: its @OTEL_PROPAGATORS@
-- token name, its outbound 'injectBag', and its inbound 'extractBag'. The standard
-- ones are 'w3cBaggage' and 'jaegerBaggage'.
data BaggagePropagator = BaggagePropagator
  { baggageName :: !Text
  -- ^ The @OTEL_PROPAGATORS@ token this propagator is configured by.
  , injectBag :: forall es. BaggageContext :> es => Eff es [(HeaderName, ByteString)]
  -- ^ Serialize the in-scope baggage as outbound headers (@[]@ when empty).
  , extractBag :: [(HeaderName, ByteString)] -> Baggage
  -- ^ Parse baggage from inbound headers (empty when absent).
  }

-- | The W3C Trace Context propagator (@traceparent@ \/ @tracestate@), token
-- @tracecontext@. Wraps "Effectful.Tracing.Propagation".
w3cTraceContext :: TraceContextPropagator
w3cTraceContext =
  TraceContextPropagator
    { traceContextName = "tracecontext"
    , inject = injectContext
    , extract = extractContext
    }

-- | The single-header B3 propagator (@b3@), token @b3@. Wraps
-- "Effectful.Tracing.Propagation.B3". On extract this reads either B3 form, so it
-- also accepts the multi-header encoding.
b3Single :: TraceContextPropagator
b3Single =
  TraceContextPropagator
    { traceContextName = "b3"
    , inject = injectContextB3
    , extract = extractContextB3
    }

-- | The multi-header B3 propagator (@X-B3-*@), token @b3multi@. Wraps
-- "Effectful.Tracing.Propagation.B3"; differs from 'b3Single' only in writing the
-- legacy multi-header form on inject.
b3Multi :: TraceContextPropagator
b3Multi =
  TraceContextPropagator
    { traceContextName = "b3multi"
    , inject = injectContextB3Multi
    , extract = extractContextB3
    }

-- | The Jaeger propagator (@uber-trace-id@), token @jaeger@. Wraps
-- "Effectful.Tracing.Propagation.Jaeger". Jaeger also carries baggage; that side
-- is 'jaegerBaggage'.
jaegerTraceContext :: TraceContextPropagator
jaegerTraceContext =
  TraceContextPropagator
    { traceContextName = "jaeger"
    , inject = injectContextJaeger
    , extract = extractContextJaeger
    }

-- | The W3C Baggage propagator (@baggage@ header), token @baggage@. Wraps
-- "Effectful.Tracing.Propagation.Baggage".
w3cBaggage :: BaggagePropagator
w3cBaggage =
  BaggagePropagator
    { baggageName = "baggage"
    , injectBag = injectBaggage
    , extractBag = extractBaggage
    }

-- | The Jaeger baggage propagator (@uberctx-@ headers), token @jaeger@. Wraps
-- the baggage side of "Effectful.Tracing.Propagation.Jaeger".
jaegerBaggage :: BaggagePropagator
jaegerBaggage =
  BaggagePropagator
    { baggageName = "jaeger"
    , injectBag = injectBaggageJaeger
    , extractBag = extractBaggageJaeger
    }

-- | Resolve an @OTEL_PROPAGATORS@ token to its trace-context propagator, or
-- 'Nothing' for an unknown token (or one, like @baggage@, that has no
-- trace-context side). Recognises @tracecontext@, @b3@, @b3multi@, and @jaeger@.
traceContextByToken :: Text -> Maybe TraceContextPropagator
traceContextByToken token =
  lookup token [(traceContextName p, p) | p <- standardTraceContextPropagators]

-- | Resolve an @OTEL_PROPAGATORS@ token to its baggage propagator, or 'Nothing'
-- for a token with no baggage side. Recognises @baggage@ and @jaeger@.
baggageByToken :: Text -> Maybe BaggagePropagator
baggageByToken token =
  lookup token [(baggageName p, p) | p <- standardBaggagePropagators]

-- | The standard trace-context propagators, in token order.
standardTraceContextPropagators :: [TraceContextPropagator]
standardTraceContextPropagators = [w3cTraceContext, b3Single, b3Multi, jaegerTraceContext]

-- | The standard baggage propagators, in token order.
standardBaggagePropagators :: [BaggagePropagator]
standardBaggagePropagators = [w3cBaggage, jaegerBaggage]

-- | Run every propagator's inject and concatenate the headers, so an outbound
-- request carries all configured formats at once. Returns @[]@ for an empty
-- list (or when there is no active span).
injectContextAll :: Tracer :> es => [TraceContextPropagator] -> Eff es [(HeaderName, ByteString)]
injectContextAll propagators = concat <$> traverse (\p -> inject p) propagators

-- | Try each propagator's extract in order and take the first that parses a
-- context, mirroring OpenTelemetry's composite extract. Returns 'Nothing' when
-- none of them match.
extractContextFirst :: [TraceContextPropagator] -> [(HeaderName, ByteString)] -> Maybe SpanContext
extractContextFirst propagators headers = asum [extract p headers | p <- propagators]

-- | Run every baggage propagator's inject and concatenate the headers. Returns
-- @[]@ for an empty list (or empty baggage).
injectBaggageAll :: BaggageContext :> es => [BaggagePropagator] -> Eff es [(HeaderName, ByteString)]
injectBaggageAll propagators = concat <$> traverse (\p -> injectBag p) propagators

-- | Extract baggage with every propagator and merge the results into one set.
-- Baggage is additive (unlike a single span context), so all formats
-- contribute; on a key present in more than one, the later propagator in the
-- list wins.
extractBaggageAll :: [BaggagePropagator] -> [(HeaderName, ByteString)] -> Baggage
extractBaggageAll propagators headers =
  baggageFromList (concatMap (\p -> baggageToList (extractBag p headers)) propagators)
