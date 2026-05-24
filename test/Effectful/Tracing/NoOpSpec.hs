{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.NoOpSpec
-- Description : Behavioural tests for the no-op interpreter.
module Effectful.Tracing.NoOpSpec
  ( tests
  ) where

import Control.Exception (ErrorCall (ErrorCall), throwIO, toException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)

import Effectful (Eff, IOE, runEff, (:>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing
  ( SpanStatus (Ok)
  , Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , getActiveSpan
  , recordException
  , runTracerNoOp
  , setStatus
  , withSpan
  , (.=)
  )

tests :: TestTree
tests =
  testGroup
    "No-op interpreter"
    [ testCase "nested withSpan returns the inner value" $ do
        result <- runEff (runTracerNoOp nestedValue)
        result @?= 42
    , testCase "exception inside withSpan propagates" $ do
        outcome <- try (runEff (runTracerNoOp throwing))
        case outcome of
          Left (ErrorCall msg) -> msg @?= "boom"
          Right () -> assertBool "expected the exception to propagate" False
    , testCase "emit operations are silent and getActiveSpan is Nothing" $ do
        result <- runEff (runTracerNoOp emitsEverything)
        result @?= 7
    ]

-- | Nested spans thread their inner values through untouched.
nestedValue :: Tracer :> es => Eff es Int
nestedValue = withSpan "outer" $ do
  x <- withSpan "left" (pure 20)
  y <- withSpan "right" (pure 22)
  pure (x + y)

-- | An exception raised inside a span must not be swallowed by the interpreter.
throwing :: (Tracer :> es, IOE :> es) => Eff es ()
throwing = withSpan "outer" $ do
  addAttribute "before.throw" (1 :: Int)
  liftIO (throwIO (ErrorCall "boom"))

-- | Every emit operation runs without effect, and with no active span
-- 'getActiveSpan' is 'Nothing' (so this returns 7, not 0).
emitsEverything :: Tracer :> es => Eff es Int
emitsEverything = do
  addAttribute "user.id" ("u123" :: Text)
  addAttributes ["http.method" .= ("GET" :: Text)]
  addEvent "fetching" []
  setStatus Ok
  recordException (toException (ErrorCall "ignored"))
  maybe 7 (const 0) <$> getActiveSpan
