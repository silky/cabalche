{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}

module Demo.Core.Types
  ( NodeId (..)
  , Weight (..)
  , Expr (..)
  , Lit (..)
  , Op (..)
  , evalExpr
  , depthOf
  ) where

import GHC.Generics (Generic)

-- | Identity of a graph node. Newtype so callers can't accidentally
-- mix node ids with arbitrary Ints.
newtype NodeId = NodeId { unNodeId :: Int }
  deriving stock   (Show, Read, Generic)
  deriving newtype (Eq, Ord)

-- | Edge weights are non-negative; we don't enforce that in the
-- type but the smart ctor in Build does.
newtype Weight = Weight { unWeight :: Double }
  deriving stock   (Show, Read, Generic)
  deriving newtype (Eq, Ord, Num, Fractional)

-- | Literal payload for an expression leaf.
data Lit
  = LInt  Int
  | LDbl  Double
  | LBool Bool
  deriving stock (Eq, Ord, Show, Read, Generic)

-- | Binary arithmetic / boolean operators.
data Op = OAdd | OMul | OAnd | OOr
  deriving stock (Eq, Ord, Show, Read, Generic, Bounded, Enum)

-- | Small expression AST. GADT form here is overkill for the
-- arithmetic, but it lets us be explicit that 'EIf' carries a
-- boolean discriminant and pulls in a few extension trade-offs the
-- demo wants to exhibit.
data Expr where
  ELit  :: Lit            -> Expr
  EBin  :: Op  -> Expr -> Expr -> Expr
  EIf   :: Expr -> Expr -> Expr -> Expr

deriving stock instance Show Expr
deriving stock instance Eq   Expr

-- | Reduce an 'Expr' to a 'Lit'. Operator-type mismatches collapse
-- to a 'LBool' false; this is a demo, not a typed evaluator.
evalExpr :: Expr -> Lit
evalExpr = \case
  ELit l        -> l
  EBin op a b   -> apply op (evalExpr a) (evalExpr b)
  EIf c t e     -> case evalExpr c of
    LBool True  -> evalExpr t
    _           -> evalExpr e
  where
    apply OAdd (LInt x)  (LInt y)  = LInt  (x + y)
    apply OAdd (LDbl x)  (LDbl y)  = LDbl  (x + y)
    apply OMul (LInt x)  (LInt y)  = LInt  (x * y)
    apply OMul (LDbl x)  (LDbl y)  = LDbl  (x * y)
    apply OAnd (LBool x) (LBool y) = LBool (x && y)
    apply OOr  (LBool x) (LBool y) = LBool (x || y)
    apply _    _         _         = LBool False

-- | Maximum nesting depth of an 'Expr'.
depthOf :: Expr -> Int
depthOf = go 0
  where
    go !acc = \case
      ELit{}      -> acc
      EBin _ a b  -> 1 + max (go acc a) (go acc b)
      EIf  c t e  -> 1 + maximum [go acc c, go acc t, go acc e]
