{-# LANGUAGE CPP #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : Effectful.Tracing.Internal.Ids
-- Description : Trace and span identifiers, generation, and hex codec.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : internal
--
-- Trace and span identifiers as defined by the OpenTelemetry / W3C
-- TraceContext specifications: a 'TraceId' is 16 bytes and a 'SpanId' is 8
-- bytes. Identifiers render as lowercase hex, matching the wire form.
--
-- This is an @.Internal.@ module: it exposes the raw newtype constructors and
-- carries no stability promise. Prefer the validated constructors
-- ('traceIdFromBytes', 'traceIdFromHex', and the generators) over the raw
-- constructors.
module Effectful.Tracing.Internal.Ids
  ( -- * Identifiers
    TraceId (..)
  , SpanId (..)

    -- * Generation
  , newTraceId
  , newSpanId

    -- * Validation
  , traceIdFromBytes
  , spanIdFromBytes
  , isValidTraceId
  , isValidSpanId

    -- * Hex codec
  , traceIdToHex
  , spanIdToHex
  , traceIdFromHex
  , spanIdFromHex
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit, ord)
import Data.Hashable (Hashable)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeLatin1)
import Data.Word (Word8)

#ifdef SECURE_IDS
import Crypto.Random (getRandomBytes)
#else
import System.Random.Stateful (globalStdGen, uniformByteStringM)
#endif

-- | The fixed length of a trace identifier, in bytes (16, per the spec).
traceIdByteLength :: Int
traceIdByteLength = 16

-- | The fixed length of a span identifier, in bytes (8, per the spec).
spanIdByteLength :: Int
spanIdByteLength = 8

-- | A 16-byte trace identifier. Renders as 32 lowercase hex characters.
newtype TraceId = TraceId ByteString
  deriving newtype (Eq, Ord, Hashable)

-- | An 8-byte span identifier. Renders as 16 lowercase hex characters.
newtype SpanId = SpanId ByteString
  deriving newtype (Eq, Ord, Hashable)

instance Show TraceId where
  show = T.unpack . traceIdToHex

instance Show SpanId where
  show = T.unpack . spanIdToHex

-- | Generate a fresh, valid (non-zero) trace identifier.
--
-- By default this uses a fast pseudo-random source (@random@'s global
-- @StdGen@, splitmix under the hood), not a CSPRNG. This is the conventional
-- SDK choice and keeps per-span cost low. Building with the @secure-ids@ cabal
-- flag swaps the byte source to @crypton@'s cryptographically secure system
-- entropy, leaving this function's name and type unchanged. The all-zero
-- identifier is the spec's "invalid" sentinel and is never returned in either
-- mode.
newTraceId :: (MonadIO m) => m TraceId
newTraceId = TraceId <$> randomNonZeroBytes traceIdByteLength

-- | Generate a fresh, valid (non-zero) span identifier. See 'newTraceId'.
newSpanId :: (MonadIO m) => m SpanId
newSpanId = SpanId <$> randomNonZeroBytes spanIdByteLength

-- | Draw @n@ random bytes, retrying on the astronomically unlikely all-zero
-- draw so the result is always a valid identifier.
randomNonZeroBytes :: (MonadIO m) => Int -> m ByteString
randomNonZeroBytes n = do
  bytes <- liftIO (drawBytes n)
  if BS.all (== 0) bytes
    then randomNonZeroBytes n
    else pure bytes

-- | Draw @n@ random bytes from the configured source. The @secure-ids@ cabal
-- flag selects between @crypton@'s cryptographically secure system entropy and
-- @random@'s fast splitmix-backed global generator (the default).
drawBytes :: Int -> IO ByteString
#ifdef SECURE_IDS
drawBytes = getRandomBytes
#else
drawBytes n = uniformByteStringM n globalStdGen
#endif

-- | A trace identifier is valid when it is the right length and not all zero.
isValidTraceId :: TraceId -> Bool
isValidTraceId (TraceId bs) = BS.length bs == traceIdByteLength && BS.any (/= 0) bs

-- | A span identifier is valid when it is the right length and not all zero.
isValidSpanId :: SpanId -> Bool
isValidSpanId (SpanId bs) = BS.length bs == spanIdByteLength && BS.any (/= 0) bs

-- | Build a 'TraceId' from raw bytes, checking only the length. Returns
-- 'Nothing' on the wrong length. (An all-zero but correctly-sized value is
-- accepted here; use 'isValidTraceId' to reject the invalid sentinel.)
traceIdFromBytes :: ByteString -> Maybe TraceId
traceIdFromBytes bs
  | BS.length bs == traceIdByteLength = Just (TraceId bs)
  | otherwise = Nothing

-- | Build a 'SpanId' from raw bytes, checking only the length. See
-- 'traceIdFromBytes'.
spanIdFromBytes :: ByteString -> Maybe SpanId
spanIdFromBytes bs
  | BS.length bs == spanIdByteLength = Just (SpanId bs)
  | otherwise = Nothing

-- | Render a 'TraceId' as 32 lowercase hex characters.
traceIdToHex :: TraceId -> Text
traceIdToHex (TraceId bs) = bytesToHex bs

-- | Render a 'SpanId' as 16 lowercase hex characters.
spanIdToHex :: SpanId -> Text
spanIdToHex (SpanId bs) = bytesToHex bs

-- | Parse a 'TraceId' from hex. Returns 'Nothing' unless the input is exactly
-- 32 hex characters.
traceIdFromHex :: Text -> Maybe TraceId
traceIdFromHex t = hexToBytes t >>= traceIdFromBytes

-- | Parse a 'SpanId' from hex. Returns 'Nothing' unless the input is exactly
-- 16 hex characters.
spanIdFromHex :: Text -> Maybe SpanId
spanIdFromHex t = hexToBytes t >>= spanIdFromBytes

-- | Render bytes as lowercase hex. @byteStringHex@ is the @bytestring@
-- library's builder-based encoder: it produces lowercase output (matching the
-- W3C wire form) and walks the input once, rather than building an
-- intermediate @String@ per byte. The result is ASCII, so decoding the bytes
-- back to 'Text' with 'decodeLatin1' is total and cannot fail.
bytesToHex :: ByteString -> Text
bytesToHex = decodeLatin1 . BSL.toStrict . toLazyByteString . byteStringHex

-- | Parse an even-length hex string into bytes. Total: returns 'Nothing' on an
-- odd length or any non-hex character.
hexToBytes :: Text -> Maybe ByteString
hexToBytes t
  | odd (T.length t) = Nothing
  | otherwise = BS.pack <$> traverse pairToByte (pairUp (T.unpack t))
  where
    pairUp :: [Char] -> [(Char, Char)]
    pairUp (a : b : rest) = (a, b) : pairUp rest
    pairUp _ = []

    pairToByte :: (Char, Char) -> Maybe Word8
    pairToByte (a, b) = do
      hi <- hexValue a
      lo <- hexValue b
      pure (fromIntegral (hi * 16 + lo))

hexValue :: Char -> Maybe Int
hexValue c
  | isDigit c = Just (ord c - ord '0')
  | c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
  | c >= 'A' && c <= 'F' = Just (ord c - ord 'A' + 10)
  | otherwise = Nothing
