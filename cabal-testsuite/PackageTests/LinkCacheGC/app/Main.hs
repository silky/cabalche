module Main where

import Lib.M0 (x0)
import Lib.M1 (x1)
import Lib.M2 (x2)
import Lib.M3 (x3)

main :: IO ()
main = print (x0 + x1 + x2 + x3)
