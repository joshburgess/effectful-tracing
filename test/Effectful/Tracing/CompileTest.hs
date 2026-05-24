{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.CompileTest
-- Description : Compile-only check that the smart-constructor API is usable.
--
-- The 'Tracer' effect has no interpreter yet, so these programs cannot be
-- /run/. They exist to prove the smart-constructor API is /usable/: if the
-- public surface stops typechecking, this module fails to compile and the test
-- suite goes red. The runtime assertion is incidental.
module Effectful.Tracing.CompileTest
  ( tests
  ) where

import Control.Exception (toException)
import Data.Text (Text)

import Effectful (Eff, IOE, (:>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Effectful.Tracing
  ( SpanArguments (kind)
  , SpanContext
  , SpanKind (Client)
  , SpanStatus (Error, Ok)
  , Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , defaultSpanArguments
  , getActiveSpan
  , recordException
  , setStatus
  , withSpan
  , withSpan'
  , (.=)
  )

tests :: TestTree
tests =
  testGroup
    "Phase 2 compile-only API"
    [ testCase "smart-constructor API typechecks" (compiles @?= ())
    ]

-- | Forcing the example programs to a concrete effect stack references them
-- (so @-Wunused-top-binds@ stays quiet) and pins their otherwise-polymorphic
-- types, without running them.
compiles :: ()
compiles =
  (nestedSpans :: Eff '[Tracer, IOE] Int)
    `seq` (spanWithArguments :: Eff '[Tracer] ())
    `seq` ()

-- | Nested spans with attribute, event, and status annotations.
nestedSpans :: Tracer :> es => Eff es Int
nestedSpans = withSpan "outer" $ do
  addAttribute "user.id" ("u123" :: Text)
  result <- withSpan "inner" $ do
    addEvent "fetching" []
    pure (42 :: Int)
  setStatus Ok
  pure result

-- | Exercises 'withSpan'' with explicit arguments, the remaining emit
-- operations, and 'getActiveSpan'.
spanWithArguments :: Tracer :> es => Eff es ()
spanWithArguments =
  withSpan' "http.get" defaultSpanArguments {kind = Client} $ do
    addAttributes ["http.method" .= ("GET" :: Text), "http.status_code" .= (200 :: Int)]
    recordException (toException (userError "transient"))
    setStatus (Error "upstream timeout")
    active <- getActiveSpan
    case active :: Maybe SpanContext of
      Nothing -> pure ()
      Just _ -> pure ()
