{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Effectful.Tracing.FuzzSpec
-- Description : Robustness / totality fuzzing for the wire-format parsers.
--
-- The propagation and id parsers all consume untrusted input from the network,
-- so the contract that matters is total: on any 'ByteString' or 'Text' they
-- must terminate and return a value (never loop, never throw). These properties
-- feed both uniformly random input and structurally-plausible-but-malformed
-- input (right shape, adversarial content) and assert the parser produces a
-- well-formed result.
--
-- Each property reduces the parser output to a 'Bool' through 'eval', which
-- forces evaluation and reports any bottom as a failure rather than letting it
-- escape. Because the library types are records of strict fields backed by
-- strict 'ByteString's, evaluating that 'Bool' walks the whole result, so
-- "didn't throw" is a real check rather than a WHNF formality.
module Effectful.Tracing.FuzzSpec
  ( tests
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

import Hedgehog (Gen, Property, assert, eval, forAll, property)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

import Effectful.Tracing.Internal.Ids
  ( SpanId (..)
  , TraceId (..)
  , isValidSpanId
  , isValidTraceId
  , spanIdFromHex
  , traceIdFromHex
  )
import Effectful.Tracing.Internal.Types
  ( SpanContext (..)
  , TraceFlags (..)
  , maxTraceStateEntries
  , traceStateEntries
  , traceStateFromHeader
  )
import Effectful.Tracing.Propagation
  ( extractContext
  , traceparentHeader
  , tracestateHeader
  )
import Effectful.Tracing.Propagation.B3
  ( b3FlagsHeader
  , b3Header
  , b3SampledHeader
  , b3SpanIdHeader
  , b3TraceIdHeader
  , extractContextB3
  )

tests :: TestTree
tests =
  testGroup
    "Parser robustness (fuzz)"
    [ testProperty "extractContext is total on arbitrary headers" prop_extractContextTotal
    , testProperty "extractContext is total on traceparent-shaped input" prop_extractContextShaped
    , testProperty "extractContextB3 is total on arbitrary headers" prop_extractB3Total
    , testProperty "extractContextB3 is total on b3-shaped input" prop_extractB3Shaped
    , testProperty "traceIdFromHex is total on arbitrary text" prop_traceIdFromHexTotal
    , testProperty "spanIdFromHex is total on arbitrary text" prop_spanIdFromHexTotal
    , testProperty "traceStateFromHeader is total and capped" prop_traceStateFromHeaderTotal
    ]

-- | Whatever 'extractContext' returns, it is either a clean rejection or a
-- context whose ids satisfy the validity invariant. 'eval' on the fully-forcing
-- predicate turns a loop into a timeout and a hidden bottom into a failure here.
prop_extractContextTotal :: Property
prop_extractContextTotal = property $ do
  tp <- forAll genFuzzBytes
  ts <- forAll genFuzzBytes
  ok <- eval (validContext (extractContext [(traceparentHeader, tp), (tracestateHeader, ts)]))
  assert ok

-- | The same totality check, but biased toward input that looks like a
-- @traceparent@ (hyphen-joined hex-ish fields), to actually exercise the parse
-- branches rather than bouncing off the first malformed byte.
prop_extractContextShaped :: Property
prop_extractContextShaped = property $ do
  tp <- forAll genTraceparentish
  ok <- eval (validContext (extractContext [(traceparentHeader, tp)]))
  assert ok

-- | 'extractContextB3' is likewise total: feeding random bytes to the single
-- @b3@ header and the multi-header fields together must yield a clean rejection
-- or a context whose ids satisfy the validity invariant.
prop_extractB3Total :: Property
prop_extractB3Total = property $ do
  single <- forAll genFuzzBytes
  tid <- forAll genFuzzBytes
  sid <- forAll genFuzzBytes
  samp <- forAll genFuzzBytes
  flags <- forAll genFuzzBytes
  ok <-
    eval
      ( validContext
          ( extractContextB3
              [ (b3Header, single)
              , (b3TraceIdHeader, tid)
              , (b3SpanIdHeader, sid)
              , (b3SampledHeader, samp)
              , (b3FlagsHeader, flags)
              ]
          )
      )
  assert ok

-- | The same totality check biased toward @b3@-shaped single-header input
-- (hyphen-joined hex-ish fields), so the field-count, id, and sampling branches
-- are exercised rather than bounced off the first malformed byte.
prop_extractB3Shaped :: Property
prop_extractB3Shaped = property $ do
  single <- forAll genB3ish
  ok <- eval (validContext (extractContextB3 [(b3Header, single)]))
  assert ok

-- | 'traceIdFromHex' returns 'Nothing' or a 16-byte id; nothing else, and never
-- a bottom.
prop_traceIdFromHexTotal :: Property
prop_traceIdFromHexTotal = property $ do
  t <- forAll genFuzzText
  ok <- eval (maybe True (\(TraceId bs) -> BS.length bs == 16) (traceIdFromHex t))
  assert ok

-- | 'spanIdFromHex' returns 'Nothing' or an 8-byte id.
prop_spanIdFromHexTotal :: Property
prop_spanIdFromHexTotal = property $ do
  t <- forAll genFuzzText
  ok <- eval (maybe True (\(SpanId bs) -> BS.length bs == 8) (spanIdFromHex t))
  assert ok

-- | 'traceStateFromHeader' never throws and never returns more than the W3C
-- entry cap, no matter how malformed the header.
prop_traceStateFromHeaderTotal :: Property
prop_traceStateFromHeaderTotal = property $ do
  t <- forAll genFuzzText
  n <- eval (length (traceStateEntries (traceStateFromHeader t)))
  assert (n <= maxTraceStateEntries)

-- | A context that survived extraction must carry valid (right-length,
-- non-zero) trace and span ids; rejection is also acceptable. The leading
-- 'seq's force the flags byte, the trace-state spine, and the remote flag so the
-- whole value is walked, while the returned conjunction is the real invariant.
validContext :: Maybe SpanContext -> Bool
validContext Nothing = True
validContext (Just ctx) =
  let TraceFlags w = spanContextTraceFlags ctx
      stateLen = length (traceStateEntries (spanContextTraceState ctx))
   in w `seq` stateLen `seq` spanContextIsRemote ctx `seq`
        (isValidTraceId (spanContextTraceId ctx) && isValidSpanId (spanContextSpanId ctx))

-- | Uniformly random bytes, including bytes that are not valid UTF-8, so the
-- @decodeUtf8'@ guard in 'extractContext' is exercised as well as the parser.
genFuzzBytes :: Gen ByteString
genFuzzBytes = Gen.bytes (Range.linear 0 80)

-- | Arbitrary text spanning the structural delimiters the parser cares about
-- and arbitrary Unicode.
genFuzzText :: Gen Text
genFuzzText =
  Gen.choice
    [ Gen.text (Range.linear 0 80) Gen.unicode
    , Gen.text (Range.linear 0 80) (Gen.element ("-=,; \t0123456789abcdefABCDEFxyz" :: String))
    ]

-- | A @b3@-shaped single-header value: 1 to 4 hyphen-joined fields, each a
-- hex-ish token (occasionally a known-good id or a real sampling token), so the
-- generator reaches the id and sampling branches of the B3 parser.
genB3ish :: Gen ByteString
genB3ish = do
  fields <- Gen.list (Range.linear 1 4) genField
  pure (encodeUtf8 (T.intercalate "-" fields))
  where
    genField =
      Gen.choice
        [ Gen.text (Range.linear 0 34) (Gen.element ("0123456789abcdef" :: String))
        , pure "4bf92f3577b34da6a3ce929d0e0e4736"
        , pure "a3ce929d0e0e4736"
        , pure "00f067aa0ba902b7"
        , Gen.element ["0", "1", "d", ""]
        ]

-- | A @traceparent@-shaped value: 1 to 6 hyphen-joined fields, each a hex-ish
-- token of varying length (occasionally a known-good id or version, occasionally
-- empty). This reaches the field-count, version, id, and flags branches of the
-- parser, where uniformly random bytes would almost always be rejected up front.
genTraceparentish :: Gen ByteString
genTraceparentish = do
  fields <- Gen.list (Range.linear 1 6) genField
  pure (encodeUtf8 (T.intercalate "-" fields))
  where
    genField =
      Gen.choice
        [ Gen.text (Range.linear 0 34) (Gen.element ("0123456789abcdef" :: String))
        , Gen.text (Range.linear 0 6) Gen.alphaNum
        , pure "4bf92f3577b34da6a3ce929d0e0e4736"
        , pure "00f067aa0ba902b7"
        , pure "00"
        , pure "ff"
        , pure ""
        ]
