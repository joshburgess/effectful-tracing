{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.AmqpSpec
-- Description : Tests for the broker-free helpers in the RabbitMQ binding.
--
-- The RabbitMQ wrappers ('Effectful.Tracing.Instrumentation.Amqp.publishMsgTraced',
-- 'Effectful.Tracing.Instrumentation.Amqp.getMsgTraced', and
-- 'Effectful.Tracing.Instrumentation.Amqp.withProcessSpan') all need a live
-- broker @Channel@ (or an @Envelope@ that embeds one), so they are covered by the
-- compile-only mirror in "Effectful.Tracing.CompileTest". 'messageHeaders' is the
-- one piece that is pure and broker-free: it decodes the trace-context headers a
-- consumer reads back, so it is exercised here directly.
--
-- Only present when built with @+amqp@.
module Effectful.Tracing.Instrumentation.AmqpSpec
  ( tests
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)

import Hedgehog (Gen, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)
import Test.Tasty.HUnit (testCase, (@?=))

import Network.AMQP (Message (msgHeaders), newMsg)
import Network.AMQP.Types
  ( FieldTable (FieldTable)
  , FieldValue (FVBool, FVInt32, FVString)
  )

import Effectful.Tracing.Instrumentation.Amqp (messageHeaders)

tests :: TestTree
tests =
  testGroup
    "Effectful.Tracing.Instrumentation.Amqp"
    [ testGroup
        "messageHeaders"
        [ testCase "a message with no headers yields no pairs" $
            messageHeaders newMsg @?= []
        , testCase "an empty header table yields no pairs" $
            messageHeaders (withHeaders []) @?= []
        , testCase "string-valued headers are decoded to text pairs" $
            messageHeaders
              (withHeaders [("traceparent", str traceparent), ("tracestate", str "k=v")])
              @?= [("traceparent", traceparent), ("tracestate", "k=v")]
        , testCase "non-string field values are dropped" $
            messageHeaders
              ( withHeaders
                  [ ("traceparent", str traceparent)
                  , ("priority", FVInt32 5)
                  , ("redelivered", FVBool True)
                  ]
              )
              @?= [("traceparent", traceparent)]
        , testProperty "every string header round-trips through messageHeaders" $
            property $ do
              entries <- forAll genStringEntries
              let fields = [(name, str value) | (name, value) <- entries]
              -- Map keying dedupes and orders by key, so compare as sorted maps.
              Map.fromList (messageHeaders (withHeaders fields))
                === Map.fromList entries
        ]
    ]
  where
    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

-- | A 'Message' carrying the given AMQP header table.
withHeaders :: [(Text, FieldValue)] -> Message
withHeaders fields = newMsg {msgHeaders = Just (FieldTable (Map.fromList fields))}

-- | A string-valued AMQP header from UTF-8 text, the way the binding writes them.
str :: Text -> FieldValue
str = FVString . encodeUtf8

-- | Header entries with distinct ASCII keys and arbitrary text values. ASCII
-- keys keep the generator from colliding on UTF-8 normalization while still
-- exercising decoding of arbitrary text values.
genStringEntries :: Gen [(Text, Text)]
genStringEntries =
  Gen.list (Range.linear 0 8) $
    (,)
      <$> Gen.text (Range.linear 1 12) Gen.alphaNum
      <*> Gen.text (Range.linear 0 24) Gen.unicode
