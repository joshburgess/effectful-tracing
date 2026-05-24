-- |
-- Module      : Main
-- Description : Space-leak regression guard for the span lifecycle.
--
-- This is a standalone workload, separate from the main tasty suite, run under
-- a deliberately tiny maximum stack (@-K1K@, set in the cabal stanza). It opens
-- and closes a large number of spans through the in-memory interpreter and then
-- forces every captured span with a strict fold to a scalar.
--
-- The point of the tiny stack is to turn a space leak into a hard failure. If a
-- regression let completed spans accumulate as a chain of thunks (a lazy
-- accumulator, a non-strict sink write, an un-forced field), forcing them here
-- would build an O(n) evaluation stack and overflow @-K1K@, failing the test.
-- The current strict lifecycle (spans forced to WHNF before they reach the
-- sink, a strict 'foldl'' here) runs in O(1) stack regardless of span count.
--
-- It is intentionally tasty-free: the tasty/hedgehog machinery legitimately
-- needs more than a 1K stack, so it cannot share this process's RTS options.
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, when)
import System.Exit (exitFailure)
#if !MIN_VERSION_base(4,20,0)
import Data.List (foldl')
#endif

import Effectful (Eff, runEff, (:>))

import Effectful.Tracing (Span (spanAttributes), Tracer, addAttribute, withSpan)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

-- | How many spans to open, close, and then force. Large enough that an O(n)
-- stack from a thunk chain would blow the 1K limit many times over.
spanCount :: Int
spanCount = 100000

-- | A flat sequence of completed spans, each carrying one attribute.
workload :: (Tracer :> es) => Eff es ()
workload =
  forM_ [1 .. spanCount] $ \i ->
    withSpan "tick" (addAttribute "i" (i :: Int))

main :: IO ()
main = do
  total <- runEff $ do
    captured <- newCapturedSpans
    _ <- runTracerInMemory captured workload
    spans <- readCapturedSpans captured
    -- Strict fold to a scalar. A leaky lazy accumulator (or un-forced span
    -- field) would defer this work into an O(n) thunk chain and overflow the
    -- 1K stack when the result is finally demanded below.
    pure $! foldl' (\acc s -> acc + length (spanAttributes s)) (0 :: Int) spans
  when (total /= spanCount) $ do
    putStrLn ("space-leak guard: expected " <> show spanCount <> " attributes, saw " <> show total)
    exitFailure
  putStrLn ("space-leak guard: forced " <> show spanCount <> " completed spans under -K1K")
