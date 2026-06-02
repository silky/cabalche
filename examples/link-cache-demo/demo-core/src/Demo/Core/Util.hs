{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Small folds and traversals used by the higher-level packages.
-- This module is the canonical target of the link-cache bench
-- script: edits here cascade through demo-codec, demo-graph,
-- demo-engine, and demo-app.
module Demo.Core.Util
  ( foldStrict
  , every
  , groupRuns
  , normaliseList
  , describe
  ) where

import Data.Foldable (foldl')

-- | Strict left fold over any 'Foldable'.
foldStrict :: Foldable t => (b -> a -> b) -> b -> t a -> b
foldStrict f z xs = foldl' f z xs
{-# INLINE foldStrict #-}

-- | True iff every element satisfies the predicate.
every :: Foldable t => (a -> Bool) -> t a -> Bool
every p = foldStrict (\(!acc) x -> acc && p x) True

-- | Group adjacent equal elements into runs.
groupRuns :: Eq a => [a] -> [[a]]
groupRuns []     = []
groupRuns (x:xs) =
  let (run, rest) = span (== x) xs
   in (x : run) : groupRuns rest

-- | Collapse adjacent duplicates and drop empty groups.
normaliseList :: Eq a => [a] -> [a]
normaliseList = map firstOf . filter nonempty . groupRuns
  where
    firstOf (h : _) = h
    firstOf []      = error "normaliseList: groupRuns produced empty group"
    nonempty []     = False
    nonempty _      = True

-- | One-line description of any 'Show'able value. Exposed so the
-- bench script's modify-type scenario has a stable target.
describe :: Show a => a -> String
describe x = "value=" <> show x
