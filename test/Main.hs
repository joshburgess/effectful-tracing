-- |
-- Module      : Main
-- Description : tasty entry point for the effectful-tracing test suite.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- Per-phase specs live under @test/Effectful/Tracing/@ and are aggregated here.
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Effectful.Tracing.PropertySpec qualified as PropertySpec

main :: IO ()
main =
  defaultMain
    (testGroup "effectful-tracing" [PropertySpec.tests])
