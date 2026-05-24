-- |
-- Module      : Main
-- Description : tasty entry point for the effectful-tracing test suite.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- Per-phase specs live under @test/Effectful/Tracing/@ and are aggregated here.
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Effectful.Tracing.CompileTest qualified as CompileTest
import Effectful.Tracing.InMemorySpec qualified as InMemorySpec
import Effectful.Tracing.NoOpSpec qualified as NoOpSpec
import Effectful.Tracing.PrettyPrintSpec qualified as PrettyPrintSpec
import Effectful.Tracing.PropertySpec qualified as PropertySpec
import Effectful.Tracing.SamplerSpec qualified as SamplerSpec

main :: IO ()
main =
  defaultMain
    ( testGroup
        "effectful-tracing"
        [ PropertySpec.tests
        , CompileTest.tests
        , NoOpSpec.tests
        , InMemorySpec.tests
        , PrettyPrintSpec.tests
        , SamplerSpec.tests
        ]
    )
