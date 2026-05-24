-- | A runnable version of the cookbook's "sample 1% but keep more of what
-- matters" recipe. It defines a custom 'Sampler' that always keeps spans a
-- caller flags as priority and otherwise falls back to a 1% ratio sampler, then
-- runs a batch through the in-memory interpreter and reports how many of each
-- kind survived.
--
-- > cabal run sampling
--
-- The priority count is exact (all are kept); the routine count is random but
-- lands near 1% of the spans started.
module Main (main) where

import Control.Monad (forM_)

import Effectful (Eff, runEff, (:>))
import Effectful.Tracing
  ( Span (spanName)
  , SpanArguments (attributes)
  , Tracer
  , addAttribute
  , defaultSpanArguments
  , withSpan
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrBool))
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemoryWith
  )
import Effectful.Tracing.Sampler
  ( Sampler (Sampler, samplerName, shouldSample)
  , SamplerInput (initialAttributes)
  , SamplingDecision (RecordAndSample)
  , simpleResult
  , traceIdRatioBased
  )

-- | Keep a span the caller flagged with @sampling.priority = True@; otherwise
-- defer to a 1% trace-id ratio sampler. A 'Sampler' is just a record, so this
-- composes a built-in inside a custom one.
priorityOr1Percent :: Sampler
priorityOr1Percent =
  Sampler
    { samplerName = "PriorityOr1Percent"
    , shouldSample = \input ->
        if flagged (initialAttributes input)
          then pure (simpleResult RecordAndSample)
          else shouldSample (traceIdRatioBased 0.01) input
    }
  where
    flagged = any (\(Attribute k v) -> k == "sampling.priority" && v == AttrBool True)

routineCount, priorityCount :: Int
routineCount = 1000
priorityCount = 5

-- | Open a batch of independent root spans: many routine ones (each its own
-- trace id, so each gets an independent 1% decision) and a few priority ones.
demo :: (Tracer :> es) => Eff es ()
demo = do
  forM_ [1 .. routineCount] $ \i ->
    withSpan "routine" (addAttribute "job.id" (i :: Int))
  forM_ [1 .. priorityCount] $ \i ->
    withSpan'
      "priority"
      defaultSpanArguments {attributes = ["sampling.priority" .= True, "job.id" .= (i :: Int)]}
      (pure ())

main :: IO ()
main = do
  spans <- runEff $ do
    captured <- newCapturedSpans
    runTracerInMemoryWith priorityOr1Percent captured demo
    readCapturedSpans captured
  let kept name = length (filter ((== name) . spanName) spans)
  putStrLn "sampler PriorityOr1Percent: keep all priority spans, ~1% of routine spans"
  putStrLn ("routine started: " <> show routineCount <> ", captured: " <> show (kept "routine"))
  putStrLn ("priority started: " <> show priorityCount <> ", captured: " <> show (kept "priority"))
