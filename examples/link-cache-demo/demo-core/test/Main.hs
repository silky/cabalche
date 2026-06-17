module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit

import Demo.Core.Path
import Demo.Core.Types
import Demo.Core.Util

main :: IO ()
main = defaultMain $ testGroup "demo-core"
  [ testGroup "Util"
      [ testCase "every on []" $
          every (const False) ([] :: [Int]) @?= True
      , testCase "every on [1,2,3]" $
          every (> 0) [1, 2, 3 :: Int] @?= True
      , testCase "groupRuns simple" $
          groupRuns "aaabbc" @?= ["aaa", "bb", "c"]
      , testCase "normaliseList collapses dups" $
          normaliseList "aaabbc" @?= "abc"
      , testCase "describe formats" $
          describe (42 :: Int) @?= "value=42"
      ]
  , testGroup "Path"
      [ testCase "mkPath collapses slashes" $
          renderPath (mkPath "//a//b///c/") @?= "/a/b/c"
      , testCase "(</>) appends segments" $
          renderPath (mkPath "a" </> "b" </> "c") @?= "/a/b/c"
      , testCase "pathSegments splits" $
          pathSegments (mkPath "a/b/c") @?= ["a", "b", "c"]
      ]
  , testGroup "Types"
      [ testCase "evalExpr simple add" $
          evalExpr (EBin OAdd (ELit (LInt 2)) (ELit (LInt 3)))
            @?= LInt 5
      , testCase "evalExpr if true" $
          evalExpr
            (EIf (ELit (LBool True))
                 (ELit (LInt 1))
                 (ELit (LInt 2)))
            @?= LInt 1
      , testCase "depthOf nested" $
          depthOf (EIf (ELit (LBool True))
                       (EBin OAdd (ELit (LInt 1)) (ELit (LInt 2)))
                       (ELit (LInt 0)))
            @?= 2
      ]
  ]
