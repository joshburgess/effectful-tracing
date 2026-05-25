-- |
-- Module      : Main
-- Description : tasty entry point for the effectful-tracing test suite.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- Per-phase specs live under @test/Effectful/Tracing/@ and are aggregated here.
{-# LANGUAGE CPP #-}

module Main (main) where

import Test.Tasty (TestTree, defaultMain, testGroup)

import Effectful.Tracing.AsyncExceptionSpec qualified as AsyncExceptionSpec
import Effectful.Tracing.AttributeSpec qualified as AttributeSpec
import Effectful.Tracing.BaggageSpec qualified as BaggageSpec
import Effectful.Tracing.CompileTest qualified as CompileTest
import Effectful.Tracing.ConcurrentSpec qualified as ConcurrentSpec
import Effectful.Tracing.FuzzSpec qualified as FuzzSpec
import Effectful.Tracing.IdGenSpec qualified as IdGenSpec
import Effectful.Tracing.IdsSpec qualified as IdsSpec
import Effectful.Tracing.InMemorySpec qualified as InMemorySpec
import Effectful.Tracing.Instrumentation.DatabaseSpec qualified as DatabaseSpec
import Effectful.Tracing.LifecycleSpec qualified as LifecycleSpec
import Effectful.Tracing.LogSpec qualified as LogSpec
import Effectful.Tracing.NoOpSpec qualified as NoOpSpec
import Effectful.Tracing.PrettyPrintLeakSpec qualified as PrettyPrintLeakSpec
import Effectful.Tracing.PrettyPrintSpec qualified as PrettyPrintSpec
import Effectful.Tracing.Propagation.B3Spec qualified as B3Spec
import Effectful.Tracing.Propagation.JaegerSpec qualified as JaegerSpec
import Effectful.Tracing.PropagationSpec qualified as PropagationSpec
import Effectful.Tracing.PropertySpec qualified as PropertySpec
import Effectful.Tracing.SamplerSpec qualified as SamplerSpec
import Effectful.Tracing.TestingSpec qualified as TestingSpec
import Effectful.Tracing.ThunkSpec qualified as ThunkSpec
import Effectful.Tracing.TypesSpec qualified as TypesSpec

#ifdef OTEL
import Effectful.Tracing.OpenTelemetrySpec qualified as OpenTelemetrySpec
#endif

#ifdef WAI
import Effectful.Tracing.Instrumentation.WaiSpec qualified as WaiSpec
#endif

#ifdef HTTP_CLIENT
import Effectful.Tracing.Instrumentation.HttpClientSpec qualified as HttpClientSpec
#endif

#ifdef SERVANT
import Effectful.Tracing.Instrumentation.ServantSpec qualified as ServantSpec
#endif

main :: IO ()
main =
  defaultMain
    ( testGroup
        "effectful-tracing"
        ( [ PropertySpec.tests
          , TypesSpec.tests
          , AttributeSpec.tests
          , IdsSpec.tests
          , IdGenSpec.tests
          , CompileTest.tests
          , NoOpSpec.tests
          , InMemorySpec.tests
          , DatabaseSpec.tests
          , LifecycleSpec.tests
          , LogSpec.tests
          , PrettyPrintSpec.tests
          , PrettyPrintLeakSpec.tests
          , SamplerSpec.tests
          , TestingSpec.tests
          , ConcurrentSpec.tests
          , PropagationSpec.tests
          , B3Spec.tests
          , JaegerSpec.tests
          , BaggageSpec.tests
          , FuzzSpec.tests
          , ThunkSpec.tests
          , AsyncExceptionSpec.tests
          ]
            <> otelTests
            <> waiTests
            <> httpClientTests
            <> servantTests
        )
    )

-- | The OpenTelemetry interpreter tests, present only when built with @+otel@.
otelTests :: [TestTree]
#ifdef OTEL
otelTests = [OpenTelemetrySpec.tests]
#else
otelTests = []
#endif

-- | The WAI middleware tests, present only when built with @+wai@.
waiTests :: [TestTree]
#ifdef WAI
waiTests = [WaiSpec.tests]
#else
waiTests = []
#endif

-- | The http-client tests, present only when built with @+http-client@.
httpClientTests :: [TestTree]
#ifdef HTTP_CLIENT
httpClientTests = [HttpClientSpec.tests]
#else
httpClientTests = []
#endif

-- | The Servant middleware tests, present only when built with @+servant@.
servantTests :: [TestTree]
#ifdef SERVANT
servantTests = [ServantSpec.tests]
#else
servantTests = []
#endif
