module Main (main) where

import qualified Data.Set as Set

import Test.Tasty
import Test.Tasty.HUnit

import Demo.Core.Types
import Demo.Graph.Build
import Demo.Graph.Traverse

main :: IO ()
main = defaultMain $ testGroup "demo-graph"
  [ testGroup "Build"
      [ testCase "fromEdges dedups parallels by min weight" $ do
          let g = fromEdges
                    [ (NodeId 0, NodeId 1, Weight 5)
                    , (NodeId 0, NodeId 1, Weight 2)
                    , (NodeId 0, NodeId 1, Weight 9)
                    ]
          edges g @?= [(NodeId 0, NodeId 1, Weight 2)]
      , testCase "fromEdges clamps negative weights to 0" $ do
          let g = fromEdges [(NodeId 0, NodeId 1, Weight (-3))]
          edges g @?= [(NodeId 0, NodeId 1, Weight 0)]
      , testCase "sinks show up as nodes" $ do
          let g = fromEdges [(NodeId 0, NodeId 1, Weight 1)]
          Set.fromList (nodes g) @?= Set.fromList [NodeId 0, NodeId 1]
      ]
  , testGroup "Traverse"
      [ testCase "dfs visits all reachable in DAG" $ do
          let g = fromEdges
                    [ (NodeId 0, NodeId 1, Weight 1)
                    , (NodeId 1, NodeId 2, Weight 1)
                    , (NodeId 0, NodeId 2, Weight 1)
                    ]
          Set.fromList (dfsFrom (NodeId 0) g)
            @?= Set.fromList [NodeId 0, NodeId 1, NodeId 2]
      , testCase "topoSort respects edges" $ do
          let g = fromEdges
                    [ (NodeId 0, NodeId 1, Weight 1)
                    , (NodeId 1, NodeId 2, Weight 1)
                    , (NodeId 0, NodeId 2, Weight 1)
                    ]
          case topoSort g of
            Just order -> do
              positionOf (NodeId 0) order < positionOf (NodeId 1) order @? "0 before 1"
              positionOf (NodeId 1) order < positionOf (NodeId 2) order @? "1 before 2"
            Nothing -> assertFailure "expected acyclic"
      , testCase "topoSort detects cycle" $ do
          let g = fromEdges
                    [ (NodeId 0, NodeId 1, Weight 1)
                    , (NodeId 1, NodeId 0, Weight 1)
                    ]
          topoSort g @?= Nothing
      ]
  ]
  where
    positionOf x xs = length (takeWhile (/= x) xs)
