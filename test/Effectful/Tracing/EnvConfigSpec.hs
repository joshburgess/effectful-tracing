{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.EnvConfigSpec
-- Description : Tests for reading OTel configuration from the environment.
--
-- The parse is pure (a lookup function), so every case is exercised with a stub
-- environment built from an association list. The four readers each get their
-- own group: service-name resolution and its fallback into resource attributes,
-- resource-attribute decoding, propagator-token resolution (including the
-- defaults, @none@, and a token that feeds both lists), and the sampler name and
-- ratio handling.
module Effectful.Tracing.EnvConfigSpec
  ( tests
  ) where

import Data.Text (Text)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrText))
import Effectful.Tracing.EnvConfig
  ( EnvConfig (baggagePropagators, resourceAttributes, serviceName, traceContextPropagators, tracesSampler)
  , defaultEnvConfig
  , parseEnvConfig
  , parsePropagators
  , parseSampler
  , parseServiceName
  )
import Effectful.Tracing.Propagation.Composite (baggageName, traceContextName)
import Effectful.Tracing.Sampler (samplerName)

-- | Build a lookup function from an association list of variable name to value.
stubEnv :: [(Text, Text)] -> (Text -> Maybe Text)
stubEnv entries name = lookup name entries

tests :: TestTree
tests =
  testGroup
    "EnvConfig"
    [ testGroup "serviceName" serviceNameTests
    , testGroup "resourceAttributes" resourceAttributeTests
    , testGroup "propagators" propagatorTests
    , testGroup "sampler" samplerTests
    , testGroup "defaults" defaultTests
    ]

serviceNameTests :: [TestTree]
serviceNameTests =
  [ testCase "reads OTEL_SERVICE_NAME" $
      parseServiceName (stubEnv [("OTEL_SERVICE_NAME", "checkout")]) @?= Just "checkout"
  , testCase "trims surrounding whitespace" $
      parseServiceName (stubEnv [("OTEL_SERVICE_NAME", "  checkout  ")]) @?= Just "checkout"
  , testCase "an empty value is treated as unset" $
      parseServiceName (stubEnv [("OTEL_SERVICE_NAME", "   ")]) @?= Nothing
  , testCase "falls back to service.name in OTEL_RESOURCE_ATTRIBUTES" $
      parseServiceName (stubEnv [("OTEL_RESOURCE_ATTRIBUTES", "service.name=billing,team=core")])
        @?= Just "billing"
  , testCase "OTEL_SERVICE_NAME wins over the resource attribute" $
      parseServiceName
        ( stubEnv
            [ ("OTEL_SERVICE_NAME", "checkout")
            , ("OTEL_RESOURCE_ATTRIBUTES", "service.name=billing")
            ]
        )
        @?= Just "checkout"
  , testCase "absent everywhere is Nothing" $
      parseServiceName (stubEnv []) @?= Nothing
  ]

resourceAttributeTests :: [TestTree]
resourceAttributeTests =
  [ testCase "decodes comma-separated key=value pairs" $
      resourceAttributes (parseEnvConfig (stubEnv [("OTEL_RESOURCE_ATTRIBUTES", "team=core,region=us-east-1")]))
        @?= [Attribute "region" (AttrText "us-east-1"), Attribute "team" (AttrText "core")]
  , testCase "percent-decodes values" $
      resourceAttributes (parseEnvConfig (stubEnv [("OTEL_RESOURCE_ATTRIBUTES", "note=a%20b")]))
        @?= [Attribute "note" (AttrText "a b")]
  , testCase "absent yields no attributes" $
      resourceAttributes (parseEnvConfig (stubEnv [])) @?= []
  ]

propagatorTests :: [TestTree]
propagatorTests =
  [ testCase "unset defaults to tracecontext + baggage" $ do
      let (traces, baggages) = parsePropagators (stubEnv [])
      map traceContextName traces @?= ["tracecontext"]
      map baggageName baggages @?= ["baggage"]
  , testCase "splits and resolves a token list in order" $ do
      let (traces, baggages) = parsePropagators (stubEnv [("OTEL_PROPAGATORS", "b3, tracecontext, baggage")])
      map traceContextName traces @?= ["b3", "tracecontext"]
      map baggageName baggages @?= ["baggage"]
  , testCase "jaeger contributes to both lists" $ do
      let (traces, baggages) = parsePropagators (stubEnv [("OTEL_PROPAGATORS", "jaeger")])
      map traceContextName traces @?= ["jaeger"]
      map baggageName baggages @?= ["jaeger"]
  , testCase "none disables all propagators" $ do
      let (traces, baggages) = parsePropagators (stubEnv [("OTEL_PROPAGATORS", "tracecontext,none")])
      map traceContextName traces @?= []
      map baggageName baggages @?= []
  , testCase "unrecognised tokens are ignored" $ do
      let (traces, baggages) = parsePropagators (stubEnv [("OTEL_PROPAGATORS", "nonsense,b3multi")])
      map traceContextName traces @?= ["b3multi"]
      map baggageName baggages @?= []
  ]

samplerTests :: [TestTree]
samplerTests =
  [ testCase "always_on" $
      samplerName (parseSampler (stubEnv [("OTEL_TRACES_SAMPLER", "always_on")])) @?= "AlwaysOn"
  , testCase "always_off" $
      samplerName (parseSampler (stubEnv [("OTEL_TRACES_SAMPLER", "always_off")])) @?= "AlwaysOff"
  , testCase "traceidratio uses the arg" $
      samplerName
        ( parseSampler
            ( stubEnv
                [ ("OTEL_TRACES_SAMPLER", "traceidratio")
                , ("OTEL_TRACES_SAMPLER_ARG", "0.25")
                ]
            )
        )
        @?= "TraceIdRatioBased{0.25}"
  , testCase "traceidratio defaults the ratio to 1.0 when the arg is absent" $
      samplerName (parseSampler (stubEnv [("OTEL_TRACES_SAMPLER", "traceidratio")]))
        @?= "TraceIdRatioBased{1.0}"
  , testCase "parentbased_traceidratio wraps the ratio sampler" $
      samplerName
        ( parseSampler
            ( stubEnv
                [ ("OTEL_TRACES_SAMPLER", "parentbased_traceidratio")
                , ("OTEL_TRACES_SAMPLER_ARG", "0.1")
                ]
            )
        )
        @?= "ParentBased{TraceIdRatioBased{0.1}}"
  , testCase "an unrecognised name degrades to parentbased_always_on" $
      samplerName (parseSampler (stubEnv [("OTEL_TRACES_SAMPLER", "made_up")]))
        @?= "ParentBased{AlwaysOn}"
  , testCase "unset degrades to parentbased_always_on" $
      samplerName (parseSampler (stubEnv [])) @?= "ParentBased{AlwaysOn}"
  ]

defaultTests :: [TestTree]
defaultTests =
  [ testCase "defaultEnvConfig has no service name" $
      serviceName defaultEnvConfig @?= Nothing
  , testCase "defaultEnvConfig has the default propagators" $ do
      map traceContextName (traceContextPropagators defaultEnvConfig) @?= ["tracecontext"]
      map baggageName (baggagePropagators defaultEnvConfig) @?= ["baggage"]
  , testCase "defaultEnvConfig has the default sampler" $
      samplerName (tracesSampler defaultEnvConfig) @?= "ParentBased{AlwaysOn}"
  ]
