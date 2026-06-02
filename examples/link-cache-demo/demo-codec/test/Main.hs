module Main (main) where

import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy  as BSL

import Test.Tasty
import Test.Tasty.HUnit

import Demo.Codec.Frame
import Demo.Codec.Json
import Demo.Core.Types

main :: IO ()
main = defaultMain $ testGroup "demo-codec"
  [ testGroup "Json"
      [ testCase "roundtrip lit" $
          roundtripExpr (ELit (LInt 42))
      , testCase "roundtrip bin" $
          roundtripExpr (EBin OAdd (ELit (LInt 1)) (ELit (LInt 2)))
      , testCase "roundtrip if" $
          roundtripExpr (EIf (ELit (LBool True))
                              (ELit (LInt 10))
                              (ELit (LDbl 3.14)))
      , testCase "roundtrip nested" $
          roundtripExpr (EBin OMul
                          (EBin OAdd (ELit (LInt 2)) (ELit (LInt 3)))
                          (ELit (LInt 4)))
      ]
  , testGroup "Frame"
      [ testCase "encode/decode roundtrip" $ do
          let payloads = [ BSC.pack "hello"
                         , BS.empty
                         , BSC.pack "another payload"
                         , BS.pack (replicate 300 0x41)
                         ]
              encoded = encodeFrames payloads
          case decodeFrames encoded of
            Right got -> got @?= payloads
            Left  err -> assertFailure ("decode failed: " <> err)
      , testCase "empty input decodes to []" $
          decodeFrames mempty @?= Right []
      , testCase "truncated input fails" $
          case decodeFrames (BSL.fromStrict (BSC.pack "\0\0\0\5abc")) of
            Left  _  -> pure ()
            Right xs -> assertFailure ("expected failure, got " <> show xs)
      ]
  ]
  where
    roundtripExpr e =
      case decodeExpr (encodeExpr e) of
        Right e' -> e' @?= e
        Left err -> assertFailure ("decode failed: " <> err)
