-- |
-- Module      : Effectful.Tracing.Attribute
-- Description : Attribute values and conversions.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Span attributes are typed key/value pairs. Following the OpenTelemetry data
-- model, a value is a scalar ('AttrText', 'AttrBool', 'AttrInt', 'AttrDouble')
-- or a /homogeneous/ array of one of those scalar types. Heterogeneous arrays
-- are unrepresentable by construction.
--
-- Use '(.=)' with the 'ToAttributeValue' class to build attributes ergonomically:
--
-- @
-- import Effectful.Tracing.Attribute
--
-- attrs :: [Attribute]
-- attrs =
--   [ \"http.method\" '.=' (\"GET\" :: Text)
--   , \"http.status_code\" '.=' (200 :: Int)
--   , \"http.request.header.accept\" '.=' ([\"application\/json\"] :: [Text])
--   ]
-- @
module Effectful.Tracing.Attribute
  ( AttributeValue (..)
  , Attribute (..)
  , (.=)
  , ToAttributeValue (..)
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V

-- | A typed attribute value: a scalar or a homogeneous array of scalars.
data AttributeValue
  = AttrText !Text
  | AttrBool !Bool
  | AttrInt !Int64
  | AttrDouble !Double
  | AttrTextArray !(Vector Text)
  | AttrBoolArray !(Vector Bool)
  | AttrIntArray !(Vector Int64)
  | AttrDoubleArray !(Vector Double)
  deriving (Eq, Show)

-- | A key/value attribute attached to a span, event, or link.
data Attribute = Attribute
  { attributeKey :: !Text
  , attributeValue :: !AttributeValue
  }
  deriving (Eq, Show)

-- | Build an 'Attribute' from a key and any 'ToAttributeValue'.
(.=) :: (ToAttributeValue v) => Text -> v -> Attribute
key .= value = Attribute key (toAttributeValue value)

infixr 8 .=

-- | Types that can be used directly as an 'AttributeValue'.
--
-- Scalar instances cover 'Text', 'String', 'Bool', 'Int', 'Int64', 'Double',
-- and 'Float'. List and 'Vector' instances of those scalar types map to the
-- corresponding homogeneous array variants. @Int@ widens to @Int64@ and @Float@
-- widens to @Double@ to match the underlying representation.
class ToAttributeValue a where
  toAttributeValue :: a -> AttributeValue

instance ToAttributeValue AttributeValue where
  toAttributeValue = id

instance ToAttributeValue Text where
  toAttributeValue = AttrText

instance ToAttributeValue String where
  toAttributeValue = AttrText . T.pack

instance ToAttributeValue Bool where
  toAttributeValue = AttrBool

instance ToAttributeValue Int where
  toAttributeValue = AttrInt . fromIntegral

instance ToAttributeValue Int64 where
  toAttributeValue = AttrInt

instance ToAttributeValue Double where
  toAttributeValue = AttrDouble

instance ToAttributeValue Float where
  toAttributeValue = AttrDouble . realToFrac

instance ToAttributeValue (Vector Text) where
  toAttributeValue = AttrTextArray

instance ToAttributeValue (Vector Bool) where
  toAttributeValue = AttrBoolArray

instance ToAttributeValue (Vector Int64) where
  toAttributeValue = AttrIntArray

instance ToAttributeValue (Vector Double) where
  toAttributeValue = AttrDoubleArray

instance ToAttributeValue [Text] where
  toAttributeValue = AttrTextArray . V.fromList

instance ToAttributeValue [Bool] where
  toAttributeValue = AttrBoolArray . V.fromList

instance ToAttributeValue [Int64] where
  toAttributeValue = AttrIntArray . V.fromList

instance ToAttributeValue [Int] where
  toAttributeValue = AttrIntArray . V.fromList . map fromIntegral

instance ToAttributeValue [Double] where
  toAttributeValue = AttrDoubleArray . V.fromList

instance ToAttributeValue [Float] where
  toAttributeValue = AttrDoubleArray . V.fromList . map realToFrac
