{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.EnvConfig
-- Description : Read OpenTelemetry configuration from environment variables.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- OpenTelemetry defines a set of @OTEL_@-prefixed
-- <https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/ environment variables>
-- so an operator can configure a service's tracing without touching code. This
-- module reads the subset that maps onto the library's own surface and packages
-- it as an 'EnvConfig' you wire into your interpreter at startup:
--
-- * @OTEL_SERVICE_NAME@: the service name (falling back to a @service.name@
--   entry in @OTEL_RESOURCE_ATTRIBUTES@).
-- * @OTEL_RESOURCE_ATTRIBUTES@: extra resource attributes, in the W3C Baggage
--   octet format (comma-separated @key=value@, percent-decoded).
-- * @OTEL_PROPAGATORS@: the propagators to install, as a comma-separated list of
--   tokens (@tracecontext@, @baggage@, @b3@, @b3multi@, @jaeger@, or @none@),
--   resolved through "Effectful.Tracing.Propagation.Composite".
-- * @OTEL_TRACES_SAMPLER@ / @OTEL_TRACES_SAMPLER_ARG@: the sampler
--   (@always_on@, @always_off@, @traceidratio@, and the @parentbased_@ variants),
--   built from "Effectful.Tracing.Sampler".
--
-- > import Effectful.Tracing.EnvConfig (EnvConfig (..), readEnvConfig)
-- >
-- > main :: IO ()
-- > main = do
-- >   env <- readEnvConfig
-- >   let propagators = traceContextPropagators env
-- >   -- ... build your OtelConfig with (tracesSampler env), seed resource
-- >   -- attributes with (resourceAttributes env), and so on.
--
-- The parse is pure ('parseEnvConfig' takes a lookup function), so it is fully
-- testable without touching the process environment; 'readEnvConfig' is the thin
-- 'IO' wrapper that reads the real environment. Unset variables fall back to the
-- OpenTelemetry defaults (propagators @tracecontext,baggage@; sampler
-- @parentbased_always_on@), and an unrecognised sampler or propagator token
-- degrades to that default rather than failing.
module Effectful.Tracing.EnvConfig
  ( -- * Configuration
    EnvConfig (..)
  , defaultEnvConfig

    -- * Reading the environment
  , readEnvConfig
  , parseEnvConfig

    -- * Individual readers (pure)
  , parseServiceName
  , parseResourceAttributes
  , parsePropagators
  , parseSampler
  ) where

import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (getEnvironment)
import Text.Read (readMaybe)

import Effectful.Tracing.Attribute (Attribute, (.=))
import Effectful.Tracing.Baggage (BaggageEntry (baggageValue), baggageToList)
import Effectful.Tracing.Propagation.Baggage (parseBaggage)
import Effectful.Tracing.Propagation.Composite
  ( BaggagePropagator
  , TraceContextPropagator
  , baggageByToken
  , traceContextByToken
  , w3cBaggage
  , w3cTraceContext
  )
import Effectful.Tracing.Sampler
  ( Sampler
  , alwaysOff
  , alwaysOn
  , defaultParentBasedConfig
  , parentBased
  , traceIdRatioBased
  )

-- | The tracing configuration read from the @OTEL_@ environment variables.
-- Every field has a resolved value: lists are empty when nothing is configured,
-- and 'tracesSampler' is always a concrete sampler (the OpenTelemetry default
-- when unset). 'serviceName' is the one optional field, 'Nothing' when neither
-- @OTEL_SERVICE_NAME@ nor a @service.name@ resource attribute is present.
data EnvConfig = EnvConfig
  { serviceName :: !(Maybe Text)
  -- ^ @OTEL_SERVICE_NAME@, or the @service.name@ entry from
  -- @OTEL_RESOURCE_ATTRIBUTES@, whichever is present (the former wins).
  , resourceAttributes :: ![Attribute]
  -- ^ The @OTEL_RESOURCE_ATTRIBUTES@ entries as typed attributes. Does not
  -- include 'serviceName'; copy that on separately if you want it as a resource
  -- attribute too.
  , traceContextPropagators :: ![TraceContextPropagator]
  -- ^ The span-context propagators named in @OTEL_PROPAGATORS@, in order.
  , baggagePropagators :: ![BaggagePropagator]
  -- ^ The baggage propagators named in @OTEL_PROPAGATORS@, in order.
  , tracesSampler :: !Sampler
  -- ^ The sampler from @OTEL_TRACES_SAMPLER@ / @OTEL_TRACES_SAMPLER_ARG@,
  -- defaulting to @parentbased_always_on@.
  }

-- | The configuration an empty environment yields: no service name, no resource
-- attributes, the default @tracecontext,baggage@ propagators, and the
-- @parentbased_always_on@ sampler.
defaultEnvConfig :: EnvConfig
defaultEnvConfig = parseEnvConfig (const Nothing)

-- | Read the configuration from the real process environment. A thin wrapper
-- over 'parseEnvConfig': it snapshots the environment once and looks each
-- variable up in it.
readEnvConfig :: IO EnvConfig
readEnvConfig = do
  entries <- getEnvironment
  let look name = T.pack <$> lookup (T.unpack name) entries
  pure (parseEnvConfig look)

-- | Build an 'EnvConfig' from a variable-lookup function. The function returns
-- the raw value for a variable name, or 'Nothing' when it is unset. Pure, so the
-- whole parse is testable by passing a stub lookup.
parseEnvConfig :: (Text -> Maybe Text) -> EnvConfig
parseEnvConfig look =
  EnvConfig
    { serviceName = parseServiceName look
    , resourceAttributes = parseResourceAttributes look
    , traceContextPropagators = traceContexts
    , baggagePropagators = baggages
    , tracesSampler = parseSampler look
    }
  where
    (traceContexts, baggages) = parsePropagators look

-- | Resolve the service name: @OTEL_SERVICE_NAME@ if set and non-empty,
-- otherwise the @service.name@ entry from @OTEL_RESOURCE_ATTRIBUTES@, otherwise
-- 'Nothing'.
parseServiceName :: (Text -> Maybe Text) -> Maybe Text
parseServiceName look =
  case nonEmpty =<< look "OTEL_SERVICE_NAME" of
    Just name -> Just name
    Nothing -> lookup "service.name" (resourcePairs look)
  where
    nonEmpty t = let s = T.strip t in if T.null s then Nothing else Just s

-- | Parse @OTEL_RESOURCE_ATTRIBUTES@ into typed attributes (string-valued, as
-- the wire format carries only strings). Absent or empty yields @[]@.
parseResourceAttributes :: (Text -> Maybe Text) -> [Attribute]
parseResourceAttributes look = [key .= value | (key, value) <- resourcePairs look]

-- | The raw @OTEL_RESOURCE_ATTRIBUTES@ key-value pairs. The variable uses the
-- W3C Baggage octet format (comma-separated @key=value@ with percent-encoded
-- values), so the resilient baggage parser reads it: malformed entries are
-- skipped and values are percent-decoded.
resourcePairs :: (Text -> Maybe Text) -> [(Text, Text)]
resourcePairs look =
  case look "OTEL_RESOURCE_ATTRIBUTES" of
    Nothing -> []
    Just raw -> [(key, baggageValue entry) | (key, entry) <- baggageToList (parseBaggage raw)]

-- | Parse @OTEL_PROPAGATORS@ into the trace-context and baggage propagator lists,
-- preserving order (which sets inject-and-extract priority). Unset defaults to
-- @tracecontext,baggage@; the special token @none@ disables all propagators;
-- unrecognised tokens are ignored. A token may contribute to both lists (e.g.
-- @jaeger@ has a trace-context and a baggage side).
parsePropagators
  :: (Text -> Maybe Text)
  -> ([TraceContextPropagator], [BaggagePropagator])
parsePropagators look =
  case fmap tokenize (look "OTEL_PROPAGATORS") of
    Nothing -> ([w3cTraceContext], [w3cBaggage])
    Just tokens
      | "none" `elem` tokens -> ([], [])
      | otherwise -> (mapMaybe traceContextByToken tokens, mapMaybe baggageByToken tokens)
  where
    tokenize = filter (not . T.null) . map (T.toLower . T.strip) . T.splitOn ","

-- | Parse @OTEL_TRACES_SAMPLER@ (and its @OTEL_TRACES_SAMPLER_ARG@ ratio for the
-- @traceidratio@ variants) into a 'Sampler'. An unset or unrecognised sampler
-- name degrades to the default, @parentbased_always_on@. The ratio defaults to
-- @1.0@ when the argument is absent or unparsable.
parseSampler :: (Text -> Maybe Text) -> Sampler
parseSampler look =
  case fmap (T.toLower . T.strip) (look "OTEL_TRACES_SAMPLER") of
    Just "always_on" -> alwaysOn
    Just "always_off" -> alwaysOff
    Just "traceidratio" -> traceIdRatioBased ratio
    Just "parentbased_always_on" -> parentBased (defaultParentBasedConfig alwaysOn)
    Just "parentbased_always_off" -> parentBased (defaultParentBasedConfig alwaysOff)
    Just "parentbased_traceidratio" -> parentBased (defaultParentBasedConfig (traceIdRatioBased ratio))
    _ -> parentBased (defaultParentBasedConfig alwaysOn)
  where
    ratio = maybe 1.0 (fromMaybe 1.0 . readMaybe . T.unpack . T.strip) (look "OTEL_TRACES_SAMPLER_ARG")
