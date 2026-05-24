{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.PrettyPrintSpec
-- Description : Golden and behavioural tests for the pretty-print interpreter.
--
-- The pure renderer ('renderTrace') is pinned with golden files built from
-- fixed spans, so the layout is locked without depending on real clocks or
-- random ids. A separate end-to-end test runs a real program through
-- 'runTracerPretty' and checks the structural properties that survive
-- nondeterministic timing and id generation.
module Effectful.Tracing.PrettyPrintSpec
  ( tests
  ) where

import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), addUTCTime, secondsToDiffTime)

import System.IO (hClose, stderr)
import System.IO.Temp (withSystemTempFile)

import Effectful (Eff, IOE, runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Effectful.Tracing (Tracer, addAttribute, withSpan)
import Effectful.Tracing.Attribute (Attribute, (.=))
import Effectful.Tracing.Internal.Clock (Timestamp (Timestamp))
import Effectful.Tracing.Internal.Ids (SpanId, TraceId, spanIdFromHex, traceIdFromHex)
import Effectful.Tracing.Internal.Types
  ( Event (Event)
  , Span (..)
  , SpanContext (..)
  , SpanKind (Client, Internal, Server)
  , SpanStatus (Error, Ok)
  , defaultTraceFlags
  , emptyTraceState
  )
import Effectful.Tracing.Interpreter.PrettyPrint
  ( PrettyPrintConfig (showAttributes, showEvents, timeFormat, useColor)
  , TimeFormat (RelativeToTraceStart)
  , defaultPrettyPrintConfig
  , renderTrace
  , runTracerPretty
  )

tests :: TestTree
tests =
  testGroup
    "Pretty-print interpreter"
    [ testGroup
        "renderTrace golden"
        [ golden "nested" "nested" (renderTrace plainConfig exampleTrace)
        , golden "colored" "colored" (renderTrace plainConfig {useColor = True} exampleTrace)
        , golden
            "relative-no-details"
            "relative-no-details"
            ( renderTrace
                plainConfig {timeFormat = RelativeToTraceStart, showAttributes = False, showEvents = False}
                exampleTrace
            )
        , golden "error" "error" (renderTrace plainConfig errorTrace)
        ]
    , testGroup
        "renderTrace structure"
        [ testCase "an empty trace renders nothing" $
            renderTrace plainConfig [] @?= ""
        , testCase "siblings are ordered by start time, not list order" $ do
            -- feed the spans in reverse; rendering must reorder by start time
            let rendered = renderTrace plainConfig {showAttributes = False, showEvents = False} (reverse exampleTrace)
            spanLineNames rendered @?= ["handle_request", "authenticate", "load_user", "db.query", "render"]
        ]
    , testCase "runTracerPretty writes one trace header with every span name" $ do
        rendered <- renderViaInterpreter
        let headers = filter ("trace " `T.isPrefixOf`) (T.lines rendered)
        length headers @?= 1
        mapM_
          (\name -> assertBool (T.unpack name <> " appears in output") (name `T.isInfixOf` rendered))
          ["root", "first-child", "grandchild", "second-child"]
    ]

-- Config --------------------------------------------------------------------

-- | A config for the pure renderer. The handle is never touched by
-- 'renderTrace'; 'stderr' just fills the field.
plainConfig :: PrettyPrintConfig
plainConfig = defaultPrettyPrintConfig stderr

-- Fixtures ------------------------------------------------------------------

-- | The trace from the build-plan example: a server span with an attribute and
-- three children, one of which has a client child carrying an attribute and an
-- event. All statuses are @Ok@.
exampleTrace :: [Span]
exampleTrace =
  [ mkSpan s1 Nothing "handle_request" Server 0 78 ["user.id" .= ("u123" :: Text)] [] Ok
  , mkSpan s2 (Just s1) "authenticate" Internal 2 14 [] [] Ok
  , mkSpan s3 (Just s1) "load_user" Internal 16 24 [] [] Ok
  , mkSpan
      s4
      (Just s3)
      "db.query"
      Client
      17
      23
      ["db.system" .= ("postgresql" :: Text)]
      [Event "query.started" (millis 17.1) []]
      Ok
  , mkSpan s5 (Just s1) "render" Internal 24 78 [] [] Ok
  ]

-- | A single span that failed: @Error@ status and an exception event.
errorTrace :: [Span]
errorTrace =
  [ mkSpan
      s1
      Nothing
      "checkout"
      Server
      0
      40
      ["cart.size" .= (3 :: Int)]
      [Event "exception" (millis 39) []]
      (Error "payment declined")
  ]

mkSpan
  :: SpanId
  -> Maybe SpanId
  -> Text
  -> SpanKind
  -> Double
  -> Double
  -> [Attribute]
  -> [Event]
  -> SpanStatus
  -> Span
mkSpan spanId parent name kind startMs endMs attrs events status =
  Span
    { spanContext = context spanId
    , spanParentContext = context <$> parent
    , spanName = name
    , spanKind = kind
    , spanStartTime = millis startMs
    , spanEndTime = millis endMs
    , spanAttributes = attrs
    , spanEvents = events
    , spanLinks = []
    , spanStatus = status
    }

context :: SpanId -> SpanContext
context spanId =
  SpanContext
    { spanContextTraceId = traceId
    , spanContextSpanId = spanId
    , spanContextTraceFlags = defaultTraceFlags
    , spanContextTraceState = emptyTraceState
    , spanContextIsRemote = False
    }

traceId :: TraceId
traceId = unsafeFromHex traceIdFromHex "4f1a9c000000000000000000000000aa"

s1, s2, s3, s4, s5 :: SpanId
s1 = unsafeFromHex spanIdFromHex "0000000000000001"
s2 = unsafeFromHex spanIdFromHex "0000000000000002"
s3 = unsafeFromHex spanIdFromHex "0000000000000003"
s4 = unsafeFromHex spanIdFromHex "0000000000000004"
s5 = unsafeFromHex spanIdFromHex "0000000000000005"

unsafeFromHex :: (Text -> Maybe a) -> Text -> a
unsafeFromHex parse hex = fromMaybe (error ("bad fixture id: " <> T.unpack hex)) (parse hex)

-- | A timestamp the given number of milliseconds after a fixed epoch.
millis :: Double -> Timestamp
millis ms = Timestamp (addUTCTime (realToFrac (ms / 1000)) epoch)
  where
    epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

-- Golden helper -------------------------------------------------------------

golden :: String -> FilePath -> Text -> TestTree
golden name file rendered =
  goldenVsString name ("test/golden/" <> file <> ".txt") (pure (BL.fromStrict (TE.encodeUtf8 rendered)))

-- | The span name from each label line (a line containing a tree connector),
-- stripped of the tree-drawing prefix and everything from the first space on.
spanLineNames :: Text -> [Text]
spanLineNames =
  map (T.takeWhile (/= ' ') . T.dropWhile (`elem` treeChars))
    . filter (T.any (`elem` connectors))
    . T.lines
  where
    treeChars = " \x2502\x251C\x2514\x2500" :: String
    connectors = "\x251C\x2514" :: String

-- End-to-end ----------------------------------------------------------------

tracedProgram :: Eff '[Tracer, IOE] ()
tracedProgram = withSpan "root" $ do
  addAttribute "k" ("v" :: Text)
  withSpan "first-child" (withSpan "grandchild" (pure ()))
  withSpan "second-child" (pure ())

renderViaInterpreter :: IO Text
renderViaInterpreter =
  withSystemTempFile "pretty-trace.txt" $ \path h -> do
    runEff (runTracerPretty (defaultPrettyPrintConfig h) tracedProgram)
    hClose h
    TE.decodeUtf8 . BL.toStrict <$> BL.readFile path
