{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.PostgresqlSimple
-- Description : Tracing wrappers for postgresql-simple queries.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Drop-in replacements for the four core @postgresql-simple@ statement runners
-- (@query@, @query_@, @execute@, @execute_@) that run each call inside a
-- @client@-kind span recording the stable OpenTelemetry database semantic
-- conventions (see "Effectful.Tracing.SemConv"). The wrappers live in @'Eff' es@
-- and delegate to "Effectful.Tracing.Instrumentation.Database", so the span is
-- named after the statement's operation and finalized even if the query throws.
--
-- Import this module qualified alongside @postgresql-simple@ so the traced
-- runners shadow the originals at the call site:
--
-- > import Database.PostgreSQL.Simple (Connection, Only (..))
-- > import Effectful.Tracing.Instrumentation.PostgresqlSimple qualified as Pg
-- >
-- > activeUsers :: (IOE :> es, Tracer :> es) => Connection -> Eff es [(Int, Text)]
-- > activeUsers conn =
-- >   Pg.query conn "SELECT id, name FROM users WHERE active = ?" (Only True)
--
-- The recorded @db.query.text@ is the statement /template/ (with @?@
-- placeholders), not the interpolated SQL, so parameter values never reach the
-- span. The @db.operation.name@ is inferred from the leading keyword of that
-- template (see 'inferOperationName'); set @db.collection.name@ \/
-- @db.namespace@ yourself with "Effectful.Tracing.addAttribute" inside the call
-- if you want them, since they cannot be derived reliably without parsing SQL.
module Effectful.Tracing.Instrumentation.PostgresqlSimple
  ( query
  , query_
  , execute
  , execute_
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)
import Data.Text.Encoding (decodeUtf8Lenient)
import GHC.Stack (HasCallStack)

import Database.PostgreSQL.Simple (Connection, FromRow, Query, ToRow)
import Database.PostgreSQL.Simple qualified as Pg
import Database.PostgreSQL.Simple.Types (fromQuery)

import Effectful (Eff, IOE, (:>))
import Effectful.Tracing (Tracer)
import Effectful.Tracing.Instrumentation.Database
  ( DatabaseQuery (queryOperation, queryText)
  , databaseQuery
  , inferOperationName
  , withQuerySpan
  )

-- | 'Database.PostgreSQL.Simple.query' wrapped in a traced @client@-kind span.
query
  :: (HasCallStack, IOE :> es, Tracer :> es, ToRow q, FromRow r)
  => Connection
  -> Query
  -> q
  -> Eff es [r]
query conn template params =
  withQuerySpan (describe template) (liftIO (Pg.query conn template params))

-- | 'Database.PostgreSQL.Simple.query_' wrapped in a traced @client@-kind span.
query_
  :: (HasCallStack, IOE :> es, Tracer :> es, FromRow r)
  => Connection
  -> Query
  -> Eff es [r]
query_ conn template =
  withQuerySpan (describe template) (liftIO (Pg.query_ conn template))

-- | 'Database.PostgreSQL.Simple.execute' wrapped in a traced @client@-kind span.
execute
  :: (HasCallStack, IOE :> es, Tracer :> es, ToRow q)
  => Connection
  -> Query
  -> q
  -> Eff es Int64
execute conn template params =
  withQuerySpan (describe template) (liftIO (Pg.execute conn template params))

-- | 'Database.PostgreSQL.Simple.execute_' wrapped in a traced @client@-kind span.
execute_
  :: (HasCallStack, IOE :> es, Tracer :> es)
  => Connection
  -> Query
  -> Eff es Int64
execute_ conn template =
  withQuerySpan (describe template) (liftIO (Pg.execute_ conn template))

-- | Build the query description from a @postgresql-simple@ 'Query' template:
-- system @\"postgresql\"@, @db.query.text@ from the template, and
-- @db.operation.name@ inferred from its leading keyword.
describe :: Query -> DatabaseQuery
describe template =
  (databaseQuery "postgresql")
    { queryText = Just statement
    , queryOperation = inferOperationName statement
    }
  where
    statement = decodeUtf8Lenient (fromQuery template)
