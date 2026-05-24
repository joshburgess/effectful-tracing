{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Effectful.Tracing.Interpreter.NoOp
-- Description : An interpreter that discards all tracing.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- 'runTracerNoOp' satisfies the 'Tracer' effect with no observable effect:
-- scoped actions run unchanged, every emit operation is silently dropped, and
-- there is never an active span. It is the interpreter to reach for when a
-- component requires @Tracer@ but the caller does not want tracing (tests,
-- benchmarks, or production paths where tracing is disabled), and it is the
-- baseline against which the library's near-zero-overhead claim is measured.
module Effectful.Tracing.Interpreter.NoOp
  ( runTracerNoOp
  ) where

import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)

import Effectful.Tracing.Effect
  ( Tracer
      ( AddAttribute
      , AddAttributes
      , AddEvent
      , GetActiveSpan
      , RecordException
      , SetStatus
      , WithSpan
      )
  )

-- | Discharge the 'Tracer' effect by doing nothing. 'withSpan' runs its body in
-- the current scope (no span is created), the emit operations are no-ops, and
-- 'getActiveSpan' returns 'Nothing'. Exceptions thrown inside a scoped action
-- propagate unchanged.
--
-- > runEff . runTracerNoOp $ do
-- >   withSpan "outer" $ addAttribute "ignored" (1 :: Int) >> pure ()
runTracerNoOp :: Eff (Tracer : es) a -> Eff es a
runTracerNoOp = interpret $ \env -> \case
  WithSpan _ _ action -> localSeqUnlift env (\unlift -> unlift action)
  AddAttribute _ _ -> pure ()
  AddAttributes _ -> pure ()
  AddEvent _ _ -> pure ()
  RecordException _ -> pure ()
  SetStatus _ -> pure ()
  GetActiveSpan -> pure Nothing
