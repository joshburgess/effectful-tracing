{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Messaging
-- Description : Framework-agnostic helpers for tracing message producers and consumers.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A small, dependency-free core for wrapping a publish or consume in a span that
-- records the stable OpenTelemetry messaging semantic conventions (see
-- "Effectful.Tracing.SemConv"). It knows nothing about any particular broker:
-- you describe the call with a 'MessagingOperation' and run the action inside
-- 'withMessagingSpan'. The operation type ('MessagingOperationType') selects the
-- span kind, so @send@ \/ @create@ become @producer@ spans and @receive@ \/
-- @process@ become @consumer@ spans, matching the OpenTelemetry model.
--
-- Distributed traces cross a broker by carrying the
-- <https://www.w3.org/TR/trace-context/ W3C Trace Context> in message headers:
-- the producer attaches the headers from 'injectMessageHeaders', and the
-- consumer hands the received headers to 'withConsumerSpan' (or extracts them
-- with 'extractMessageHeaders') so its span continues the producer's trace. The
-- headers are plain text key\/value pairs, the portable shape across Kafka,
-- RabbitMQ, SQS, and the like.
--
-- > -- producer: open a send span and attach the trace context to the message
-- > publishOrder :: (IOE :> es, Tracer :> es) => Order -> Eff es ()
-- > publishOrder order =
-- >   withMessagingSpan (messagingOperation "kafka" Send) { messagingDestination = Just "orders" } $ do
-- >     headers <- injectMessageHeaders
-- >     liftIO (produce "orders" headers (encode order))
-- >
-- > -- consumer: continue the producer's trace under a process span
-- > handleOrder :: (IOE :> es, Tracer :> es) => Message -> Eff es ()
-- > handleOrder msg =
-- >   withConsumerSpan
-- >     (messageHeaders msg)
-- >     (messagingOperation "kafka" Process) { messagingDestination = Just "orders" }
-- >     (liftIO (process (messageBody msg)))
--
-- The span is named following the convention @{operation} {destination}@ (for
-- example @\"send orders\"@), preferring 'messagingOperationName' then the
-- operation type for the leading word, and 'messagingDestinationTemplate' then
-- 'messagingDestination' for the trailing word, so the name stays low
-- cardinality.
module Effectful.Tracing.Instrumentation.Messaging
  ( -- * Describing an operation
    MessagingOperation (..)
  , MessagingOperationType (..)
  , messagingOperation

    -- * Tracing an operation
  , withMessagingSpan
  , withConsumerSpan

    -- * Propagating context through message headers
  , injectMessageHeaders
  , extractMessageHeaders

    -- * Helpers
  , messagingSpanName
  , messagingSpanKind
  , messagingAttributes
  , operationTypeText
  ) where

import Control.Applicative ((<|>))
import Data.CaseInsensitive qualified as CI
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import GHC.Stack (HasCallStack)

import Effectful (Eff, (:>))

import Effectful.Tracing
  ( SpanArguments (attributes, kind)
  , SpanContext
  , SpanKind (Client, Consumer, Producer)
  , Tracer
  , defaultSpanArguments
  , extractContext
  , injectContext
  , withRemoteParent
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute)
import Effectful.Tracing.SemConv qualified as SemConv

-- | The kind of messaging operation, following the OpenTelemetry
-- @messaging.operation.type@ values. The constructor both fills that attribute
-- (see 'operationTypeText') and selects the span kind (see 'messagingSpanKind').
data MessagingOperationType
  = -- | A message is created but not yet sent (a @producer@ span).
    Create
  | -- | One or more messages are handed to the broker (a @producer@ span). This
    -- covers what some systems call \"publish\".
    Send
  | -- | One or more messages are requested from the broker (a @consumer@ span).
    Receive
  | -- | One or more received messages are processed (a @consumer@ span).
    Process
  | -- | One or more messages are settled, for example acknowledged or rejected
    -- (a @client@ span).
    Settle
  deriving (Eq, Show)

-- | A broker-agnostic description of a messaging call, used to populate the
-- @messaging.*@ attributes (see "Effectful.Tracing.SemConv") and the span name.
-- Build it with 'messagingOperation' and fill in the fields you know; every
-- optional field left as 'Nothing' is simply not recorded.
data MessagingOperation = MessagingOperation
  { messagingSystem :: !Text
  -- ^ @messaging.system@: the messaging system, for example @\"kafka\"@.
  -- Required.
  , messagingOperationType :: !MessagingOperationType
  -- ^ @messaging.operation.type@: the operation category, which also selects the
  -- span kind. Required.
  , messagingOperationName :: !(Maybe Text)
  -- ^ @messaging.operation.name@: the system-specific operation name, for
  -- example @\"publish\"@ or @\"ack\"@. Used as the leading word of the span
  -- name; falls back to the operation type when unset.
  , messagingDestination :: !(Maybe Text)
  -- ^ @messaging.destination.name@: the destination the call acts on, for
  -- example a topic or queue name.
  , messagingDestinationTemplate :: !(Maybe Text)
  -- ^ @messaging.destination.template@: a low-cardinality template the
  -- destination is derived from. Preferred over 'messagingDestination' in the
  -- span name when destinations are dynamic.
  , messagingMessageId :: !(Maybe Text)
  -- ^ @messaging.message.id@: the broker-assigned identifier of a single
  -- message.
  , messagingConversationId :: !(Maybe Text)
  -- ^ @messaging.message.conversation_id@: the conversation \/ correlation
  -- identifier tying related messages together.
  , messagingBodySize :: !(Maybe Int)
  -- ^ @messaging.message.body.size@: the size of the message body in bytes.
  , messagingBatchCount :: !(Maybe Int)
  -- ^ @messaging.batch.message_count@: the number of messages in a batch
  -- operation.
  }
  deriving (Eq, Show)

-- | A 't:MessagingOperation' for the given @messaging.system@ and operation
-- type with every optional field unset, ready for record-update syntax to fill
-- in what you know.
--
-- > (messagingOperation "rabbitmq" Send) { messagingDestination = Just "orders" }
messagingOperation :: Text -> MessagingOperationType -> MessagingOperation
messagingOperation system operationType =
  MessagingOperation
    { messagingSystem = system
    , messagingOperationType = operationType
    , messagingOperationName = Nothing
    , messagingDestination = Nothing
    , messagingDestinationTemplate = Nothing
    , messagingMessageId = Nothing
    , messagingConversationId = Nothing
    , messagingBodySize = Nothing
    , messagingBatchCount = Nothing
    }

-- | Run a messaging action inside a span named by 'messagingSpanName', of the
-- kind 'messagingSpanKind' picks for the operation type, and annotated with
-- 'messagingAttributes'. The span is finalized (with its end time, and
-- 'Effectful.Tracing.Error' status if the action throws) by the shared span
-- lifecycle when the action returns or unwinds.
--
-- This opens a fresh span as a child of the current one. On the consumer side,
-- use 'withConsumerSpan' instead to continue the producer's remote trace.
withMessagingSpan
  :: (HasCallStack, Tracer :> es)
  => MessagingOperation
  -> Eff es a
  -> Eff es a
withMessagingSpan op =
  withSpan'
    (messagingSpanName op)
    defaultSpanArguments
      { kind = messagingSpanKind (messagingOperationType op)
      , attributes = messagingAttributes op
      }

-- | Run a consumer action inside a 'withMessagingSpan' that continues the
-- producer's trace. The given message headers are parsed with
-- 'extractMessageHeaders'; when they carry a valid context the span becomes a
-- child of that remote parent (via 'Effectful.Tracing.withRemoteParent'),
-- otherwise it opens a new local root. Pass a @receive@ or @process@ operation.
withConsumerSpan
  :: (HasCallStack, Tracer :> es)
  => [(Text, Text)]
  -- ^ Headers from the received message.
  -> MessagingOperation
  -> Eff es a
  -> Eff es a
withConsumerSpan headers op action =
  case extractMessageHeaders headers of
    Just parent -> withRemoteParent parent (withMessagingSpan op action)
    Nothing -> withMessagingSpan op action

-- | Serialize the active span's context as message headers for an outbound
-- message, as plain text @traceparent@ (and @tracestate@, if non-empty)
-- key\/value pairs. Attach these to the message you publish so the consumer can
-- continue the trace. Returns @[]@ when there is no active span, so it composes
-- with a base header list unconditionally.
injectMessageHeaders :: (Tracer :> es) => Eff es [(Text, Text)]
injectMessageHeaders = map toTextHeader <$> injectContext
  where
    toTextHeader (name, value) =
      (decodeUtf8Lenient (CI.original name), decodeUtf8Lenient value)

-- | Parse the trace context out of a received message's headers into a remote
-- 't:SpanContext', the consumer-side counterpart of 'injectMessageHeaders'.
-- Returns 'Nothing' when no valid @traceparent@ is present. Pair with
-- 'Effectful.Tracing.withRemoteParent', or use 'withConsumerSpan', which does
-- both. Header lookup is case-insensitive.
extractMessageHeaders :: [(Text, Text)] -> Maybe SpanContext
extractMessageHeaders = extractContext . map fromTextHeader
  where
    fromTextHeader (name, value) = (CI.mk (encodeUtf8 name), encodeUtf8 value)

-- | The span name for a messaging operation, following the OpenTelemetry
-- convention: @{operation} {destination}@ (for example @\"send orders\"@). The
-- leading word prefers 'messagingOperationName', falling back to the operation
-- type; the trailing word prefers 'messagingDestinationTemplate', then
-- 'messagingDestination', and is omitted when neither is set. This keeps the
-- name low cardinality.
messagingSpanName :: MessagingOperation -> Text
messagingSpanName op =
  case messagingDestinationTemplate op <|> messagingDestination op of
    Just destination -> label <> " " <> destination
    Nothing -> label
  where
    label = fromMaybe (operationTypeText (messagingOperationType op)) (messagingOperationName op)

-- | The span kind for an operation type: @producer@ for 'Create' and 'Send',
-- @consumer@ for 'Receive' and 'Process', and @client@ for 'Settle'.
messagingSpanKind :: MessagingOperationType -> SpanKind
messagingSpanKind = \case
  Create -> Producer
  Send -> Producer
  Receive -> Consumer
  Process -> Consumer
  Settle -> Client

-- | The @messaging.operation.type@ value for an operation type: the lowercase
-- name, for example @\"send\"@ for 'Send'.
operationTypeText :: MessagingOperationType -> Text
operationTypeText = \case
  Create -> "create"
  Send -> "send"
  Receive -> "receive"
  Process -> "process"
  Settle -> "settle"

-- | The @messaging.*@ attributes for an operation: @messaging.system@ and
-- @messaging.operation.type@ always, plus @messaging.operation.name@,
-- @messaging.destination.name@, @messaging.destination.template@,
-- @messaging.message.id@, @messaging.message.conversation_id@,
-- @messaging.message.body.size@, and @messaging.batch.message_count@ for
-- whichever optional fields are set.
messagingAttributes :: MessagingOperation -> [Attribute]
messagingAttributes op =
  [ SemConv.messagingSystem .= messagingSystem op
  , SemConv.messagingOperationType .= operationTypeText (messagingOperationType op)
  ]
    <> mapMaybe
      optionalText
      [ (SemConv.messagingOperationName, messagingOperationName op)
      , (SemConv.messagingDestinationName, messagingDestination op)
      , (SemConv.messagingDestinationTemplate, messagingDestinationTemplate op)
      , (SemConv.messagingMessageId, messagingMessageId op)
      , (SemConv.messagingMessageConversationId, messagingConversationId op)
      ]
    <> mapMaybe
      optionalInt
      [ (SemConv.messagingMessageBodySize, messagingBodySize op)
      , (SemConv.messagingBatchMessageCount, messagingBatchCount op)
      ]
  where
    optionalText (key, value) = (key .=) <$> value
    optionalInt (key, value) = (key .=) <$> value
