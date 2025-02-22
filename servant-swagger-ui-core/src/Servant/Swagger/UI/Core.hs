{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-----------------------------------------------------------------------------
--
-- Provides 'SwaggerUI' and corresponding 'swaggerUIServer' to embed
-- <http://swagger.io/swagger-ui/ swagger ui> into the application.
--
-- All of UI files are embedded into the binary.
--
-- /An example:/
--
-- @
-- -- | Actual API.
-- type BasicAPI = Get '[PlainText, JSON] Text
--     :\<|> "cat" :> Capture ":name" CatName :> Get '[JSON] Cat
--
-- -- | API type with bells and whistles, i.e. schema file and swagger-ui.
-- type API = 'SwaggerSchemaUI' "swagger-ui" "swagger.json"
--     :\<|> BasicAPI
--
-- -- | Servant server for an API
-- server :: Server API
-- server = 'swaggerSchemaUIServer' swaggerDoc
--     :\<|> (pure "Hello World" :\<|> catEndpoint)
--   where
--     catEndpoint name = pure $ Cat name False
-- @

module Servant.Swagger.UI.Core
  ( -- * Swagger UI API
    SwaggerSchemaUI,
    SwaggerSchemaUI',

    -- * Implementation details
    SwaggerUiHtml (..),
    swaggerSchemaUIServerImpl,
    swaggerSchemaUIServerImpl',
    Handler,
  )
where

import Data.ByteString (ByteString)
import Data.OpenApi (OpenApi)
import qualified Data.Text as T
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Network.Wai.Application.Static (embeddedSettings, staticApp)
import Servant
  ( Get,
    Handler,
    HasLink (MkLink),
    HasServer (ServerT),
    IsElem,
    JSON,
    Link,
    Proxy (..),
    Raw,
    Tagged (Tagged),
    URI (uriPath),
    linkURI,
    safeLink,
    type (:<|>) (..),
    type (:>),
  )
import Servant.HTML.Blaze (HTML)
import Text.Blaze (ToMarkup (..))

-- | Swagger schema + ui api.
--
-- @SwaggerSchemaUI "swagger-ui" "swagger.json"@ will result into following hierarchy:
--
-- @
-- \/swagger.json
-- \/swagger-ui
-- \/swagger-ui\/index.html
-- \/swagger-ui\/...
-- @
type SwaggerSchemaUI (dir :: Symbol) (schema :: Symbol) =
  SwaggerSchemaUI' dir (schema :> Get '[JSON] OpenApi)

-- | Use 'SwaggerSchemaUI'' when you need even more control over
-- where @swagger.json@ is served (e.g. subdirectory).
type SwaggerSchemaUI' (dir :: Symbol) (api :: *) =
  api
    :<|> dir
      :> ( Get '[HTML] (SwaggerUiHtml dir api)
             :<|> "index.html" :> Get '[HTML] (SwaggerUiHtml dir api)
             :<|> Raw
         )

-- | Index file for swagger ui.
--
-- It's configured by the location of swagger schema and directory it lives under.
--
-- Implementation detail: the @index.html@ is prepopulated with parameters
-- to find schema file automatically.
data SwaggerUiHtml (dir :: Symbol) (api :: *) = SwaggerUiHtml T.Text

instance
  (KnownSymbol dir, HasLink api, Link ~ MkLink api Link, IsElem api api) =>
  ToMarkup (SwaggerUiHtml dir api)
  where
  toMarkup (SwaggerUiHtml template) =
    preEscapedToMarkup $
      T.replace "SERVANT_SWAGGER_UI_SCHEMA" schema $
        T.replace "SERVANT_SWAGGER_UI_DIR" dir $
          template
    where
      schema = T.pack $ uriPath . linkURI $ safeLink proxyApi proxyApi
      dir = T.pack $ symbolVal (Proxy :: Proxy dir)
      proxyApi = Proxy :: Proxy api

swaggerSchemaUIServerImpl ::
  (Monad m, ServerT api m ~ m OpenApi) =>
  T.Text ->
  [(FilePath, ByteString)] ->
  OpenApi ->
  ServerT (SwaggerSchemaUI' dir api) m
swaggerSchemaUIServerImpl indexTemplate files swagger =
  swaggerSchemaUIServerImpl' indexTemplate files $ return swagger

-- | Use a custom server to serve the Swagger spec source.
swaggerSchemaUIServerImpl' ::
  Monad m =>
  T.Text ->
  [(FilePath, ByteString)] ->
  ServerT api m ->
  ServerT (SwaggerSchemaUI' dir api) m
swaggerSchemaUIServerImpl' indexTemplate files server =
  server
    :<|> return (SwaggerUiHtml indexTemplate)
    :<|> return (SwaggerUiHtml indexTemplate)
    :<|> rest
  where
    rest = Tagged $ staticApp $ embeddedSettings files
