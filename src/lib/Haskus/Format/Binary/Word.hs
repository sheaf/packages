{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MagicHash #-}

-- | Unsigned and signed words
module Haskus.Format.Binary.Word
   ( WordAtLeast
   , IntAtLeast
   -- * Some C types
   , CSize(..)
   , CUShort
   , CShort
   , CUInt
   , CInt
   , CULong
   , CLong
   -- * Unlifted
   , module GHC.Word
   , module GHC.Int
   , Word#
   , Int#
   , plusWord#
   , minusWord#
   , (+#)
   , (-#)
   , (==#)
   , (>#)
   , (<#)
   , (>=#)
   , (<=#)
   , ltWord#
   , leWord#
   , gtWord#
   , geWord#
   , eqWord#
   , isTrue#
   )
where

import Data.Word
import Data.Int
import Foreign.C.Types
import GHC.Word
import GHC.Int
import GHC.Exts

import Haskus.Utils.Types

-- | Return a Word with at least 'n' bits
type family WordAtLeast (n :: Nat) where
   WordAtLeast n =
       If (n <=? 8) Word8
      (If (n <=? 16) Word16
      (If (n <=? 32) Word32
      (If (n <=? 64) Word64
      (TypeError ('Text "Cannot find Word with size " ':<>: 'ShowType n))
      )))

-- | Return a Int with at least 'n' bits
type family IntAtLeast (n :: Nat) where
   IntAtLeast n =
       If (n <=? 8) Int8
      (If (n <=? 16) Int16
      (If (n <=? 32) Int32
      (If (n <=? 64) Int64
      (TypeError ('Text "Cannot find Int with size " ':<>: 'ShowType n))
      )))
