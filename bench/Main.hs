{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : tasty-bench entry point for the effectful-tracing benchmarks.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
--
-- The no-op overhead benchmark (Phase 3): a chain of @n@ trivial operations run
-- plain versus the same chain with each operation wrapped in @withSpan@ under
-- 'runTracerNoOp'. The @bcompare@ entry reports the traced run as a ratio of the
-- plain baseline within a single run, since absolute timings are not comparable
-- across machines.
--
-- Read the ratio, not the absolute numbers. The target is < 1.05 (5% overhead),
-- measured on a quiet, dedicated machine. CI runners are noisy shared VMs, so a
-- 5% gate would flap; treat the CI number as informational and only investigate
-- a gross regression (say > 1.20).
module Main (main) where

import Control.Monad (foldM)

import Effectful (Eff, runEff, (:>))
import Effectful.Tracing (Tracer, runTracerNoOp, withSpan)
import Test.Tasty.Bench (bcompare, bench, bgroup, defaultMain, nfIO)

-- | A chain of @n@ accumulating operations, each doing @work@ units of
-- computation, with no tracing involved.
plainChain :: Int -> Int -> Eff es Int
plainChain perOp n = foldM step 0 [1 .. n]
  where
    step acc i = pure (acc + work perOp i)

-- | The same chain, but each operation runs inside its own (no-op) span.
tracedChain :: Tracer :> es => Int -> Int -> Eff es Int
tracedChain perOp n = foldM step 0 [1 .. n]
  where
    step acc i = withSpan "step" (pure (acc + work perOp i))

-- | A pure unit of CPU work whose cost scales with the first argument. @0@ is
-- effectively free, isolating the fixed per-@withSpan@ cost; a larger value
-- stands in for the real work a span normally wraps.
work :: Int -> Int -> Int
work perOp seed = foldl' (+) seed [1 .. perOp]
{-# NOINLINE work #-}

main :: IO ()
main =
  defaultMain
    [ -- Each span wraps an essentially free operation, so the ratio is the raw
      -- per-'withSpan' dispatch/unlift cost, not a realistic overhead figure.
      bgroup
        "trivial-op"
        [ bench "plain" (nfIO (runEff (plainChain 0 n)))
        , bcompare "$NF == \"plain\" && $(NF-1) == \"trivial-op\"" $
            bench "withSpan-noop" (nfIO (runEff (runTracerNoOp (tracedChain 0 n))))
        ]
    , -- Each span wraps a realistic unit of work; the ratio shows the overhead
      -- a caller actually pays. This is the figure the 5% target refers to.
      bgroup
        "realistic-op"
        [ bench "plain" (nfIO (runEff (plainChain perOp n)))
        , bcompare "$NF == \"plain\" && $(NF-1) == \"realistic-op\"" $
            bench "withSpan-noop" (nfIO (runEff (runTracerNoOp (tracedChain perOp n))))
        ]
    ]
  where
    n = 1000
    perOp = 600
