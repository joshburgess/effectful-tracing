-- | A small worker loop showing the everyday local-development shape of
-- @effectful-tracing@: one span per unit of work, an interpreter chosen at
-- runtime, a failing job that still records an @Error@ span, and a
-- fire-and-forget background task that becomes its own linked trace.
--
-- Pick the interpreter with the @ET_TRACER@ environment variable:
--
-- * unset / anything else: pretty-print each finished trace to @stderr@
-- * @noop@: tracing compiles to nothing (the production default)
-- * @memory@: capture spans in memory and print a one-line summary
--
-- > cabal run worker                 # pretty tree on stderr
-- > ET_TRACER=memory cabal run worker
-- > ET_TRACER=noop   cabal run worker
module Main (main) where

import Control.Monad (forM_, void, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stderr)

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Effectful.Exception (SomeException, throwIO, try)

import Effectful.Tracing
  ( Span (spanName)
  , Tracer
  , addAttribute
  , addEvent
  , withSpan
  , (.=)
  )
import Effectful.Tracing.Concurrent (forkLinked)
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )
import Effectful.Tracing.Interpreter.NoOp (runTracerNoOp)
import Effectful.Tracing.Interpreter.PrettyPrint
  ( PrettyPrintConfig (showEvents, timeFormat, useColor)
  , TimeFormat (RelativeToTraceStart)
  , defaultPrettyPrintConfig
  , runTracerPretty
  )

-- | A unit of work for the worker to process.
data Job = Job
  { jobId :: Int
  , jobLabel :: Text
  , jobRows :: Int
  , jobFails :: Bool
  }

-- | A fixed batch, including one job that fails so the Error path is visible.
jobs :: [Job]
jobs =
  [ Job 1 "import" 12 False
  , Job 2 "reconcile" 0 True
  , Job 3 "export" 47 False
  ]

-- | Process one job inside its own root span, with a nested child span for the
-- fetch. Throwing here finalizes the span with an @Error@ status and an
-- @exception@ event before the exception propagates out of 'withSpan'.
processJob :: (Tracer :> es) => Job -> Eff es ()
processJob job = withSpan "worker.handleJob" $ do
  addAttribute "job.id" (jobId job)
  addAttribute "job.label" (jobLabel job)
  withSpan "db.fetch" $
    addEvent "rows.read" ["rows" .= jobRows job]
  when (jobFails job) $
    throwIO (userError "downstream service unavailable")

-- | Run the batch, then spawn one linked background trace and wait for it.
runWorker :: (Tracer :> es, Concurrent :> es, IOE :> es) => Eff es ()
runWorker = do
  -- A failing job must not stop the worker, so each job is isolated. The span
  -- is still recorded as an error even though we swallow the exception here.
  forM_ jobs $ \job ->
    void (try @SomeException (processJob job))

  -- Fire-and-forget work spawned from within a span: 'forkLinked' starts it as
  -- its own root trace with a link back to "request", rather than nesting it
  -- under a parent that has already returned.
  done <- newEmptyMVar
  withSpan "request" $ do
    addEvent "spawn.background" []
    void $ forkLinked $ do
      withSpan "background.reindex" $ do
        addAttribute "reindex.shard" (7 :: Int)
        threadDelay 1000
      putMVar done ()
  takeMVar done

main :: IO ()
main = do
  mode <- fromMaybe "pretty" <$> lookupEnv "ET_TRACER"
  case mode of
    "noop" -> do
      putStrLn "[noop] running worker; tracing compiles to nothing."
      runEff . runConcurrent $ runTracerNoOp runWorker
    "memory" -> do
      putStrLn "[memory] running worker; capturing spans in memory."
      names <- runEff . runConcurrent $ do
        captured <- newCapturedSpans
        runTracerInMemory captured runWorker
        map spanName <$> readCapturedSpans captured
      putStrLn ("captured " <> show (length names) <> " spans: " <> show names)
    _ -> do
      putStrLn "[pretty] running worker; printing each finished trace to stderr."
      color <- hIsTerminalDevice stderr
      let config =
            (defaultPrettyPrintConfig stderr)
              { useColor = color
              , showEvents = True
              , timeFormat = RelativeToTraceStart
              }
      runEff . runConcurrent $ runTracerPretty config runWorker
