{-# LANGUAGE CPP #-}
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
-- 'runTracerNoOp'. The comparison entries report the traced run as a ratio of the
-- plain baseline within a single run, since absolute timings are not comparable
-- across machines.
--
-- Read the ratio, not the absolute numbers. The target is < 1.05 (5% overhead),
-- measured on a quiet, dedicated machine. CI runners are noisy shared VMs, so a
-- 5% gate would flap; the @realistic-op@ comparison therefore uses
-- 'bcompareWithin' with a deliberately loose upper bound of @1.20@, so the
-- benchmark process exits non-zero (failing the CI gate) only on a gross
-- regression, not on ordinary runner noise. The @trivial-op@ comparison is left
-- as a plain 'bcompare': its baseline is essentially free, so its ratio is the
-- raw per-'withSpan' dispatch cost and is inherently large, which is informative
-- but not a meaningful pass/fail threshold.
module Main (main) where

import Control.Monad (foldM)

-- @foldl'@ moved into Prelude in base-4.20 (GHC 9.10); import it explicitly on
-- older bases so the package still builds on GHC 9.6 / 9.8.
#if !MIN_VERSION_base(4,20,0)
import Data.List (foldl')
#endif

import Effectful (Eff, runEff, (:>))
import Effectful.Tracing (Tracer, runTracerNoOp, withSpan)
import Test.Tasty.Bench (bcompare, bcompareWithin, bench, bgroup, defaultMain, nfIO)

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
        , -- Fail the run (and so the CI gate) only if the traced chain is more
          -- than 1.20x the plain baseline; a speedup or any ratio at or below
          -- 1.20 passes. The lower bound is 0 because traced is never expected
          -- to be meaningfully faster than plain.
          bcompareWithin 0 1.20 "$NF == \"plain\" && $(NF-1) == \"realistic-op\"" $
            bench "withSpan-noop" (nfIO (runEff (runTracerNoOp (tracedChain perOp n))))
        ]
    ]
  where
    n = 1000
    perOp = 600
