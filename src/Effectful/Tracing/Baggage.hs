{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Effectful.Tracing.Baggage
-- Description : Ambient key-value context (W3C Baggage) as a scoped effect.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- <https://www.w3.org/TR/baggage/ W3C Baggage> is a set of key-value pairs that
-- travels alongside a trace across service boundaries, carrying application
-- context (a tenant id, a feature flag, a request priority) that any downstream
-- service can read. Unlike span attributes, baggage is not tied to a single
-- span: it is __ambient__, in scope for everything that runs within it.
--
-- This module models that ambient context the same way the 'Tracer' interpreters
-- model the active span: __lexically__, carried in a private @effectful@
-- @Reader@ and scoped with a @local@-style combinator
-- rather than thread-local mutable state. 'runBaggage' installs the context,
-- 'getBaggage' reads it, and 'localBaggage' \/ 'withBaggageEntry' set entries for
-- a nested scope only. Because the carrier is a handler-local value, baggage
-- propagates into forked work through @effectful@'s environment cloning, the same
-- as the active span (see "Effectful.Tracing.Concurrent").
--
-- The 't:Baggage' value, its pure operations, and this effect are all backend
-- independent. To carry baggage across a network hop, render and parse the
-- @baggage@ header with "Effectful.Tracing.Propagation.Baggage".
--
-- > import Effectful (runEff)
-- > import Effectful.Tracing.Baggage
-- >
-- > example = runEff . runBaggage $ do
-- >   withBaggageEntry "tenant.id" "acme" $ do
-- >     tenant <- lookupBaggageValue "tenant.id" <$> getBaggage
-- >     ...                                  -- tenant == Just "acme" in this scope
module Effectful.Tracing.Baggage
  ( -- * Baggage values
    Baggage
  , BaggageEntry (..)
  , emptyBaggage
  , insertBaggage
  , insertBaggageEntry
  , deleteBaggage
  , lookupBaggage
  , lookupBaggageValue
  , baggageToList
  , baggageFromList
  , nullBaggage
  , baggageSize

    -- * The ambient effect
  , BaggageContext
  , runBaggage
  , runBaggageWith
  , getBaggage
  , localBaggage
  , withBaggageEntry
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (localSeqUnlift, reinterpret, send)
import Effectful.Reader.Static (ask, local, runReader)

-- | One baggage entry: a value plus optional metadata. The metadata is the
-- verbatim @;@-separated property string the W3C format allows after a value
-- (for example @;ttl=30@); most entries have none. It is preserved on a
-- round-trip but otherwise opaque to this library.
data BaggageEntry = BaggageEntry
  { baggageValue :: !Text
  -- ^ The entry's value (already percent-decoded when parsed from a header).
  , baggageMetadata :: !(Maybe Text)
  -- ^ The verbatim property string, if any.
  }
  deriving (Eq, Show)

-- | An immutable set of baggage entries keyed by name. Construct it with
-- 'emptyBaggage' and the @insert@ \/ @delete@ operations, or parse it from a
-- header with "Effectful.Tracing.Propagation.Baggage".
newtype Baggage = Baggage (Map Text BaggageEntry)
  deriving (Eq, Show)

-- | The empty baggage set.
emptyBaggage :: Baggage
emptyBaggage = Baggage Map.empty

-- | Set a key to a bare value (no metadata), replacing any existing entry.
insertBaggage :: Text -> Text -> Baggage -> Baggage
insertBaggage key value = insertBaggageEntry key (BaggageEntry value Nothing)

-- | Set a key to a full 't:BaggageEntry' (value plus metadata), replacing any
-- existing entry.
insertBaggageEntry :: Text -> BaggageEntry -> Baggage -> Baggage
insertBaggageEntry key entry (Baggage m) = Baggage (Map.insert key entry m)

-- | Remove a key. A no-op if it is absent.
deleteBaggage :: Text -> Baggage -> Baggage
deleteBaggage key (Baggage m) = Baggage (Map.delete key m)

-- | Look up an entry (value and metadata) by key.
lookupBaggage :: Text -> Baggage -> Maybe BaggageEntry
lookupBaggage key (Baggage m) = Map.lookup key m

-- | Look up just the value for a key, ignoring any metadata.
lookupBaggageValue :: Text -> Baggage -> Maybe Text
lookupBaggageValue key = fmap baggageValue . lookupBaggage key

-- | All entries, ordered by key.
baggageToList :: Baggage -> [(Text, BaggageEntry)]
baggageToList (Baggage m) = Map.toList m

-- | Build baggage from a list of entries. On a duplicate key the last entry
-- wins.
baggageFromList :: [(Text, BaggageEntry)] -> Baggage
baggageFromList = Baggage . Map.fromList

-- | Whether the baggage set is empty.
nullBaggage :: Baggage -> Bool
nullBaggage (Baggage m) = Map.null m

-- | The number of entries.
baggageSize :: Baggage -> Int
baggageSize (Baggage m) = Map.size m

-- | The ambient-baggage capability. @GetBaggage@ reads the in-scope baggage;
-- @LocalBaggage@ runs a sub-action with the baggage transformed for that scope
-- only. The constructors are private: program against 'getBaggage',
-- 'localBaggage', and 'withBaggageEntry', and discharge the effect with
-- 'runBaggage' \/ 'runBaggageWith'.
data BaggageContext :: Effect where
  GetBaggage :: BaggageContext m Baggage
  LocalBaggage :: (Baggage -> Baggage) -> m a -> BaggageContext m a

type instance DispatchOf BaggageContext = Dynamic

-- | Discharge the effect starting from 'emptyBaggage'. Use this when a process
-- originates baggage itself.
runBaggage :: Eff (BaggageContext : es) a -> Eff es a
runBaggage = runBaggageWith emptyBaggage

-- | Discharge the effect starting from the given baggage. Use this to seed the
-- context from an inbound request, pairing it with
-- 'Effectful.Tracing.Propagation.Baggage.extractBaggage'.
--
-- The baggage is carried in a private @Reader@ and scoped with @local@, so it is
-- lexical: 'localBaggage' and 'withBaggageEntry' affect only their nested action.
runBaggageWith :: Baggage -> Eff (BaggageContext : es) a -> Eff es a
runBaggageWith initial =
  reinterpret (runReader initial) $ \env -> \case
    GetBaggage -> ask
    LocalBaggage f action ->
      localSeqUnlift env $ \unlift -> local f (unlift action)

-- | The baggage currently in scope.
getBaggage :: BaggageContext :> es => Eff es Baggage
getBaggage = send GetBaggage

-- | Run a sub-action with the baggage transformed by the given function. The
-- change is visible only inside the action (and anything it forks); the
-- surrounding scope is unchanged.
--
-- > localBaggage (insertBaggage "request.priority" "high") $ ...
localBaggage :: BaggageContext :> es => (Baggage -> Baggage) -> Eff es a -> Eff es a
localBaggage f action = send (LocalBaggage f action)

-- | Run a sub-action with one extra entry (a bare value) in scope. A
-- convenience for the common @'localBaggage' . 'insertBaggage'@.
--
-- > withBaggageEntry "tenant.id" "acme" $ ...
withBaggageEntry :: BaggageContext :> es => Text -> Text -> Eff es a -> Eff es a
withBaggageEntry key value = localBaggage (insertBaggage key value)
