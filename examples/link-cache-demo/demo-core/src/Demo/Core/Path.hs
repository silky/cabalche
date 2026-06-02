{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Demo.Core.Path
  ( Path
  , mkPath
  , pathSegments
  , renderPath
  , (</>)
  ) where

import Data.String (IsString (..))

-- | Slash-separated label path used by the graph layer. Wrapped in
-- a newtype so we can attach a smart constructor that normalises
-- away empty segments and trailing slashes.
newtype Path = Path { unPath :: String }
  deriving stock   (Show, Read)
  deriving newtype (Eq, Ord)

-- | Build a 'Path' from a raw string. Collapses runs of '/' and
-- drops leading/trailing separators.
mkPath :: String -> Path
mkPath = Path . normalise
  where
    normalise =
        intercalate "/"
      . filter (not . null)
      . splitOn '/'

instance IsString Path where
  fromString = mkPath

-- | Break a path back into its segments.
pathSegments :: Path -> [String]
pathSegments = splitOn '/' . unPath

-- | Render a 'Path' as a plain string with a leading slash.
renderPath :: Path -> String
renderPath p = '/' : unPath p

infixl 5 </>
-- | Append a string segment to a path, normalising as we go.
(</>) :: Path -> String -> Path
Path p </> s = mkPath (p <> "/" <> s)

splitOn :: Char -> String -> [String]
splitOn c = foldr step [[]]
  where
    step ch acc@(cur : rest)
      | ch == c   = [] : acc
      | otherwise = (ch : cur) : rest
    step _  []    = [[]]

intercalate :: String -> [String] -> String
intercalate _   []     = ""
intercalate _   [x]    = x
intercalate sep (x:xs) = x <> sep <> intercalate sep xs
