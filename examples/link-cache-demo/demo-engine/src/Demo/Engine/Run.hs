{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Orchestration entrypoint used by the demo-app executable. Bakes
-- in a small expression + graph so the executable produces something
-- to look at without needing CLI arg parsing.
module Demo.Engine.Run
  ( runDemo
  , demoInput
  ) where

import qualified Data.ByteString.Lazy as BSL

import Demo.Codec.Json      (encodeExpr)
import Demo.Core.Types
import Demo.Engine.Pipeline (PipelineInput (..), PipelineResult (..), runPipeline)
import Demo.Graph.Build     (Graph, fromEdges)

-- | Canonical input used by the executable and the engine tests.
demoInput :: PipelineInput
demoInput = PipelineInput
  { piExprBytes = encodeExpr exampleExpr
  , piGraph     = exampleGraph
  }

exampleExpr :: Expr
exampleExpr =
  EIf (ELit (LBool True))
      (EBin OAdd (ELit (LInt 2)) (EBin OMul (ELit (LInt 3)) (ELit (LInt 4))))
      (ELit (LInt 0))

exampleGraph :: Graph
exampleGraph = fromEdges
  [ (NodeId 0, NodeId 1, Weight 1.0)
  , (NodeId 0, NodeId 2, Weight 2.5)
  , (NodeId 1, NodeId 3, Weight 0.5)
  , (NodeId 2, NodeId 3, Weight 0.5)
  , (NodeId 3, NodeId 4, Weight 1.0)
  ]

-- | Render the pipeline result as a multi-line string.
runDemo :: IO ()
runDemo = case runPipeline demoInput of
  Left err -> putStrLn ("pipeline failed: " <> err)
  Right PipelineResult{..} -> do
    putStrLn "demo-app pipeline result:"
    putStrLn ("  root value : " <> show prRootValue)
    putStrLn ("  dfs order  : " <> show prDfsOrder)
    putStrLn ("  topo order : " <> show prTopo)
    putStrLn ("  summary    : " <> prSummary)
