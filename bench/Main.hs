-- |
-- Module      : Main
-- Description : tasty-bench entry point for the effectful-tracing benchmarks.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- Phase 0 scaffolding: no benchmarks yet. The no-op overhead benchmark
-- (Phase 3) and later workloads are added here.
module Main (main) where

import Test.Tasty.Bench (defaultMain)

main :: IO ()
main = defaultMain []
