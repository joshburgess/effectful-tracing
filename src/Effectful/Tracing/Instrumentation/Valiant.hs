{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.Instrumentation.Valiant
-- Description : Tracing wrappers for valiant's Effectful adapter.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Drop-in replacements for the statement runners in @Valiant.Effectful@ (the
-- @valiant-effectful@ adapter for <https://hackage.haskell.org/package/valiant valiant>,
-- the compile-time checked PostgreSQL library) that run each call inside a
-- @client@-kind span recording the stable OpenTelemetry database semantic
-- conventions (see "Effectful.Tracing.SemConv"). Each wrapper delegates to the
-- @Valiant@ effect and to "Effectful.Tracing.Instrumentation.Database", so the
-- span is named after the statement's operation and finalized even if the query
-- throws.
--
-- Import this module qualified /instead of/ @Valiant.Effectful@ for the traced
-- runners, keeping @Valiant.Effectful@ for the handler ('Valiant.Effectful.runValiant')
-- and the transaction \/ raw-connection helpers, which carry no statement to
-- describe:
--
-- > import Valiant (Statement)
-- > import Valiant.Effectful (Valiant, runValiant)
-- > import Effectful.Tracing.Instrumentation.Valiant qualified as V
-- >
-- > activeUsers :: (Valiant :> es, Tracer :> es) => Statement () User -> Eff es [User]
-- > activeUsers listUsers = V.fetchAllEff listUsers ()
--
-- The system name is @postgresql@. The recorded @db.query.text@ is the
-- statement's own validated SQL (a 'Valiant.Statement', whose text is the
-- parameterized query, never interpolated values), and @db.operation.name@ is
-- inferred from its leading keyword (see 'inferOperationName'). Set
-- @db.collection.name@ \/ @db.namespace@ yourself with
-- "Effectful.Tracing.addAttribute" inside the call if you want them, since they
-- cannot be derived reliably without parsing SQL.
module Effectful.Tracing.Instrumentation.Valiant
  ( -- * Queries
    fetchOneEff
  , fetchAllEff
  , fetchScalarEff
  , fetchOneOrThrowEff
  , fetchExistsEff

    -- * Commands
  , executeEff
  , executeReturningEff
  , executeBatchEff
  ) where

import Data.Int (Int64)
import Data.Text.Encoding (decodeUtf8Lenient)
import GHC.Stack (HasCallStack)

import Valiant (Statement (stmtSQL))
import Valiant.Effectful (Valiant)
import Valiant.Effectful qualified as V

import Effectful (Eff, (:>))
import Effectful.Tracing (Tracer, addAttribute)
import Effectful.Tracing.Instrumentation.Database
  ( DatabaseQuery (queryOperation, queryText)
  , databaseQuery
  , inferOperationName
  , withQuerySpan
  )
import Effectful.Tracing.SemConv qualified as SemConv

-- | 'Valiant.Effectful.fetchOneEff' wrapped in a traced @client@-kind span.
fetchOneEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es (Maybe r)
fetchOneEff stmt params =
  withQuerySpan (describe stmt) (V.fetchOneEff stmt params)

-- | 'Valiant.Effectful.fetchAllEff' wrapped in a traced @client@-kind span.
fetchAllEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es [r]
fetchAllEff stmt params =
  withQuerySpan (describe stmt) (V.fetchAllEff stmt params)

-- | 'Valiant.Effectful.fetchScalarEff' wrapped in a traced @client@-kind span.
fetchScalarEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es r
fetchScalarEff stmt params =
  withQuerySpan (describe stmt) (V.fetchScalarEff stmt params)

-- | 'Valiant.Effectful.fetchOneOrThrowEff' wrapped in a traced @client@-kind span.
fetchOneOrThrowEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es r
fetchOneOrThrowEff stmt params =
  withQuerySpan (describe stmt) (V.fetchOneOrThrowEff stmt params)

-- | 'Valiant.Effectful.fetchExistsEff' wrapped in a traced @client@-kind span.
fetchExistsEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es Bool
fetchExistsEff stmt params =
  withQuerySpan (describe stmt) (V.fetchExistsEff stmt params)

-- | 'Valiant.Effectful.executeEff' wrapped in a traced @client@-kind span.
executeEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p ()
  -> p
  -> Eff es Int64
executeEff stmt params =
  withQuerySpan (describe stmt) (V.executeEff stmt params)

-- | 'Valiant.Effectful.executeReturningEff' wrapped in a traced @client@-kind span.
executeReturningEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p r
  -> p
  -> Eff es (Int64, [r])
executeReturningEff stmt params =
  withQuerySpan (describe stmt) (V.executeReturningEff stmt params)

-- | 'Valiant.Effectful.executeBatchEff' wrapped in a traced @client@-kind span.
-- The number of parameter rows is recorded as @db.operation.batch.size@.
executeBatchEff
  :: (HasCallStack, Valiant :> es, Tracer :> es)
  => Statement p ()
  -> [p]
  -> Eff es Int64
executeBatchEff stmt paramsList =
  withQuerySpan (describe stmt) $ do
    addAttribute SemConv.dbOperationBatchSize (length paramsList)
    V.executeBatchEff stmt paramsList

-- | Build the query description from a 'Valiant.Statement': system
-- @\"postgresql\"@, @db.query.text@ from the statement's validated SQL, and
-- @db.operation.name@ inferred from its leading keyword.
describe :: Statement p r -> DatabaseQuery
describe stmt =
  (databaseQuery "postgresql")
    { queryText = Just statement
    , queryOperation = inferOperationName statement
    }
  where
    statement = decodeUtf8Lenient (stmtSQL stmt)
