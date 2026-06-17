module Main where

import Lib.A (a)
import Lib.B (b)
import Lib.C (c)

main :: IO ()
main = print (a + b + c)
