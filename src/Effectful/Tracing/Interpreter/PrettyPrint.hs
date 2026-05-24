{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Interpreter.PrettyPrint
-- Description : A development-time interpreter that prints traces as a tree.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- 'runTracerPretty' writes a human-readable, tree-shaped rendering of each
-- finished trace to a 'Handle' (typically 'System.IO.stderr'). It is meant for
-- local development and debugging, not production export.
--
-- > import Effectful (runEff)
-- > import Effectful.Tracing
-- > import Effectful.Tracing.Interpreter.PrettyPrint
-- > import System.IO (stderr)
-- >
-- > main :: IO ()
-- > main =
-- >   runEff . runTracerPretty (defaultPrettyPrintConfig stderr) $
-- >     withSpan "handle_request" $ do
-- >       addAttribute "user.id" ("u123" :: Text)
-- >       withSpan "load_user" (pure ())
--
-- produces something like:
--
-- > trace 4f1a9c.. (1ms)
-- > └─ handle_request (1ms) status=Unset
-- >    user.id=u123
-- >    └─ load_user (0ms) status=Unset
--
-- == Why a trace is buffered until its root closes
--
-- Spans complete out of order: a parent finishes after its children, so the
-- tree is not known until the root closes. The interpreter accumulates the
-- spans of each in-flight trace in a @'TVar' ('Map' 'TraceId' [Span])@ and
-- renders the whole tree the moment the root (a span with no parent) closes,
-- then drops that trace from the map. The lexical span model guarantees the
-- root closes last, so by then every descendant has been collected.
--
-- The lifecycle itself (lexical active span, finalize-exactly-once under
-- 'generalBracket') is shared with the in-memory interpreter and lives in
-- "Effectful.Tracing.Internal.Live"; this module supplies the
-- buffer-and-render sink and the pure 'renderTrace' formatter.
module Effectful.Tracing.Interpreter.PrettyPrint
  ( -- * Interpreter
    runTracerPretty

    -- * Configuration
  , PrettyPrintConfig (..)
  , defaultPrettyPrintConfig
  , TimeFormat (..)

    -- * Pure rendering
  , renderTrace
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Numeric (showFFloat)
import System.IO (Handle)

import Effectful (Eff, IOE, (:>))

import Effectful.Tracing.Attribute
  ( Attribute (Attribute)
  , AttributeValue (..)
  )
import Effectful.Tracing.Effect (Tracer)
import Effectful.Tracing.Internal.Clock (Timestamp (Timestamp))
import Effectful.Tracing.Internal.Ids (SpanId, TraceId, traceIdToHex)
import Effectful.Tracing.Internal.Live (interpretTracer)
import Effectful.Tracing.Internal.Types
  ( Event (eventName, eventTime)
  , Span (..)
  , SpanContext (spanContextSpanId, spanContextTraceId)
  , SpanKind (Internal)
  , SpanStatus (Error, Ok, Unset)
  )

-- | How a span's time is shown in the rendered tree.
data TimeFormat
  = -- | Wall-clock start time plus duration, e.g. @14:03:11.024 (78ms)@.
    Absolute
  | -- | Offset from the start of the trace plus duration, e.g. @+12ms (8ms)@.
    RelativeToTraceStart
  | -- | Duration only, e.g. @(78ms)@. The default.
    DurationOnly
  deriving (Eq, Show)

-- | How 'runTracerPretty' renders traces.
data PrettyPrintConfig = PrettyPrintConfig
  { handle :: !Handle
  -- ^ Where rendered traces are written. 'renderTrace' ignores this field.
  , useColor :: !Bool
  -- ^ Emit ANSI color escapes. There is no auto-detection here; a caller that
  -- wants \"color when attached to a terminal\" should set this from
  -- @'System.IO.hIsTerminalDevice' h@.
  , showAttributes :: !Bool
  -- ^ Print each span's attributes beneath it.
  , showEvents :: !Bool
  -- ^ Print each span's events beneath it.
  , timeFormat :: !TimeFormat
  -- ^ How span times are shown.
  }

-- | A reasonable default: no color, attributes and events shown, durations
-- only. Pass the 'Handle' to write to (e.g. 'System.IO.stderr').
defaultPrettyPrintConfig :: Handle -> PrettyPrintConfig
defaultPrettyPrintConfig h =
  PrettyPrintConfig
    { handle = h
    , useColor = False
    , showAttributes = True
    , showEvents = True
    , timeFormat = DurationOnly
    }

-- | Interpret 'Tracer' by rendering each finished trace to the configured
-- handle as a tree. Each trace is printed once, when its root span closes.
runTracerPretty
  :: IOE :> es
  => PrettyPrintConfig
  -> Eff (Tracer : es) a
  -> Eff es a
runTracerPretty config eff = do
  traces <- liftIO (newTVarIO Map.empty)
  interpretTracer (flushOnRoot config traces) eff

-- | Accumulate a completed span under its trace id; when the span is a root,
-- pop the whole trace and render it.
flushOnRoot :: PrettyPrintConfig -> TVar (Map TraceId [Span]) -> Span -> IO ()
flushOnRoot config traces completed = do
  let traceId = spanContextTraceId (spanContext completed)
  finished <- atomically $ do
    pending <- readTVar traces
    let gathered = completed : Map.findWithDefault [] traceId pending
    if isNothing (spanParentContext completed)
      then Just gathered <$ writeTVar traces (Map.delete traceId pending)
      else Nothing <$ writeTVar traces (Map.insert traceId gathered pending)
  case finished of
    Just spans -> T.hPutStr (handle config) (renderTrace config spans)
    Nothing -> pure ()

-- | Render the spans of a single trace as a tree, in the layout described by
-- the module documentation. The input may be in any order and is expected to
-- belong to one trace; siblings are ordered by start time. The 'handle' field
-- of the config is ignored. Pure, so it is the unit of golden testing.
renderTrace :: PrettyPrintConfig -> [Span] -> Text
renderTrace config spans = case spans of
  [] -> ""
  (representative : _) ->
    let traceId = spanContextTraceId (spanContext representative)
        traceStart = minimum (map spanStartTime spans)
        traceEnd = maximum (map spanEndTime spans)
        header =
          "trace "
            <> traceIdToHex traceId
            <> " ("
            <> formatDuration (durationBetween traceStart traceEnd)
            <> ")"
        roots = sortOn spanStartTime (filter isRoot spans)
     in T.unlines (header : renderForest config traceStart "" roots spans)
  where
    presentIds :: Set.Set SpanId
    presentIds = Set.fromList (map (spanContextSpanId . spanContext) spans)

    isRoot s = case spanParentContext s of
      Nothing -> True
      Just pc -> not (spanContextSpanId pc `Set.member` presentIds)

-- | Render a list of sibling spans, each with its subtree, under a shared
-- indentation prefix.
renderForest :: PrettyPrintConfig -> Timestamp -> Text -> [Span] -> [Span] -> [Text]
renderForest config traceStart prefix nodes allSpans =
  concat
    [ renderNode config traceStart prefix (index == lastIndex) node allSpans
    | (index, node) <- zip [0 :: Int ..] nodes
    ]
  where
    lastIndex = length nodes - 1

-- | Render one span: its label line, then its detail lines (attributes,
-- events), then its children.
renderNode :: PrettyPrintConfig -> Timestamp -> Text -> Bool -> Span -> [Span] -> [Text]
renderNode config traceStart prefix isLast node allSpans =
  nodeLine : (details <> childLines)
  where
    connector = if isLast then "\x2514\x2500 " else "\x251C\x2500 "
    childPrefix = prefix <> if isLast then "   " else "\x2502  "
    nodeLine = prefix <> connector <> label config traceStart node
    details = map (childPrefix <>) (attributeLines config node <> eventLines config node)
    children = sortOn spanStartTime (childrenOfSpan node allSpans)
    childLines = renderForest config traceStart childPrefix children allSpans

-- | The spans whose direct parent is the given span.
childrenOfSpan :: Span -> [Span] -> [Span]
childrenOfSpan node = filter isChild
  where
    nodeId = spanContextSpanId (spanContext node)
    isChild s = (spanContextSpanId <$> spanParentContext s) == Just nodeId

-- | The single-line summary of a span: name, kind, time, and status.
label :: PrettyPrintConfig -> Timestamp -> Span -> Text
label config traceStart s =
  colorName config (spanName s)
    <> kindPart (spanKind s)
    <> " ("
    <> timePart config traceStart s
    <> ") status="
    <> colorStatus config (spanStatus s)
  where
    kindPart Internal = ""
    kindPart k = " [" <> T.toLower (T.pack (show k)) <> "]"

-- | The time portion of a span label, per the configured 'TimeFormat'.
timePart :: PrettyPrintConfig -> Timestamp -> Span -> Text
timePart config traceStart s = case timeFormat config of
  DurationOnly -> formatDuration spanDuration
  RelativeToTraceStart ->
    "+" <> formatDuration (durationBetween traceStart (spanStartTime s)) <> " " <> formatDuration spanDuration
  Absolute ->
    formatAbsolute (spanStartTime s) <> " " <> formatDuration spanDuration
  where
    spanDuration = durationBetween (spanStartTime s) (spanEndTime s)

attributeLines :: PrettyPrintConfig -> Span -> [Text]
attributeLines config s
  | showAttributes config = map (colorAttribute config . renderAttribute) (spanAttributes s)
  | otherwise = []

eventLines :: PrettyPrintConfig -> Span -> [Text]
eventLines config s
  | showEvents config = map renderEvent (spanEvents s)
  | otherwise = []
  where
    renderEvent e =
      colorEvent config $
        "event: "
          <> eventName e
          <> " @ +"
          <> formatDuration (durationBetween (spanStartTime s) (eventTime e))

renderAttribute :: Attribute -> Text
renderAttribute (Attribute key value) = key <> "=" <> renderAttributeValue value

renderAttributeValue :: AttributeValue -> Text
renderAttributeValue = \case
  AttrText t -> t
  AttrBool b -> renderBool b
  AttrInt i -> T.pack (show i)
  AttrDouble d -> T.pack (show d)
  AttrTextArray v -> renderArray id (toList v)
  AttrBoolArray v -> renderArray renderBool (toList v)
  AttrIntArray v -> renderArray (T.pack . show) (toList v)
  AttrDoubleArray v -> renderArray (T.pack . show) (toList v)
  where
    renderBool b = if b then "true" else "false"
    renderArray render xs = "[" <> T.intercalate ", " (map render xs) <> "]"

-- Time formatting -----------------------------------------------------------

durationBetween :: Timestamp -> Timestamp -> NominalDiffTime
durationBetween (Timestamp from) (Timestamp to) = diffUTCTime to from

-- | Format a duration with a unit chosen for readability: seconds when at least
-- a second, milliseconds otherwise (with one decimal place for sub-millisecond
-- durations so short spans are not all rendered as @0ms@).
formatDuration :: NominalDiffTime -> Text
formatDuration d
  | millis >= 1000 = fixed 2 (millis / 1000) <> "s"
  | millis >= 1 = fixed 0 millis <> "ms"
  | otherwise = fixed 1 millis <> "ms"
  where
    millis = realToFrac d * 1000 :: Double
    fixed places n = T.pack (showFFloat (Just places) n "")

formatAbsolute :: Timestamp -> Text
formatAbsolute (Timestamp t) = T.pack (formatTime defaultTimeLocale "%H:%M:%S%3Q" (t :: UTCTime))

-- Color ---------------------------------------------------------------------

colorName :: PrettyPrintConfig -> Text -> Text
colorName config = withColor config "1" -- bold

colorStatus :: PrettyPrintConfig -> SpanStatus -> Text
colorStatus config status = withColor config (statusColor status) (statusText status)
  where
    statusColor Ok = "32" -- green
    statusColor (Error _) = "31" -- red
    statusColor Unset = "90" -- dim
    statusText Unset = "Unset"
    statusText Ok = "Ok"
    statusText (Error msg) = "Error: " <> msg

colorAttribute :: PrettyPrintConfig -> Text -> Text
colorAttribute config = withColor config "90" -- dim

colorEvent :: PrettyPrintConfig -> Text -> Text
colorEvent config = withColor config "36" -- cyan

-- | Wrap text in an ANSI SGR escape when color is enabled, otherwise return it
-- unchanged.
withColor :: PrettyPrintConfig -> Text -> Text -> Text
withColor config code t
  | useColor config = "\ESC[" <> code <> "m" <> t <> "\ESC[0m"
  | otherwise = t
