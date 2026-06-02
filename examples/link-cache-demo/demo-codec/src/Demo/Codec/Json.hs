{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Aeson encodings for the demo-core types. We hand-roll the
-- 'Expr' instances because GADT-constrained data doesn't auto-derive
-- ToJSON/FromJSON cleanly, and the explicit form is more interesting
-- as demo code anyway.
module Demo.Codec.Json
  ( encodeExpr
  , decodeExpr
  , encodeNodeId
  , decodeNodeId
  ) where

import qualified Data.Aeson           as A
import qualified Data.Aeson.Types     as A
import qualified Data.ByteString.Lazy as BSL

import Demo.Core.Types

-- | Encode an 'Expr' to JSON bytes.
encodeExpr :: Expr -> BSL.ByteString
encodeExpr = A.encode . exprToJSON

-- | Decode JSON bytes into an 'Expr'.
decodeExpr :: BSL.ByteString -> Either String Expr
decodeExpr bs = case A.eitherDecode bs of
  Left err -> Left err
  Right v  -> A.parseEither exprFromJSON v

encodeNodeId :: NodeId -> BSL.ByteString
encodeNodeId (NodeId n) = A.encode n

decodeNodeId :: BSL.ByteString -> Either String NodeId
decodeNodeId = fmap NodeId . A.eitherDecode

-- -- Expr <-> JSON --------------------------------------------------

exprToJSON :: Expr -> A.Value
exprToJSON = \case
  ELit l       -> A.object [ "tag" A..= ("lit" :: String), "lit" A..= litToJSON l ]
  EBin op a b  -> A.object [ "tag" A..= ("bin" :: String)
                           , "op"  A..= show op
                           , "lhs" A..= exprToJSON a
                           , "rhs" A..= exprToJSON b
                           ]
  EIf c t e    -> A.object [ "tag"  A..= ("if" :: String)
                           , "cond" A..= exprToJSON c
                           , "then" A..= exprToJSON t
                           , "else" A..= exprToJSON e
                           ]

litToJSON :: Lit -> A.Value
litToJSON = \case
  LInt  n -> A.object [ "int"  A..= n ]
  LDbl  d -> A.object [ "dbl"  A..= d ]
  LBool b -> A.object [ "bool" A..= b ]

exprFromJSON :: A.Value -> A.Parser Expr
exprFromJSON = A.withObject "Expr" $ \o -> do
  tag <- o A..: "tag" :: A.Parser String
  case tag of
    "lit" -> ELit <$> (o A..: "lit" >>= litFromJSON)
    "bin" -> do
      op <- o A..: "op"
      a  <- o A..: "lhs" >>= exprFromJSON
      b  <- o A..: "rhs" >>= exprFromJSON
      pure (EBin (read op) a b)
    "if"  -> do
      c <- o A..: "cond" >>= exprFromJSON
      t <- o A..: "then" >>= exprFromJSON
      e <- o A..: "else" >>= exprFromJSON
      pure (EIf c t e)
    other -> fail ("Expr: unknown tag " <> other)

litFromJSON :: A.Value -> A.Parser Lit
litFromJSON = A.withObject "Lit" $ \o ->
      (LInt  <$> o A..: "int")
  <> (LDbl  <$> o A..: "dbl")
  <> (LBool <$> o A..: "bool")
