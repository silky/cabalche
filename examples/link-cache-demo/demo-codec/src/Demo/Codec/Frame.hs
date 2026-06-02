{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Length-prefixed binary frame format. Each frame is
--
--    [4-byte big-endian length] [payload bytes]
--
-- The codec is deliberately hand-rolled rather than 'binary' / 'cereal'
-- to keep the dependency closure small while still demonstrating
-- non-trivial bytestring work.
module Demo.Codec.Frame
  ( encodeFrames
  , decodeFrames
  ) where

import           Data.Bits             (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy    as BSL
import           Data.Word             (Word32)

-- | Encode a list of payloads to a single lazy bytestring of
-- length-prefixed frames.
encodeFrames :: [BS.ByteString] -> BSL.ByteString
encodeFrames = BB.toLazyByteString . mconcat . map oneFrame
  where
    oneFrame bs =
      let n = fromIntegral (BS.length bs) :: Word32
       in word32BE n <> BB.byteString bs

word32BE :: Word32 -> BB.Builder
word32BE w =
     BB.word8 (fromIntegral ((w `shiftR` 24) .&. 0xff))
  <> BB.word8 (fromIntegral ((w `shiftR` 16) .&. 0xff))
  <> BB.word8 (fromIntegral ((w `shiftR`  8) .&. 0xff))
  <> BB.word8 (fromIntegral ( w              .&. 0xff))

-- | Decode a stream of length-prefixed frames. Returns the parsed
-- payloads in order, or 'Left' on a truncated input.
decodeFrames :: BSL.ByteString -> Either String [BS.ByteString]
decodeFrames = go [] . BSL.toStrict
  where
    go acc bs
      | BS.null bs = Right (reverse acc)
      | BS.length bs < 4 = Left "frame: truncated length prefix"
      | otherwise =
          let (lenBytes, rest) = BS.splitAt 4 bs
              n = fromBE lenBytes
              nI = fromIntegral n
           in if BS.length rest < nI
                then Left "frame: truncated payload"
                else let (payload, rest') = BS.splitAt nI rest
                      in go (payload : acc) rest'

fromBE :: BS.ByteString -> Word32
fromBE bs = case BS.unpack bs of
  [b0, b1, b2, b3] ->
        (fromIntegral b0 `shiftL` 24)
    .|. (fromIntegral b1 `shiftL` 16)
    .|. (fromIntegral b2 `shiftL`  8)
    .|.  fromIntegral b3
  _ -> 0
