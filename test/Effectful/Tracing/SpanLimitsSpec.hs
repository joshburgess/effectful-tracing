{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.SpanLimitsSpec
-- Description : Tests for the per-span attribute, event, and link caps.
--
-- Two layers are exercised. The pure 'applySpanLimits' is tested directly on a
-- captured span (captured under 'unlimitedSpanLimits', then re-capped purely),
-- which is the policy unit: count caps keep the earliest entries, the
-- value-length cap truncates strings and string-array elements and leaves other
-- values alone, a 'Nothing' cap keeps everything, and a negative cap keeps
-- nothing. The interpreter integration then confirms the same caps are enforced
-- as a span records: emitting past the count limit drops the overflow, and a
-- value-length limit truncates on the way out.
module Effectful.Tracing.SpanLimitsSpec
  ( tests
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

import Effectful (Eff, IOE, runEff, (:>))

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Effectful.Tracing
  ( SpanArguments (attributes)
  , Tracer
  , addAttribute
  , addAttributes
  , addEvent
  , alwaysOn
  , defaultSpanArguments
  , withSpan
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute (Attribute), AttributeValue (AttrInt, AttrText, AttrTextArray))
import Effectful.Tracing.Interpreter.InMemory
  ( newCapturedSpans
  , readCapturedSpans
  , runTracerInMemoryWithLimits
  )
import Effectful.Tracing.Internal.Types
  ( Event (eventAttributes)
  , Link (Link)
  , Span (spanAttributes, spanContext, spanEvents, spanLinks)
  )
import Effectful.Tracing.SpanLimits
  ( SpanLimits
      ( attributeCountLimit
      , attributeValueLengthLimit
      , eventCountLimit
      , linkCountLimit
      )
  , applySpanLimits
  , defaultSpanLimits
  , unlimitedSpanLimits
  )

tests :: TestTree
tests =
  testGroup
    "SpanLimits"
    [ testGroup "presets" presetTests
    , testGroup "applySpanLimits" applyTests
    , testGroup "interpreter integration" interpreterTests
    ]

presetTests :: [TestTree]
presetTests =
  [ testCase "defaultSpanLimits matches the OpenTelemetry defaults" $ do
      attributeCountLimit defaultSpanLimits @?= Just 128
      attributeValueLengthLimit defaultSpanLimits @?= Nothing
      eventCountLimit defaultSpanLimits @?= Just 128
      linkCountLimit defaultSpanLimits @?= Just 128
  , testCase "unlimitedSpanLimits disables every cap" $ do
      attributeCountLimit unlimitedSpanLimits @?= Nothing
      attributeValueLengthLimit unlimitedSpanLimits @?= Nothing
      eventCountLimit unlimitedSpanLimits @?= Nothing
      linkCountLimit unlimitedSpanLimits @?= Nothing
  ]

applyTests :: [TestTree]
applyTests =
  [ testCase "caps the attribute count, keeping the earliest" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttributes numbered))
      let capped = applySpanLimits (onlyAttributeCount (Just 2)) s
      map attrKey (spanAttributes capped) @?= ["k0", "k1"]
  , testCase "a Nothing attribute cap keeps everything" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttributes numbered))
      length (spanAttributes (applySpanLimits (onlyAttributeCount Nothing) s)) @?= 5
  , testCase "a negative attribute cap keeps nothing" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttributes numbered))
      spanAttributes (applySpanLimits (onlyAttributeCount (Just (-1))) s) @?= []
  , testCase "truncates a long AttrText value" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttribute "k" ("abcdef" :: Text)))
      let capped = applySpanLimits (onlyValueLength (Just 3)) s
      lookupValue "k" capped @?= Just (AttrText "abc")
  , testCase "truncates each element of an AttrTextArray value" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttribute "k" (["abcd", "ef", "ghijk"] :: [Text])))
      let capped = applySpanLimits (onlyValueLength (Just 2)) s
      lookupValue "k" capped @?= Just (AttrTextArray (V.fromList ["ab", "ef", "gh"]))
  , testCase "leaves non-string values untouched" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addAttribute "k" (123456 :: Int)))
      lookupValue "k" (applySpanLimits (onlyValueLength (Just 2)) s) @?= Just (AttrInt 123456)
  , testCase "caps the event count, keeping the earliest" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (mapM_ event ["e0", "e1", "e2", "e3"]))
      length (spanEvents (applySpanLimits (onlyEventCount (Just 2)) s)) @?= 2
  , testCase "truncates string values inside an event's attributes" $ do
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (addEvent "e" ["k" .= ("abcdef" :: Text)]))
      case spanEvents (applySpanLimits (onlyValueLength (Just 3)) s) of
        [e] -> map attrValue (eventAttributes e) @?= [AttrText "abc"]
        other -> assertFailure ("expected one event, got " <> show (length other))
  , testCase "caps the link count, keeping the earliest" $ do
      -- The interpreter does not synthesize links here, so seed the captured
      -- span with several (reusing its own context), then cap purely.
      s <- oneSpan unlimitedSpanLimits (withSpan "s" (pure ()))
      let withLinks = s {spanLinks = replicate 5 (Link (spanContext s) [])}
      length (spanLinks (applySpanLimits (onlyLinkCount (Just 2)) withLinks)) @?= 2
  ]

interpreterTests :: [TestTree]
interpreterTests =
  [ testCase "emitting past the attribute cap drops the overflow" $ do
      s <- oneSpan (onlyAttributeCount (Just 2)) (withSpan "s" (addAttributes numbered))
      map attrKey (spanAttributes s) @?= ["k0", "k1"]
  , testCase "the cap counts the initial span-argument attributes" $ do
      -- Three seeded via span arguments, capped at two: the initial set is
      -- bounded at open, keeping the earliest.
      s <-
        oneSpan
          (onlyAttributeCount (Just 2))
          (withSpan' "s" defaultSpanArguments {attributes = take 3 numbered} (pure ()))
      map attrKey (spanAttributes s) @?= ["k0", "k1"]
  , testCase "emitting past the event cap drops the overflow" $ do
      s <- oneSpan (onlyEventCount (Just 2)) (withSpan "s" (mapM_ event ["e0", "e1", "e2", "e3"]))
      length (spanEvents s) @?= 2
  , testCase "a value-length cap truncates on the way out" $ do
      s <- oneSpan (onlyValueLength (Just 4)) (withSpan "s" (addAttribute "k" ("abcdefgh" :: Text)))
      lookupValue "k" s @?= Just (AttrText "abcd")
  ]

-- | Five numbered attributes, @k0@ through @k4@, in order.
numbered :: [Attribute]
numbered = [T.pack ("k" <> show n) .= (n :: Int) | n <- [0 .. 4 :: Int]]

-- | Emit a no-attribute event with the given name.
event :: (Tracer :> es) => Text -> Eff es ()
event name = addEvent name []

attrKey :: Attribute -> Text
attrKey (Attribute k _) = k

attrValue :: Attribute -> AttributeValue
attrValue (Attribute _ v) = v

lookupValue :: Text -> Span -> Maybe AttributeValue
lookupValue key s = lookup key [(k, v) | Attribute k v <- spanAttributes s]

-- | Caps for one dimension at a time, everything else unlimited.
onlyAttributeCount :: Maybe Int -> SpanLimits
onlyAttributeCount n = unlimitedSpanLimits {attributeCountLimit = n}

onlyValueLength :: Maybe Int -> SpanLimits
onlyValueLength n = unlimitedSpanLimits {attributeValueLengthLimit = n}

onlyEventCount :: Maybe Int -> SpanLimits
onlyEventCount n = unlimitedSpanLimits {eventCountLimit = n}

onlyLinkCount :: Maybe Int -> SpanLimits
onlyLinkCount n = unlimitedSpanLimits {linkCountLimit = n}

-- | Run a single-root computation under the given limits and return the one
-- captured span, failing the test if a different number was captured.
oneSpan :: SpanLimits -> Eff '[Tracer, IOE] a -> IO Span
oneSpan limits action = do
  spans <- runEff $ do
    buffer <- newCapturedSpans
    _ <- runTracerInMemoryWithLimits limits alwaysOn buffer action
    readCapturedSpans buffer
  case spans of
    [s] -> pure s
    other -> assertFailure ("expected one captured span, got " <> show (length other))
