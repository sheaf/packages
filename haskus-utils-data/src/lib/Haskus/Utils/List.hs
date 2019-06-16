module Haskus.Utils.List
   ( checkLength
   , (++)
   , replicate
   , drop
   , length
   , take
   , chunksOf
   , pick1
   , L.partition
   , L.nub
   , L.sort
   , L.intersperse
   , L.foldl'
   , L.head
   , L.tail
   , L.zipWith
   , L.repeat
   , L.nubOn
   , L.nubBy
   , L.sortOn
   , L.sortBy
   , L.split
   , L.splitOn
   , L.groupOn
   , L.groupBy
   , L.transpose
   , (L.\\)
   , L.intersect
   , L.find
   , L.zip3
   , L.zip4
   , L.stripPrefix
   , L.isPrefixOf
   , L.deleteBy
   , L.isSuffixOf
   )
where

import Prelude hiding (replicate, length, drop, take)

import qualified Data.List as L
import qualified Data.List.Extra as L

-- | Check that a list has the given length (support infinite lists)
checkLength :: Word -> [a] -> Bool
checkLength 0 []     = True
checkLength 0 _      = False
checkLength _ []     = False
checkLength i (_:xs) = checkLength (i-1) xs

-- | Replicate
replicate :: Word -> a -> [a]
replicate n a = L.replicate (fromIntegral n) a

-- | Take
take :: Word -> [a] -> [a]
take n = L.take (fromIntegral n)

-- | Length
length :: Foldable t => t a -> Word
length = fromIntegral . L.length

-- | Drop
drop :: Word -> [a] -> [a]
drop n = L.drop (fromIntegral n)

-- | Split a list into chunks of a given size. The last chunk may contain fewer
-- than n elements.
chunksOf :: Word -> [a] -> [[a]]
chunksOf n = L.chunksOf (fromIntegral n)


-- | Pick each element and return the element and the rest of the list
--
-- >>> pick1 [1,2,3,4]
-- [(1,[2,3,4]),(2,[1,3,4]),(3,[1,2,4]),(4,[1,2,3])]
pick1 :: [a] -> [(a,[a])]
pick1 = go []
   where
      go _  []     = []
      go ys (x:xs) = (x,reverse ys++xs) : go (x:ys) xs
