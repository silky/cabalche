{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | High-level pipeline: load an expression from JSON, evaluate it,
-- and traverse a graph rooted at a node whose id is derived from the
-- evaluation result.
module Demo.Engine.Pipeline
  ( PipelineInput (..)
  , PipelineResult (..)
  , runPipeline
  ) where

import qualified Data.ByteString.Lazy as BSL

import Demo.Codec.Json     (decodeExpr)
import Demo.Core.Types
import Demo.Core.Util      (describe, normaliseList)
import Demo.Graph.Build    (Graph, nodes)
import Demo.Graph.Traverse (dfsFrom, isAcyclic, topoSort)

data PipelineInput = PipelineInput
  { piExprBytes :: BSL.ByteString
  , piGraph     :: Graph
  } deriving (Eq, Show)

data PipelineResult = PipelineResult
  { prRootValue :: Lit
  , prDfsOrder  :: [NodeId]
  , prTopo      :: Maybe [NodeId]
  , prSummary   :: String
  } deriving (Eq, Show)

-- | Decode the input expression, evaluate it, and use the result to
-- decide which graph node to root the DFS at:
--
-- * 'LInt n'   -> @NodeId (n `mod` count)@
-- * 'LDbl d'   -> @NodeId (floor d `mod` count)@
-- * 'LBool b'  -> @NodeId (if b then 0 else count - 1)@
runPipeline :: PipelineInput -> Either String PipelineResult
runPipeline PipelineInput{..} = do
  e <- decodeExpr piExprBytes
  let v = evalExpr e
  case nodes piGraph of
    []    -> Left "pipeline: graph is empty"
    ns    -> do
      let count = length ns
          rootIdx = case v of
            LInt  n -> n `mod` count
            LDbl  d -> floor d `mod` count
            LBool b -> if b then 0 else count - 1
          root  = ns !! (rootIdx `mod` count)
          order = normaliseList (dfsFrom root piGraph)
          topo  = topoSort piGraph
      pure PipelineResult
        { prRootValue = v
        , prDfsOrder  = order
        , prTopo      = topo
        , prSummary   = describe v
                     <> ", root=" <> show root
                     <> ", acyclic=" <> show (isAcyclic piGraph)
        }
