{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Database
-- Description : Framework-agnostic helpers for tracing database client calls.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- A small, dependency-free core for wrapping a database call in a @client@-kind
-- span that records the stable OpenTelemetry database semantic conventions (see
-- "Effectful.Tracing.SemConv"). It knows nothing about any particular driver:
-- you describe the call with a 'DatabaseQuery' and run the action inside
-- 'withQuerySpan'. The driver-specific module
-- "Effectful.Tracing.Instrumentation.PostgresqlSimple" (built with the
-- @postgresql-simple@ flag) is a thin layer on top of this.
--
-- > runUsers :: (IOE :> es, Tracer :> es) => Connection -> Eff es [User]
-- > runUsers conn =
-- >   withQuerySpan
-- >     (databaseQuery "postgresql")
-- >       { queryText = Just "SELECT id, name FROM users WHERE active = $1"
-- >       , queryOperation = Just "SELECT"
-- >       , queryCollection = Just "users"
-- >       }
-- >     (liftIO (query conn "SELECT id, name FROM users WHERE active = ?" (Only True)))
--
-- The span is named following the convention @{operation} {collection}@ (for
-- example @\"SELECT users\"@), falling back to the operation alone, then to the
-- system name, so the name stays low cardinality. Record the /parameterized/
-- statement in 'queryText' (placeholders, not interpolated values) to avoid
-- leaking row data; 'inferOperationName' can pull the leading command keyword
-- out of such a statement when the driver does not give you one directly.
module Effectful.Tracing.Instrumentation.Database
  ( -- * Describing a query
    DatabaseQuery (..)
  , databaseQuery

    -- * Tracing a query
  , withQuerySpan

    -- * Helpers
  , inferOperationName
  , querySpanName
  , queryAttributes
  ) where

import Data.Char (isSpace)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Stack (HasCallStack)

import Effectful (Eff, (:>))

import Effectful.Tracing
  ( SpanArguments (attributes, kind)
  , SpanKind (Client)
  , Tracer
  , defaultSpanArguments
  , withSpan'
  , (.=)
  )
import Effectful.Tracing.Attribute (Attribute)
import Effectful.Tracing.SemConv qualified as SemConv

-- | A driver-agnostic description of a database call, used to populate the
-- @db.*@ attributes (see "Effectful.Tracing.SemConv") and the span name. Build
-- it with 'databaseQuery' and fill in the fields you know; every optional field
-- left as 'Nothing' is simply not recorded.
data DatabaseQuery = DatabaseQuery
  { querySystem :: !Text
  -- ^ @db.system.name@: the DBMS, for example @\"postgresql\"@. Required.
  , queryText :: !(Maybe Text)
  -- ^ @db.query.text@: the /parameterized/ statement (placeholders, not
  -- interpolated values), for example @\"SELECT * FROM users WHERE id = $1\"@.
  , queryOperation :: !(Maybe Text)
  -- ^ @db.operation.name@: the low-cardinality command keyword, for example
  -- @\"SELECT\"@. 'inferOperationName' can derive this from 'queryText'.
  , queryCollection :: !(Maybe Text)
  -- ^ @db.collection.name@: the primary table the call acts on, for example
  -- @\"users\"@.
  , queryNamespace :: !(Maybe Text)
  -- ^ @db.namespace@: the logical database the connection is scoped to.
  }
  deriving (Eq, Show)

-- | A 'DatabaseQuery' for the given @db.system.name@ with every optional field
-- unset, ready for record-update syntax to fill in what you know.
--
-- > (databaseQuery "postgresql") { queryOperation = Just "INSERT", queryCollection = Just "orders" }
databaseQuery :: Text -> DatabaseQuery
databaseQuery system =
  DatabaseQuery
    { querySystem = system
    , queryText = Nothing
    , queryOperation = Nothing
    , queryCollection = Nothing
    , queryNamespace = Nothing
    }

-- | Run a database action inside a @client@-kind span named by 'querySpanName'
-- and annotated with 'queryAttributes'. The span is finalized (with its end
-- time, and 'Effectful.Tracing.Error' status if the action throws) by the
-- shared span lifecycle when the action returns or unwinds.
withQuerySpan
  :: (HasCallStack, Tracer :> es)
  => DatabaseQuery
  -> Eff es a
  -> Eff es a
withQuerySpan q =
  withSpan'
    (querySpanName q)
    defaultSpanArguments
      { kind = Client
      , attributes = queryAttributes q
      }

-- | The span name for a query, following the OpenTelemetry convention: prefer
-- @{operation} {collection}@ (for example @\"SELECT users\"@), fall back to the
-- operation alone, then to the @db.system.name@ when neither is known. This
-- keeps the name low cardinality (never the full statement).
querySpanName :: DatabaseQuery -> Text
querySpanName q =
  case (queryOperation q, queryCollection q) of
    (Just op, Just coll) -> op <> " " <> coll
    (Just op, Nothing) -> op
    (Nothing, _) -> querySystem q

-- | The @db.*@ attributes for a query: @db.system.name@ always, plus
-- @db.query.text@, @db.operation.name@, @db.collection.name@, and
-- @db.namespace@ for whichever optional fields are set.
queryAttributes :: DatabaseQuery -> [Attribute]
queryAttributes q =
  (SemConv.dbSystemName .= querySystem q)
    : mapMaybe
      optional
      [ (SemConv.dbQueryText, queryText q)
      , (SemConv.dbOperationName, queryOperation q)
      , (SemConv.dbCollectionName, queryCollection q)
      , (SemConv.dbNamespace, queryNamespace q)
      ]
  where
    optional (key, value) = (key .=) <$> value

-- | Pull the low-cardinality operation name out of a statement: the leading
-- word, upper-cased, for example @\"SELECT\"@ from
-- @\"select * from users\"@. Returns 'Nothing' for a blank statement. This is a
-- best-effort heuristic for drivers that do not hand you the operation
-- directly; it does not parse SQL.
inferOperationName :: Text -> Maybe Text
inferOperationName statement =
  case T.words (T.dropWhile isSpace statement) of
    [] -> Nothing
    (w : _) -> Just (T.toUpper w)
