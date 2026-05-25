{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Effectful.Tracing.SemConv
-- Description : OpenTelemetry semantic-convention attribute keys.
-- Copyright   : (c) The effectful-tracing contributors
-- License     : BSD-3-Clause
-- Stability   : experimental
--
-- Typed constants for the OpenTelemetry semantic-convention attribute keys this
-- library emits, so the instrumentation modules name attributes from one place
-- instead of scattering string literals. The values track the /stable/ HTTP and
-- URL conventions (the @http.request.method@ \/ @url.full@ \/
-- @http.response.status_code@ set), not the older pre-stable names
-- (@http.method@, @http.url@, @http.status_code@) that earlier releases used.
--
-- These are plain 'Text', so you can use them directly with '.=' (from
-- "Effectful.Tracing.Attribute") when recording your own attributes:
--
-- > import Effectful.Tracing (addAttribute)
-- > import Effectful.Tracing.SemConv qualified as SemConv
-- >
-- > addAttribute SemConv.httpRoute ("/users/{id}" :: Text)
--
-- The naming follows the convention namespaces: @http.*@ for protocol-level
-- request and response attributes, @url.*@ for the parts of the request URL,
-- @network.*@ for transport details, @db.*@ for database client calls, and
-- @exception.*@ for recorded errors.
module Effectful.Tracing.SemConv
  ( -- * HTTP attributes
    httpRequestMethod
  , httpResponseStatusCode
  , httpRoute

    -- * URL attributes
  , urlFull
  , urlScheme
  , urlPath
  , urlQuery

    -- * Network attributes
  , networkProtocolVersion

    -- * Database attributes
  , dbSystemName
  , dbQueryText
  , dbOperationName
  , dbCollectionName
  , dbNamespace

    -- * Exception attributes
  , exceptionType
  , exceptionMessage
  ) where

import Data.Text (Text)

-- | @http.request.method@: the HTTP request method, for example @\"GET\"@ or
-- @\"POST\"@. (Stable replacement for the pre-stable @http.method@.)
httpRequestMethod :: Text
httpRequestMethod = "http.request.method"

-- | @http.response.status_code@: the HTTP response status code, for example
-- @200@. (Stable replacement for the pre-stable @http.status_code@.)
httpResponseStatusCode :: Text
httpResponseStatusCode = "http.response.status_code"

-- | @http.route@: the matched route template (low cardinality), for example
-- @\"/users/{id}\"@. Set this only when the routing layer knows the template;
-- never the raw, high-cardinality path.
httpRoute :: Text
httpRoute = "http.route"

-- | @url.full@: the absolute request URL, for example
-- @\"https:\/\/example.com\/widgets?q=cat\"@. (Stable replacement for the
-- pre-stable @http.url@.)
urlFull :: Text
urlFull = "url.full"

-- | @url.scheme@: the URL scheme, for example @\"http\"@ or @\"https\"@. (Stable
-- replacement for the pre-stable @http.scheme@.)
urlScheme :: Text
urlScheme = "url.scheme"

-- | @url.path@: the path component of the request URL, for example
-- @\"/widgets\"@, without any query string. (Half of the stable replacement for
-- the pre-stable @http.target@; see 'urlQuery' for the other half.)
urlPath :: Text
urlPath = "url.path"

-- | @url.query@: the query component of the request URL, for example
-- @\"q=cat\"@, without the leading @?@. (The other half of the stable
-- replacement for the pre-stable @http.target@; see 'urlPath'.)
urlQuery :: Text
urlQuery = "url.query"

-- | @network.protocol.version@: the protocol version, for example @\"1.1\"@ or
-- @\"2\"@. (Stable replacement for the pre-stable @http.flavor@.)
networkProtocolVersion :: Text
networkProtocolVersion = "network.protocol.version"

-- | @db.system.name@: the database management system, for example
-- @\"postgresql\"@ or @\"mysql\"@. (Stable replacement for the pre-stable
-- @db.system@.)
dbSystemName :: Text
dbSystemName = "db.system.name"

-- | @db.query.text@: the database query text, for example
-- @\"SELECT * FROM users WHERE id = $1\"@. Record the /parameterized/ statement
-- (placeholders, not interpolated values) to keep cardinality low and avoid
-- leaking row data. (Stable replacement for the pre-stable @db.statement@.)
dbQueryText :: Text
dbQueryText = "db.query.text"

-- | @db.operation.name@: the name of the operation being executed, for example
-- @\"SELECT\"@ or @\"INSERT\"@. This is the low-cardinality command keyword, not
-- the full statement. (Stable replacement for the pre-stable @db.operation@.)
dbOperationName :: Text
dbOperationName = "db.operation.name"

-- | @db.collection.name@: the primary table (or collection) the operation acts
-- on, for example @\"users\"@. (Stable replacement for the pre-stable
-- @db.sql.table@ \/ @db.mongodb.collection@.)
dbCollectionName :: Text
dbCollectionName = "db.collection.name"

-- | @db.namespace@: the logical database name the connection is scoped to, for
-- example @\"orders\"@. (Stable replacement for the pre-stable @db.name@.)
dbNamespace :: Text
dbNamespace = "db.namespace"

-- | @exception.type@: the type or class of an exception, for example
-- @\"IOException\"@.
exceptionType :: Text
exceptionType = "exception.type"

-- | @exception.message@: the human-readable exception message. (Already the
-- stable key; included here so all recorded keys live in one module.)
exceptionMessage :: Text
exceptionMessage = "exception.message"
