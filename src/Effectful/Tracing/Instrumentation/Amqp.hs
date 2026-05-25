{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Amqp
-- Description : Tracing wrappers for the amqp (RabbitMQ) client.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Drop-in replacements for the core @amqp@ publish and consume calls that run
-- each inside a span recording the stable OpenTelemetry messaging semantic
-- conventions (see "Effectful.Tracing.SemConv"). The wrappers live in @'Eff' es@
-- and delegate to "Effectful.Tracing.Instrumentation.Messaging", so the span is
-- named after the operation and destination and is finalized even if the call
-- throws.
--
-- The producer side ('publishMsgTraced') writes the active span's
-- <https://www.w3.org/TR/trace-context/ W3C Trace Context> into the message's
-- AMQP headers, and the consumer side ('withProcessSpan') reads it back, so a
-- trace continues across the broker without any manual header plumbing.
--
-- Import this module qualified alongside @Network.AMQP@:
--
-- > import Network.AMQP (Channel, Ack (Ack), newMsg, msgBody)
-- > import Effectful.Tracing.Instrumentation.Amqp qualified as Amqp
-- >
-- > -- producer: publish a message, attaching the trace context to its headers
-- > placeOrder :: (IOE :> es, Tracer :> es) => Channel -> Eff es ()
-- > placeOrder chan = do
-- >   _ <- Amqp.publishMsgTraced chan "orders" "orders.created" newMsg {msgBody = body}
-- >   pure ()
-- >
-- > -- consumer: poll for a message, then process it under the producer's trace
-- > handleOrder :: (IOE :> es, Tracer :> es) => Channel -> Eff es ()
-- > handleOrder chan = do
-- >   received <- Amqp.getMsgTraced chan Ack "orders"
-- >   case received of
-- >     Nothing -> pure ()
-- >     Just (msg, env) -> Amqp.withProcessSpan msg env (process (msgBody msg))
--
-- The @messaging.destination.name@ is the exchange the call targets, falling
-- back to the routing key for the default (empty) exchange, since that is the
-- queue name. RabbitMQ does not expose a portable message size before send, so
-- @messaging.message.body.size@ is taken from the body you hand it.
module Effectful.Tracing.Instrumentation.Amqp
  ( -- * Producing
    publishMsgTraced

    -- * Consuming
  , getMsgTraced
  , withProcessSpan

    -- * Reading headers
  , messageHeaders
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import GHC.Stack (HasCallStack)

import Network.AMQP
  ( Ack
  , Channel
  , Envelope (envExchangeName, envRoutingKey)
  , Message (msgBody, msgCorrelationID, msgHeaders, msgID)
  , getMsg
  , publishMsg
  )
import Network.AMQP.Types (FieldTable (FieldTable), FieldValue (FVString))

import Effectful (Eff, IOE, (:>))
import Effectful.Tracing (Tracer)
import Effectful.Tracing.Instrumentation.Messaging
  ( MessagingOperation
      ( messagingBodySize
      , messagingConversationId
      , messagingDestination
      , messagingMessageId
      )
  , MessagingOperationType (Process, Receive, Send)
  , injectMessageHeaders
  , messagingOperation
  , withConsumerSpan
  , withMessagingSpan
  )

-- | 'Network.AMQP.publishMsg' wrapped in a traced @producer@-kind span. The
-- active span's trace context is merged into the message's headers before it is
-- sent, so a consumer using 'withProcessSpan' continues this trace.
publishMsgTraced
  :: (HasCallStack, IOE :> es, Tracer :> es)
  => Channel
  -> Text
  -- ^ Exchange.
  -> Text
  -- ^ Routing key.
  -> Message
  -> Eff es (Maybe Int)
publishMsgTraced chan exchange routingKey msg =
  withMessagingSpan (describePublish exchange routingKey msg) $ do
    headers <- injectMessageHeaders
    liftIO (publishMsg chan exchange routingKey (setTraceHeaders headers msg))

-- | 'Network.AMQP.getMsg' wrapped in a traced @consumer@-kind span for the
-- @receive@ operation. This traces the act of fetching from the queue; to also
-- trace processing under the producer's trace, pass the result to
-- 'withProcessSpan'.
getMsgTraced
  :: (HasCallStack, IOE :> es, Tracer :> es)
  => Channel
  -> Ack
  -> Text
  -- ^ Queue.
  -> Eff es (Maybe (Message, Envelope))
getMsgTraced chan ack queue =
  withMessagingSpan (describeReceive queue) (liftIO (getMsg chan ack queue))

-- | Process a received message inside a traced @consumer@-kind span for the
-- @process@ operation. The message's trace-context headers are read with
-- 'messageHeaders', so the span continues the producer's trace when they are
-- present and opens a new local root otherwise. Use this around the body of a
-- 'Network.AMQP.consumeMsgs' callback or a 'getMsgTraced' result.
withProcessSpan
  :: (HasCallStack, Tracer :> es)
  => Message
  -> Envelope
  -> Eff es a
  -> Eff es a
withProcessSpan msg env =
  withConsumerSpan (messageHeaders msg) (describeProcess msg env)

-- | The text headers carried on a message, as @key\/value@ pairs. Only
-- string-valued AMQP headers are returned (trace-context headers are always
-- strings); other field types are dropped. This is the input
-- 'withProcessSpan' uses to continue the producer's trace.
messageHeaders :: Message -> [(Text, Text)]
messageHeaders msg =
  case msgHeaders msg of
    Nothing -> []
    Just (FieldTable table) -> mapMaybe textHeader (Map.toList table)
  where
    textHeader (name, FVString bytes) = Just (name, decodeUtf8Lenient bytes)
    textHeader _ = Nothing

-- | Merge trace-context headers into a message, overwriting any existing
-- entries with the same keys and preserving the rest.
setTraceHeaders :: [(Text, Text)] -> Message -> Message
setTraceHeaders [] msg = msg
setTraceHeaders headers msg =
  msg {msgHeaders = Just (FieldTable (foldr insertHeader existing headers))}
  where
    existing = case msgHeaders msg of
      Just (FieldTable table) -> table
      Nothing -> Map.empty
    insertHeader (name, value) = Map.insert name (FVString (encodeUtf8 value))

-- | Describe a publish: system @\"rabbitmq\"@, a @send@ operation, the
-- destination, and the message id, correlation id, and body size when present.
describePublish :: Text -> Text -> Message -> MessagingOperation
describePublish exchange routingKey msg =
  (messagingOperation "rabbitmq" Send)
    { messagingDestination = Just (publishDestination exchange routingKey)
    , messagingMessageId = msgID msg
    , messagingConversationId = msgCorrelationID msg
    , messagingBodySize = Just (bodySize msg)
    }

-- | Describe a poll: system @\"rabbitmq\"@, a @receive@ operation, and the queue
-- as the destination.
describeReceive :: Text -> MessagingOperation
describeReceive queue =
  (messagingOperation "rabbitmq" Receive) {messagingDestination = Just queue}

-- | Describe processing a delivered message: system @\"rabbitmq\"@, a @process@
-- operation, the destination from the delivery envelope, and the message id,
-- correlation id, and body size when present.
describeProcess :: Message -> Envelope -> MessagingOperation
describeProcess msg env =
  (messagingOperation "rabbitmq" Process)
    { messagingDestination = Just (envDestination env)
    , messagingMessageId = msgID msg
    , messagingConversationId = msgCorrelationID msg
    , messagingBodySize = Just (bodySize msg)
    }

-- | The destination name for a publish: the exchange, or the routing key when
-- the exchange is empty (the default exchange routes directly to the queue).
publishDestination :: Text -> Text -> Text
publishDestination exchange routingKey
  | T.null exchange = routingKey
  | otherwise = exchange

-- | The destination name from a delivery envelope, by the same rule as
-- 'publishDestination'.
envDestination :: Envelope -> Text
envDestination env
  | T.null (envExchangeName env) = envRoutingKey env
  | otherwise = envExchangeName env

-- | The message body size in bytes.
bodySize :: Message -> Int
bodySize = fromIntegral . BL.length . msgBody
