{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.SqliteSimple
-- Description : Tracing wrappers for sqlite-simple queries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Drop-in replacements for the @sqlite-simple@ statement runners (@query@,
-- @query_@, @execute@, @execute_@, @executeMany@) that run each call inside a
-- @client@-kind span recording the stable OpenTelemetry database semantic
-- conventions (see "Effectful.Tracing.SemConv"). The wrappers live in @'Eff' es@
-- and delegate to "Effectful.Tracing.Instrumentation.Database", so the span is
-- named after the statement's operation and finalized even if the query throws.
--
-- Import this module qualified alongside @sqlite-simple@ so the traced runners
-- shadow the originals at the call site:
--
-- > import Database.SQLite.Simple (Connection, Only (..))
-- > import Effectful.Tracing.Instrumentation.SqliteSimple qualified as Sqlite
-- >
-- > activeUsers :: (IOE :> es, Tracer :> es) => Connection -> Eff es [(Int, Text)]
-- > activeUsers conn =
-- >   Sqlite.query conn "SELECT id, name FROM users WHERE active = ?" (Only True)
--
-- The recorded @db.query.text@ is the statement /template/ (with @?@
-- placeholders), not the interpolated SQL, so parameter values never reach the
-- span. The @db.operation.name@ is inferred from the leading keyword of that
-- template (see 'inferOperationName'); set @db.collection.name@ \/
-- @db.namespace@ yourself with "Effectful.Tracing.addAttribute" inside the call
-- if you want them, since they cannot be derived reliably without parsing SQL.
module Effectful.Tracing.Instrumentation.SqliteSimple
  ( query
  , query_
  , execute
  , execute_
  , executeMany
  ) where

import Control.Monad.IO.Class (liftIO)
import GHC.Stack (HasCallStack)

import Database.SQLite.Simple (Connection, FromRow, Query, ToRow)
import Database.SQLite.Simple qualified as Sqlite
import Database.SQLite.Simple.Types (fromQuery)

import Effectful (Eff, IOE, (:>))
import Effectful.Tracing (Tracer, addAttribute)
import Effectful.Tracing.Instrumentation.Database
  ( DatabaseQuery (queryOperation, queryText)
  , databaseQuery
  , inferOperationName
  , withQuerySpan
  )
import Effectful.Tracing.SemConv qualified as SemConv

-- | 'Database.SQLite.Simple.query' wrapped in a traced @client@-kind span.
query
  :: (HasCallStack, IOE :> es, Tracer :> es, ToRow q, FromRow r)
  => Connection
  -> Query
  -> q
  -> Eff es [r]
query conn template params =
  withQuerySpan (describe template) (liftIO (Sqlite.query conn template params))

-- | 'Database.SQLite.Simple.query_' wrapped in a traced @client@-kind span.
query_
  :: (HasCallStack, IOE :> es, Tracer :> es, FromRow r)
  => Connection
  -> Query
  -> Eff es [r]
query_ conn template =
  withQuerySpan (describe template) (liftIO (Sqlite.query_ conn template))

-- | 'Database.SQLite.Simple.execute' wrapped in a traced @client@-kind span.
execute
  :: (HasCallStack, IOE :> es, Tracer :> es, ToRow q)
  => Connection
  -> Query
  -> q
  -> Eff es ()
execute conn template params =
  withQuerySpan (describe template) (liftIO (Sqlite.execute conn template params))

-- | 'Database.SQLite.Simple.execute_' wrapped in a traced @client@-kind span.
execute_
  :: (HasCallStack, IOE :> es, Tracer :> es)
  => Connection
  -> Query
  -> Eff es ()
execute_ conn template =
  withQuerySpan (describe template) (liftIO (Sqlite.execute_ conn template))

-- | 'Database.SQLite.Simple.executeMany' wrapped in a traced @client@-kind
-- span. The number of parameter rows is recorded as @db.operation.batch.size@.
executeMany
  :: (HasCallStack, IOE :> es, Tracer :> es, ToRow q)
  => Connection
  -> Query
  -> [q]
  -> Eff es ()
executeMany conn template paramsList =
  withQuerySpan (describe template) $ do
    addAttribute SemConv.dbOperationBatchSize (length paramsList)
    liftIO (Sqlite.executeMany conn template paramsList)

-- | Build the query description from a @sqlite-simple@ 'Query' template: system
-- @\"sqlite\"@, @db.query.text@ from the template, and @db.operation.name@
-- inferred from its leading keyword.
describe :: Query -> DatabaseQuery
describe template =
  (databaseQuery "sqlite")
    { queryText = Just statement
    , queryOperation = inferOperationName statement
    }
  where
    statement = fromQuery template
