{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | DFS, reachability, and topological sort over 'Graph'.
module Demo.Graph.Traverse
  ( dfsFrom
  , reachable
  , topoSort
  , isAcyclic
  ) where

import           Control.Monad             (foldM, unless, when)
import           Control.Monad.State.Strict (State, evalState, gets, modify')
import qualified Data.Map.Strict           as Map
import qualified Data.Set                  as Set
import           Data.Set                  (Set)

import Demo.Core.Types
import Demo.Core.Util  (foldStrict)
import Demo.Graph.Build

-- | Depth-first traversal returning nodes in visit order.
dfsFrom :: NodeId -> Graph -> [NodeId]
dfsFrom start g = reverse (evalState (go start) Set.empty)
  where
    go :: NodeId -> State (Set NodeId) [NodeId]
    go u = do
      seen <- gets (Set.member u)
      if seen
        then gets Set.toList >>= \_ -> pure []
        else do
          modify' (Set.insert u)
          rec' <- traverse (\(v, _) -> go v) (neighbours u g)
          pure (u : concat rec')

-- | Set of nodes reachable from a source (inclusive).
reachable :: NodeId -> Graph -> Set NodeId
reachable start g = execDfs start g

execDfs :: NodeId -> Graph -> Set NodeId
execDfs start g = snd (foldStrict step (Set.empty, Set.empty) (dfsFrom start g))
  where
    step (queued, visited) n
      | Set.member n visited = (queued, visited)
      | otherwise            = (queued, Set.insert n visited)

-- | Kahn-style topological sort. 'Nothing' on a cyclic graph.
topoSort :: Graph -> Maybe [NodeId]
topoSort g = evalState (kahn roots) initial
  where
    inDegree :: Map.Map NodeId Int
    inDegree = foldStrict bumpFrom (Map.fromList (map (, 0) (nodes g))) (edges g)
      where
        bumpFrom acc (_, v, _) = Map.insertWith (+) v 1 acc

    roots = [ n | (n, 0) <- Map.toAscList inDegree ]

    initial = inDegree

    kahn :: [NodeId] -> State (Map.Map NodeId Int) (Maybe [NodeId])
    kahn []     = do
      remaining <- gets (Map.filter (> 0))
      if Map.null remaining
        then pure (Just [])
        else pure Nothing
    kahn (u:us) = do
      let succs = map fst (neighbours u g)
      newRoots <- foldM bump [] succs
      rest <- kahn (us ++ reverse newRoots)
      pure ((u :) <$> rest)
      where
        bump acc v = do
          d <- gets (Map.findWithDefault 0 v)
          let d' = d - 1
          modify' (Map.insert v d')
          pure (if d' == 0 then v : acc else acc)

isAcyclic :: Graph -> Bool
isAcyclic = maybe False (const True) . topoSort
