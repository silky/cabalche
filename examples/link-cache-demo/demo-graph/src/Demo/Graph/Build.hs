{-# LANGUAGE ScopedTypeVariables #-}

-- | Adjacency-list graph keyed by 'NodeId' with edge 'Weight's.
-- Construction goes through 'fromEdges' which enforces non-negative
-- weights and deduplicates parallel edges (keeping the minimum).
module Demo.Graph.Build
  ( Graph
  , empty
  , fromEdges
  , addEdge
  , edges
  , nodes
  , neighbours
  , size
  ) where

import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)

import Demo.Core.Types

-- | Adjacency representation. @adj ! u@ maps each successor to the
-- minimum edge weight between @u@ and that successor.
newtype Graph = Graph { adj :: Map NodeId (Map NodeId Weight) }
  deriving (Eq, Show)

empty :: Graph
empty = Graph Map.empty

-- | Build a 'Graph' from a flat edge list. Negative weights are
-- clamped to zero. Parallel edges are merged by taking the minimum
-- weight (a defensive convention for shortest-path-style consumers).
fromEdges :: [(NodeId, NodeId, Weight)] -> Graph
fromEdges = foldr step empty
  where
    step (u, v, w) g = addEdge u v (clamp w) g
    clamp w
      | w < Weight 0 = Weight 0
      | otherwise    = w

-- | Insert (or strengthen) a directed edge.
addEdge :: NodeId -> NodeId -> Weight -> Graph -> Graph
addEdge u v w (Graph m) =
  let bumpV = Map.insertWith min v w
      m'   = Map.insertWith (Map.unionWith min) u (Map.singleton v w) m
      -- Ensure the destination has an (empty) entry, so 'nodes'
      -- reports sinks too.
      m''  = Map.insertWith (\_ old -> old) v Map.empty m'
   in Graph (Map.adjust bumpV u m'')

-- | All edges in (u, v, w) form, sorted by source then target.
edges :: Graph -> [(NodeId, NodeId, Weight)]
edges (Graph m) =
  [ (u, v, w)
  | (u, vs) <- Map.toAscList m
  , (v, w)  <- Map.toAscList vs
  ]

-- | All nodes that appear as source or destination.
nodes :: Graph -> [NodeId]
nodes (Graph m) = Map.keys m

-- | Direct successors of a node (with edge weights).
neighbours :: NodeId -> Graph -> [(NodeId, Weight)]
neighbours u (Graph m) =
  maybe [] Map.toAscList (Map.lookup u m)

-- | Total number of edges.
size :: Graph -> Int
size = length . edges
