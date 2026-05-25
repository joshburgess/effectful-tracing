{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.MessagingSpec
-- Description : Tests for the framework-agnostic messaging span helpers.
--
-- These exercise the pure helpers ('operationTypeText', 'messagingSpanKind',
-- 'messagingSpanName', 'messagingAttributes') directly and run
-- 'withMessagingSpan' \/ 'withConsumerSpan' through the in-memory interpreter,
-- asserting the emitted span carries the producer \/ consumer kind, the
-- convention name, and exactly the @messaging.*@ attributes for the fields that
-- were set. The propagation round-trip ('injectMessageHeaders' \/
-- 'extractMessageHeaders') and the consumer continuing a remote parent are
-- covered too, since carrying the trace across the broker is the distinguishing
-- messaging behaviour. No live broker is involved.
module Effectful.Tracing.Instrumentation.MessagingSpec
  ( tests
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, withSpan)
import Effectful.Tracing.Attribute
  ( Attribute (attributeKey, attributeValue)
  , AttributeValue (AttrInt, AttrText)
  )
import Effectful.Tracing.Instrumentation.Messaging
  ( MessagingOperation
      ( messagingBatchCount
      , messagingBodySize
      , messagingConversationId
      , messagingDestination
      , messagingDestinationTemplate
      , messagingMessageId
      , messagingOperationName
      )
  , MessagingOperationType (Create, Process, Receive, Send, Settle)
  , extractMessageHeaders
  , injectMessageHeaders
  , messagingAttributes
  , messagingOperation
  , messagingSpanKind
  , messagingSpanName
  , operationTypeText
  , withConsumerSpan
  , withMessagingSpan
  )
import Effectful.Tracing.Internal.Ids (traceIdToHex)
import Effectful.Tracing.Internal.Types
  ( Span
  , SpanContext (spanContextTraceId)
  , SpanKind (Client, Consumer, Producer)
  , spanAttributes
  , spanContext
  , spanKind
  , spanName
  )
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemory
  )

tests :: TestTree
tests =
  testGroup
    "Instrumentation.Messaging"
    [ testGroup "operationTypeText" operationTypeCases
    , testGroup "messagingSpanKind" spanKindCases
    , testGroup "messagingSpanName" spanNameCases
    , testGroup "messagingAttributes" attributeCases
    , testGroup "withMessagingSpan" withMessagingSpanCases
    , testGroup "propagation" propagationCases
    ]

operationTypeCases :: [TestTree]
operationTypeCases =
  [ testCase "create" $ operationTypeText Create @?= "create"
  , testCase "send" $ operationTypeText Send @?= "send"
  , testCase "receive" $ operationTypeText Receive @?= "receive"
  , testCase "process" $ operationTypeText Process @?= "process"
  , testCase "settle" $ operationTypeText Settle @?= "settle"
  ]

spanKindCases :: [TestTree]
spanKindCases =
  [ testCase "create is a producer" $ messagingSpanKind Create @?= Producer
  , testCase "send is a producer" $ messagingSpanKind Send @?= Producer
  , testCase "receive is a consumer" $ messagingSpanKind Receive @?= Consumer
  , testCase "process is a consumer" $ messagingSpanKind Process @?= Consumer
  , testCase "settle is a client" $ messagingSpanKind Settle @?= Client
  ]

spanNameCases :: [TestTree]
spanNameCases =
  [ testCase "operation name and destination" $
      messagingSpanName
        (messagingOperation "kafka" Send) {messagingOperationName = Just "publish", messagingDestination = Just "orders"}
        @?= "publish orders"
  , testCase "falls back to the operation type for the leading word" $
      messagingSpanName (messagingOperation "kafka" Send) {messagingDestination = Just "orders"}
        @?= "send orders"
  , testCase "prefers the destination template over the destination name" $
      messagingSpanName
        (messagingOperation "kafka" Send)
          { messagingDestination = Just "orders-42"
          , messagingDestinationTemplate = Just "orders-{shard}"
          }
        @?= "send orders-{shard}"
  , testCase "operation type only when no destination is known" $
      messagingSpanName (messagingOperation "kafka" Receive) @?= "receive"
  ]

attributeCases :: [TestTree]
attributeCases =
  [ testCase "system and operation type when nothing else is set" $
      keys (messagingOperation "kafka" Send)
        @?= ["messaging.system", "messaging.operation.type"]
  , testCase "includes every set optional field in convention order" $
      keys
        (messagingOperation "kafka" Send)
          { messagingOperationName = Just "publish"
          , messagingDestination = Just "orders"
          , messagingDestinationTemplate = Just "orders-{shard}"
          , messagingMessageId = Just "m-1"
          , messagingConversationId = Just "c-1"
          , messagingBodySize = Just 128
          , messagingBatchCount = Just 4
          }
        @?= [ "messaging.system"
            , "messaging.operation.type"
            , "messaging.operation.name"
            , "messaging.destination.name"
            , "messaging.destination.template"
            , "messaging.message.id"
            , "messaging.message.conversation_id"
            , "messaging.message.body.size"
            , "messaging.batch.message_count"
            ]
  , testCase "records the system name and operation type values" $ do
      let ps = pairs (messagingOperation "rabbitmq" Process)
      lookup "messaging.system" ps @?= Just (AttrText "rabbitmq")
      lookup "messaging.operation.type" ps @?= Just (AttrText "process")
  , testCase "records integer sizes as integer attributes" $ do
      let ps = pairs (messagingOperation "kafka" Send) {messagingBatchCount = Just 4}
      lookup "messaging.batch.message_count" ps @?= Just (AttrInt 4)
  ]
  where
    keys = map attributeKey . messagingAttributes
    pairs = map (\a -> (attributeKey a, attributeValue a)) . messagingAttributes

withMessagingSpanCases :: [TestTree]
withMessagingSpanCases =
  [ testCase "emits a producer-kind span named by the convention" $ do
      spans <-
        run $
          withMessagingSpan
            (messagingOperation "kafka" Send) {messagingDestination = Just "orders"}
            (pure ())
      case spans of
        [s] -> do
          spanName s @?= "send orders"
          spanKind s @?= Producer
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  , testCase "emits a consumer-kind span for a process operation" $ do
      spans <- run (withMessagingSpan (messagingOperation "kafka" Process) (pure ()))
      map spanKind spans @?= [Consumer]
  , testCase "annotates the span with the messaging.* attributes" $ do
      spans <-
        run $
          withMessagingSpan
            (messagingOperation "kafka" Send) {messagingDestination = Just "orders"}
            (pure ())
      case spans of
        [s] ->
          map attributeKey (spanAttributes s)
            @?= ["messaging.system", "messaging.operation.type", "messaging.destination.name"]
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  , testCase "nests under an enclosing span" $ do
      spans <- run (withSpan "outer" (withMessagingSpan (messagingOperation "kafka" Send) (pure ())))
      map spanName spans @?= ["send", "outer"]
  ]

propagationCases :: [TestTree]
propagationCases =
  [ testCase "inject emits a lowercase traceparent header for the active span" $ do
      headers <- runResult (withSpan "outbound" injectMessageHeaders)
      assertBool "a traceparent header is present" ("traceparent" `elem` map fst headers)
  , testCase "inject emits no headers when there is no active span" $ do
      headers <- runResult injectMessageHeaders
      headers @?= []
  , testCase "inject then extract round-trips to a remote context" $ do
      headers <- runResult (withSpan "outbound" injectMessageHeaders)
      assertBool "round-trips to a context" (isJust (extractMessageHeaders headers))
  , testCase "consumer span continues the remote trace from the message headers" $ do
      spans <-
        run (withConsumerSpan remoteHeaders (messagingOperation "kafka" Process) (pure ()))
      case spans of
        [s] -> traceIdToHex (spanContextTraceId (spanContext s)) @?= remoteTraceIdHex
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  , testCase "consumer span opens a fresh trace when headers carry no context" $ do
      spans <-
        run (withConsumerSpan [] (messagingOperation "kafka" Process) (pure ()))
      case spans of
        [s] ->
          assertBool
            "trace id is not the remote one"
            (traceIdToHex (spanContextTraceId (spanContext s)) /= remoteTraceIdHex)
        other -> fail ("expected exactly one captured span, got " <> show (length other))
  ]

-- | A canonical W3C @traceparent@ as a text message header, plus its trace id,
-- standing in for context a producer attached to a message.
remoteHeaders :: [(Text, Text)]
remoteHeaders =
  [("traceparent", "00-" <> remoteTraceIdHex <> "-00f067aa0ba902b7-01")]

remoteTraceIdHex :: Text
remoteTraceIdHex = "4bf92f3577b34da6a3ce929d0e0e4736"

-- | Run a 'Tracer' computation through the in-memory interpreter, returning the
-- captured spans (innermost first, as the interpreter records them on close).
run :: Eff '[Tracer, IOE] a -> IO [Span]
run action = runEff $ do
  captured <- newCapturedSpans
  _ <- runTracerInMemory captured action
  readCapturedSpans captured

-- | Run a 'Tracer' computation through the in-memory interpreter, discarding the
-- captured spans and returning the computation's result.
runResult :: Eff '[Tracer, IOE] a -> IO a
runResult action = runEff $ do
  captured <- newCapturedSpans
  runTracerInMemory captured action
