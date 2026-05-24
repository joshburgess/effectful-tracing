-- |
-- Module      : Main
-- Description : tasty entry point for the effectful-tracing test suite.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- Phase 0 scaffolding: the suite runs and reports zero tests. Per-phase specs
-- are added under @test/Effectful/Tracing/@ as the library is built out.
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "effectful-tracing" [])
