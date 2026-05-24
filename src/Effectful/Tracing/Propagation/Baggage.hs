{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Propagation.Baggage
-- Description : W3C Baggage propagation across process boundaries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Carry ambient key-value context across a network hop using the
-- <https://www.w3.org/TR/baggage/ W3C Baggage> @baggage@ header. 'injectBaggage'
-- renders the in-scope baggage for an outbound request; 'extractBaggage' parses
-- an inbound header back into a 't:Baggage' value, which
-- 'Effectful.Tracing.Baggage.runBaggageWith' then makes ambient for the request.
--
-- > -- inbound: seed the ambient baggage from the request
-- > handle req = runBaggageWith (extractBaggage (requestHeaders req)) (serve req)
-- >
-- > -- outbound: forward the ambient baggage to the next hop
-- > call = do
-- >   headers <- injectBaggage
-- >   liftIO (httpGet url (baseHeaders <> headers))
--
-- The wire format is @key1=value1,key2=value2;prop=x@: comma-separated entries,
-- each an optionally percent-encoded value with optional @;@-separated metadata.
-- Values are percent-encoded on the way out and decoded on the way in; keys are
-- emitted verbatim. Parsing is resilient: a malformed entry is skipped rather
-- than failing the whole header, and the entry count is capped at
-- 'maxBaggageEntries'.
--
-- This is built directly against the 'Effectful.Tracing.Baggage.BaggageContext'
-- effect, with no dependency on an OpenTelemetry SDK.
module Effectful.Tracing.Propagation.Baggage
  ( -- * Wire format
    baggageHeader
  , maxBaggageEntries

    -- * Outbound
  , injectBaggage
  , renderBaggage

    -- * Inbound
  , extractBaggage
  , parseBaggage
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', decodeUtf8Lenient, encodeUtf8)
import Data.Word (Word8)
import Network.HTTP.Types.Header (HeaderName)

import Effectful (Eff, (:>))

import Effectful.Tracing.Baggage
  ( Baggage
  , BaggageContext
  , BaggageEntry (BaggageEntry)
  , baggageFromList
  , baggageToList
  , getBaggage
  )

-- | The @baggage@ header name (case-insensitive, per HTTP).
baggageHeader :: HeaderName
baggageHeader = "baggage"

-- | The maximum number of entries parsed from a single header, per the W3C
-- limit. Extra entries beyond this are dropped.
maxBaggageEntries :: Int
maxBaggageEntries = 180

-- | Serialize the in-scope baggage as a @baggage@ header for an outbound
-- request. Returns @[]@ when the baggage is empty, so it composes with a base
-- header list unconditionally.
injectBaggage :: BaggageContext :> es => Eff es [(HeaderName, ByteString)]
injectBaggage = do
  rendered <- renderBaggage <$> getBaggage
  pure [(baggageHeader, encodeUtf8 rendered) | not (T.null rendered)]

-- | Render baggage to a header value: @key=value@ entries (values
-- percent-encoded, metadata appended verbatim) joined with commas, ordered by
-- key. Empty baggage renders to the empty string.
renderBaggage :: Baggage -> Text
renderBaggage = T.intercalate "," . map renderMember . baggageToList
  where
    renderMember (key, BaggageEntry value metadata) =
      key <> "=" <> percentEncode value <> maybe "" (";" <>) metadata

-- | Parse the @baggage@ header from an inbound request into a 'Baggage' value.
-- An absent or undecodable header yields empty baggage.
extractBaggage :: [(HeaderName, ByteString)] -> Baggage
extractBaggage headers =
  case lookup baggageHeader headers of
    Nothing -> baggageFromList []
    Just raw -> either (const (baggageFromList [])) parseBaggage (decodeUtf8' raw)

-- | Parse a decoded @baggage@ header value. Total: malformed entries (no key,
-- an invalid key token) are skipped, surrounding whitespace is trimmed, values
-- are percent-decoded, and the result is capped at 'maxBaggageEntries'.
parseBaggage :: Text -> Baggage
parseBaggage =
  baggageFromList . take maxBaggageEntries . mapMaybe parseMember . T.splitOn ","

-- | Parse one @key=value;props@ member, or 'Nothing' if it is malformed.
parseMember :: Text -> Maybe (Text, BaggageEntry)
parseMember member =
  case T.splitOn ";" (T.strip member) of
    [] -> Nothing
    (keyValue : props) -> do
      let (rawKey, rest) = T.breakOn "=" keyValue
          key = T.strip rawKey
      _ <- T.stripPrefix "=" rest -- require a '=' to be present
      if not (isToken key)
        then Nothing
        else
          let value = percentDecode (T.strip (T.drop 1 rest))
              metadata = case map T.strip props of
                [] -> Nothing
                stripped -> Just (T.intercalate ";" stripped)
           in Just (key, BaggageEntry value metadata)

-- | Whether a key is a non-empty RFC 7230 token (the W3C key grammar).
isToken :: Text -> Bool
isToken key = not (T.null key) && T.all isTokenChar key

-- | An RFC 7230 @tchar@: an unreserved token character.
isTokenChar :: Char -> Bool
isTokenChar c =
  isAsciiLower c
    || isAsciiUpper c
    || isDigit c
    || c `elem` ("!#$%&'*+-.^_`|~" :: String)

-- | Percent-encode a value: keep RFC 3986 unreserved bytes, escape the rest as
-- @%XX@ (uppercase hex) over the UTF-8 encoding. Conservative (it escapes more
-- than the W3C grammar strictly requires), but always produces a valid value.
percentEncode :: Text -> Text
percentEncode = T.concat . map encodeByte . BS.unpack . encodeUtf8
  where
    encodeByte w
      | isUnreserved w = T.singleton (toEnum (fromIntegral w))
      | otherwise = T.pack ['%', hexDigit (w `shiftR` 4), hexDigit (w .&. 0x0F)]

-- | The uppercase hex digit for a nibble (0-15).
hexDigit :: Word8 -> Char
hexDigit n
  | n < 10 = toEnum (fromIntegral n + ord '0')
  | otherwise = toEnum (fromIntegral n - 10 + ord 'A')

-- | An RFC 3986 unreserved byte: @ALPHA@, @DIGIT@, or one of @-._~@.
isUnreserved :: Word8 -> Bool
isUnreserved w =
  (w >= 0x41 && w <= 0x5A) -- A-Z
    || (w >= 0x61 && w <= 0x7A) -- a-z
    || (w >= 0x30 && w <= 0x39) -- 0-9
    || w == 0x2D -- '-'
    || w == 0x2E -- '.'
    || w == 0x5F -- '_'
    || w == 0x7E -- '~'

-- | Percent-decode a value. Total: a @%@ not followed by two hex digits is kept
-- literally. Decodes over the UTF-8 bytes, so multi-byte values round-trip.
percentDecode :: Text -> Text
percentDecode = decodeUtf8Lenient . BS.pack . decodeBytes . BS.unpack . encodeUtf8
  where
    decodeBytes (w : a : b : rest)
      | w == 0x25 -- '%'
      , Just hi <- hexValue a
      , Just lo <- hexValue b =
          ((hi `shiftL` 4) .|. lo) : decodeBytes rest
    decodeBytes (w : rest) = w : decodeBytes rest
    decodeBytes [] = []

-- | The numeric value of an ASCII hex-digit byte, if it is one.
hexValue :: Word8 -> Maybe Word8
hexValue w
  | w >= 0x30 && w <= 0x39 = Just (w - 0x30) -- 0-9
  | w >= 0x41 && w <= 0x46 = Just (w - 0x41 + 10) -- A-F
  | w >= 0x61 && w <= 0x66 = Just (w - 0x61 + 10) -- a-f
  | otherwise = Nothing
