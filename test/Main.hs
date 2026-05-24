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

import Effectful.Tracing.AttributeSpec qualified as AttributeSpec
import Effectful.Tracing.CompileTest qualified as CompileTest
import Effectful.Tracing.ConcurrentSpec qualified as ConcurrentSpec
import Effectful.Tracing.FuzzSpec qualified as FuzzSpec
import Effectful.Tracing.IdsSpec qualified as IdsSpec
import Effectful.Tracing.InMemorySpec qualified as InMemorySpec
import Effectful.Tracing.LifecycleSpec qualified as LifecycleSpec
import Effectful.Tracing.NoOpSpec qualified as NoOpSpec
import Effectful.Tracing.PrettyPrintSpec qualified as PrettyPrintSpec
import Effectful.Tracing.PropagationSpec qualified as PropagationSpec
import Effectful.Tracing.PropertySpec qualified as PropertySpec
import Effectful.Tracing.SamplerSpec qualified as SamplerSpec
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

main :: IO ()
main =
  defaultMain
    ( testGroup
        "effectful-tracing"
        ( [ PropertySpec.tests
          , TypesSpec.tests
          , AttributeSpec.tests
          , IdsSpec.tests
          , CompileTest.tests
          , NoOpSpec.tests
          , InMemorySpec.tests
          , LifecycleSpec.tests
          , PrettyPrintSpec.tests
          , SamplerSpec.tests
          , ConcurrentSpec.tests
          , PropagationSpec.tests
          , FuzzSpec.tests
          ]
            <> otelTests
            <> waiTests
            <> httpClientTests
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
