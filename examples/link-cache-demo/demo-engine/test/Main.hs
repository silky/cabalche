module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit

import Demo.Core.Types
import Demo.Codec.Json      (encodeExpr)
import Demo.Engine.Pipeline (PipelineInput (..), PipelineResult (..), runPipeline)
import Demo.Engine.Run      (demoInput)
import Demo.Graph.Build     (fromEdges)

main :: IO ()
main = defaultMain $ testGroup "demo-engine"
  [ testCase "demoInput runs to a result" $
      case runPipeline demoInput of
        Right r -> do
          prRootValue r @?= LInt 14
          length (prDfsOrder r) > 0 @? "DFS produced some nodes"
        Left err -> assertFailure ("pipeline failed: " <> err)
  , testCase "empty graph is rejected" $
      case runPipeline (PipelineInput
                          { piExprBytes = encodeExpr (ELit (LInt 0))
                          , piGraph     = fromEdges []
                          }) of
        Left _  -> pure ()
        Right _ -> assertFailure "expected pipeline to fail on empty graph"
  , testCase "boolean steers root index to first when true" $ do
      let g = fromEdges
                [ (NodeId 10, NodeId 11, Weight 1)
                , (NodeId 11, NodeId 12, Weight 1)
                ]
          inp = PipelineInput
                  { piExprBytes = encodeExpr (ELit (LBool True))
                  , piGraph     = g
                  }
      case runPipeline inp of
        Right r -> prRootValue r @?= LBool True
        Left e  -> assertFailure e
  ]
