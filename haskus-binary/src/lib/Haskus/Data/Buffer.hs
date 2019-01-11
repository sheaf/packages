{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE UnboxedTuples #-}

module Haskus.Data.Buffer
   ( Buffer (..)
   , TypedBuffer (..)
   -- * Buffers taxonomy
   , Pinning (..)
   , Management (..)
   , Mutability (..)
   , BufferI
   , BufferP
   , BufferM
   , BufferMP
   , BufferE
   , BufferF
   , BufferPF
   , BufferMF
   , BufferMPF
   , BufferEF
   -- * Operations
   , newBuffer
   , newPinnedBuffer
   , newAlignedPinnedBuffer
   , withBufferAddr#
   , withBufferPtr
   , bufferSizeIO
   , BufferSize (..)
   , bufferToListIO
   , BufferToList (..)
   , bufferReadWord8IO
   , bufferWriteWord8IO
   -- * Finalizers
   , Finalizers
   , addFinalizer
   , makeFinalizable
   , touchBuffer
   -- * Reexport
   , module Control.Monad.Primitive
   )
where

import Haskus.Format.Binary.Word
import Haskus.Format.Binary.Storable
import Haskus.Format.Binary.Ptr
import Haskus.Utils.Monad

import qualified Data.Primitive.ByteArray as BA
import qualified Data.Primitive.Types     as BA
import Control.Monad.Primitive
import Data.IORef
import Unsafe.Coerce

import GHC.Prim
import GHC.Weak
import GHC.Exts (toList, IsList(..))
import GHC.Types (IO(..))

-- $setup
-- >>> :set -XDataKinds
-- >>> :set -XTypeApplications
-- >>> :set -XFlexibleContexts
-- >>> :set -XTypeFamilies

-- | Is the buffer pinned into memory?
data Pinning
   = Pinned
   | NotPinned
   deriving (Show,Eq)

-- | Is the buffer automatically garbage collected?
data Management
   = Managed    -- ^ GCed
   | Finalized  -- ^ Finalizers run just before GCing
   | NotManaged -- ^ Not managed at all
   deriving (Show,Eq)

-- | Allocation heap
data Heap
   = Internal -- ^ GHC heap
   | External -- ^ External heap

-- | Is the buffer mutable or not
data Mutability
   = Mutable   -- ^ Bytes are mutable
   | Immutable -- ^ Bytes are immutable
   deriving (Show,Eq)

data Buffer (mut :: Mutability) (pin :: Pinning) (gc :: Management) (heap :: Heap) where
   Buffer    :: BA.ByteArray                                -> Buffer 'Immutable 'NotPinned 'Managed    'Internal
   BufferP   :: BA.ByteArray                                -> Buffer 'Immutable 'Pinned    'Managed    'Internal
   BufferM   :: BA.MutableByteArray RealWorld               -> Buffer 'Mutable   'NotPinned 'Managed    'Internal
   BufferMP  :: BA.MutableByteArray RealWorld               -> Buffer 'Mutable   'Pinned    'Managed    'Internal
   BufferE   :: Addr# -> Word                               -> Buffer 'Mutable   'Pinned    'NotManaged 'External
   BufferF   :: BA.ByteArray                  -> Finalizers -> Buffer 'Immutable 'NotPinned 'Finalized  'Internal
   BufferPF  :: BA.ByteArray                  -> Finalizers -> Buffer 'Immutable 'Pinned    'Finalized  'Internal
   BufferMF  :: BA.MutableByteArray RealWorld -> Finalizers -> Buffer 'Mutable   'NotPinned 'Finalized  'Internal
   BufferMPF :: BA.MutableByteArray RealWorld -> Finalizers -> Buffer 'Mutable   'Pinned    'Finalized  'Internal
   BufferEF  :: Addr# -> Word                 -> Finalizers -> Buffer 'Mutable   'Pinned    'Finalized  'External

type BufferI   = Buffer 'Immutable 'NotPinned 'Managed     'Internal
type BufferP   = Buffer 'Immutable 'Pinned    'Managed     'Internal
type BufferM   = Buffer 'Mutable   'NotPinned 'Managed     'Internal
type BufferMP  = Buffer 'Mutable   'Pinned    'Managed     'Internal
type BufferE   = Buffer 'Mutable   'Pinned    'NotManaged  'External
type BufferF   = Buffer 'Immutable 'NotPinned 'Finalized   'Internal
type BufferPF  = Buffer 'Immutable 'Pinned    'Finalized   'Internal
type BufferMF  = Buffer 'Mutable   'NotPinned 'Finalized   'Internal
type BufferMPF = Buffer 'Mutable   'Pinned    'Finalized   'Internal
type BufferEF  = Buffer 'Mutable   'Pinned    'Finalized   'External

-- | A buffer with an additional phantom type indicating its binary format
newtype TypedBuffer (t :: k) mut pin gc heap = TypedBuffer (Buffer mut pin gc heap)

-----------------------------------------------------------------
-- Allocation
-----------------------------------------------------------------

-- | Allocate a buffer (mutable, unpinned)
newBuffer :: MonadIO m => Word -> m BufferM
newBuffer sz = BufferM <$> liftIO (BA.newByteArray (fromIntegral sz))

-- | Allocate a buffer (mutable, pinned)
newPinnedBuffer :: MonadIO m => Word -> m BufferMP
newPinnedBuffer sz = BufferMP <$> liftIO (BA.newPinnedByteArray (fromIntegral sz))

-- | Allocate an aligned buffer (mutable, pinned)
newAlignedPinnedBuffer :: MonadIO m => Word -> Word -> m BufferMP
newAlignedPinnedBuffer sz al = BufferMP <$> liftIO (BA.newAlignedPinnedByteArray (fromIntegral sz) (fromIntegral al))

-----------------------------------------------------------------
-- Finalizers
-----------------------------------------------------------------

newtype Finalizers = Finalizers (IORef [IO ()])

-- | Insert a finalizer. Return True if there was no finalizer before
insertFinalizer :: Finalizers -> IO () -> IO Bool
insertFinalizer (Finalizers rfs) f = do
  atomicModifyIORef rfs $ \finalizers -> case finalizers of
    [] -> ([f] , True)
    fs -> (f:fs, False)

-- | Add a finalizer.
addFinalizer :: Buffer mut pin 'Finalized heap -> IO () -> IO ()
addFinalizer b f = case b of
   BufferEF _addr _sz fin@(Finalizers rfs) -> do
      wasEmpty <- insertFinalizer fin f
      -- add the weak reference to the finalizer IORef (not to Addr#)
      when wasEmpty $ void $ mkWeakIORef rfs (runFinalizers fin)

   BufferF ba fin -> do
      wasEmpty <- insertFinalizer fin f
      -- add the weak reference to the ByteArray
      when wasEmpty $ void $ mkWeak ba () (Just (runFinalizers fin))

   BufferPF ba fin -> do
      wasEmpty <- insertFinalizer fin f
      -- add the weak reference to the ByteArray
      when wasEmpty $ void $ mkWeak ba () (Just (runFinalizers fin))

   BufferMF ba fin -> do
      wasEmpty <- insertFinalizer fin f
      -- add the weak reference to the MutableByteArray
      when wasEmpty $ void $ mkWeak ba () (Just (runFinalizers fin))

   BufferMPF ba fin -> do
      wasEmpty <- insertFinalizer fin f
      -- add the weak reference to the MutableByteArray
      when wasEmpty $ void $ mkWeak ba () (Just (runFinalizers fin))

-- | Internal function used to execute finalizers
runFinalizers :: Finalizers -> IO ()
runFinalizers (Finalizers rfs) = do
   -- atomically remove finalizers to avoid double execution
   fs <- atomicModifyIORef rfs $ \fs -> ([], fs)
   sequence_ fs

-- | Create empty Finalizers
newFinalizers :: IO Finalizers
newFinalizers = Finalizers <$> newIORef []

-- | Touch a buffer
touchBuffer :: MonadIO m => Buffer mut pin gc heap -> m ()
touchBuffer (Buffer    ba                        ) = liftIO $ touch ba
touchBuffer (BufferP   ba                        ) = liftIO $ touch ba
touchBuffer (BufferM   ba                        ) = liftIO $ touch ba
touchBuffer (BufferMP  ba                        ) = liftIO $ touch ba
touchBuffer (BufferF   ba         _fin           ) = liftIO $ touch ba
touchBuffer (BufferPF  ba         _fin           ) = liftIO $ touch ba
touchBuffer (BufferMF  ba         _fin           ) = liftIO $ touch ba
touchBuffer (BufferMPF ba         _fin           ) = liftIO $ touch ba
touchBuffer (BufferE   _addr _sz                 ) = return ()
touchBuffer (BufferEF  _addr _sz (Finalizers fin)) = liftIO $ touch fin

-- | Make a buffer finalizable
--
-- The new buffer liveness is used to trigger finalizers.
--
makeFinalizable :: Buffer mut pin f heap -> IO (Buffer mut pin 'Finalized heap)
makeFinalizable (BufferE addr sz) = BufferEF  addr sz <$> newFinalizers
makeFinalizable (Buffer  ba  )    = BufferF   ba      <$> newFinalizers
makeFinalizable (BufferP ba  )    = BufferPF  ba      <$> newFinalizers
makeFinalizable (BufferM ba  )    = BufferMF  ba      <$> newFinalizers
makeFinalizable (BufferMP ba )    = BufferMPF ba      <$> newFinalizers
makeFinalizable x@(BufferF {})    = return x
makeFinalizable x@(BufferEF {})   = return x
makeFinalizable x@(BufferPF {})   = return x
makeFinalizable x@(BufferMF {})   = return x
makeFinalizable x@(BufferMPF {})  = return x


-- | Do something with a buffer address
--
-- Note: don't write into immutable buffer as it would break referential
-- consistency
withBufferAddr# :: Buffer mut 'Pinned gc heap -> (Addr# -> IO a) -> IO a
withBufferAddr# b@(BufferP ba) f = do
   let !(BA.Addr addr) = BA.byteArrayContents ba
   r <- f addr
   touch b
   return r
withBufferAddr# b@(BufferMP ba) f = do
   let !(BA.Addr addr) = BA.mutableByteArrayContents ba
   r <- f addr
   touch b
   return r
withBufferAddr# b@(BufferPF ba _fin) f = do
   let !(BA.Addr addr) = BA.byteArrayContents ba
   r <- f addr
   touch b
   return r
withBufferAddr# b@(BufferMPF ba _fin) f = do
   let !(BA.Addr addr) = BA.mutableByteArrayContents ba
   r <- f addr
   touch b
   return r
withBufferAddr# (BufferE addr _sz)         f = f (addr)
withBufferAddr# b@(BufferEF addr _sz _fin) f = do
   r <- f addr
   touch b
   return r

-- | Do something with a buffer pointer
--
-- Note: don't write into immutable buffer as it would break referential
-- consistency
withBufferPtr :: Buffer mut 'Pinned gc heap -> (Ptr b -> IO a) -> IO a
withBufferPtr b f = withBufferAddr# b g
   where
      g addr = f (Ptr addr)


-- | Get buffer size
bufferSizeIO :: MonadIO m => Buffer mut pin gc heap -> m Word
bufferSizeIO = \case
   BufferM ba             -> fromIntegral <$> liftIO (BA.getSizeofMutableByteArray ba)
   BufferMP ba            -> fromIntegral <$> liftIO (BA.getSizeofMutableByteArray ba)
   BufferMF  ba _fin      -> fromIntegral <$> liftIO (BA.getSizeofMutableByteArray ba)
   BufferMPF ba _fin      -> fromIntegral <$> liftIO (BA.getSizeofMutableByteArray ba)
   BufferE  _addr sz      -> return sz
   BufferEF _addr sz _fin -> return sz
   Buffer  ba             -> return $ fromIntegral $ BA.sizeofByteArray ba
   BufferP ba             -> return $ fromIntegral $ BA.sizeofByteArray ba
   BufferF   ba _fin      -> return $ fromIntegral $ BA.sizeofByteArray ba
   BufferPF  ba _fin      -> return $ fromIntegral $ BA.sizeofByteArray ba

class BufferSize a where
   -- |  Get buffer size
   bufferSize :: a -> Word

instance BufferSize BufferI where
   bufferSize (Buffer ba)  = fromIntegral $ BA.sizeofByteArray ba
instance BufferSize BufferP where
   bufferSize (BufferP ba) = fromIntegral $ BA.sizeofByteArray ba
instance BufferSize BufferF where
   bufferSize (BufferF ba _fin)  = fromIntegral $ BA.sizeofByteArray ba
instance BufferSize BufferPF where
   bufferSize (BufferPF ba _fin) = fromIntegral $ BA.sizeofByteArray ba
instance BufferSize BufferE where
   bufferSize (BufferE _addr sz) = sz
instance BufferSize BufferEF where
   bufferSize (BufferEF _addr sz _fin) = sz

-- | Get contents as a list of bytes
bufferToListIO :: MonadIO m => Buffer mut pin gc heap -> m [Word8]
bufferToListIO = \case
   Buffer  ba             -> return (toList ba)
   BufferP ba             -> return (toList ba)
   BufferF   ba _fin      -> return (toList ba)
   BufferPF  ba _fin      -> return (toList ba)
   BufferM ba             -> return (toList (unsafeCoerce ba :: BA.ByteArray))
   BufferMP ba            -> return (toList (unsafeCoerce ba :: BA.ByteArray))
   BufferMF  ba _fin      -> return (toList (unsafeCoerce ba :: BA.ByteArray))
   BufferMPF ba _fin      -> return (toList (unsafeCoerce ba :: BA.ByteArray))
   BufferE  addr sz       -> peekArray sz (Ptr addr)
   BufferEF addr sz _fin  -> peekArray sz (Ptr addr)

class BufferToList a where
   -- | Get contents as a list of bytes
   bufferToList :: a -> [Word8]

instance BufferToList BufferI where
   bufferToList (Buffer ba) = toList ba
instance BufferToList BufferP where
   bufferToList (BufferP ba) = toList ba
instance BufferToList BufferF where
   bufferToList (BufferF ba _fin) = toList ba
instance BufferToList BufferPF where
   bufferToList (BufferPF ba _fin) = toList ba

-- | Support for OverloadedLists
--
-- >>> :set -XOverloadedLists
-- >>> let b = [25,26,27,28] :: BufferI
--
instance IsList BufferI where
   type Item BufferI  = Word8
   toList (Buffer ba) = toList ba
   fromList xs        = Buffer (fromList xs)
   fromListN sz xs    = Buffer (fromListN sz xs)


-- | Read a Word8, offset in bytes
--
-- We don't check that the offset is valid
--
-- >>> let b = [25,26,27,28] :: BufferI
-- >>> bufferReadWord8IO b 2 
-- 27
--
bufferReadWord8IO :: MonadIO m => Buffer mut pin gc heap -> Word -> m Word8
bufferReadWord8IO b (fromIntegral -> !(I# off)) = case b of
   BufferM (BA.MutableByteArray ba)          -> liftIO $ IO $ \s -> case readWord8Array# ba off s of (# s2 , r #) -> (# s2 , W8# r #)
   BufferMP (BA.MutableByteArray ba)         -> liftIO $ IO $ \s -> case readWord8Array# ba off s of (# s2 , r #) -> (# s2 , W8# r #)
   BufferMF  (BA.MutableByteArray ba) _fin   -> liftIO $ IO $ \s -> case readWord8Array# ba off s of (# s2 , r #) -> (# s2 , W8# r #)
   BufferMPF (BA.MutableByteArray ba) _fin   -> liftIO $ IO $ \s -> case readWord8Array# ba off s of (# s2 , r #) -> (# s2 , W8# r #)
   BufferE  addr _sz                         -> return (W8# (indexWord8OffAddr# addr off))
   BufferEF addr _sz _fin                    -> return (W8# (indexWord8OffAddr# addr off))
   Buffer  (BA.ByteArray ba)                 -> return (W8# (indexWord8Array# ba off))
   BufferP (BA.ByteArray ba)                 -> return (W8# (indexWord8Array# ba off))
   BufferF   (BA.ByteArray ba) _fin          -> return (W8# (indexWord8Array# ba off))
   BufferPF  (BA.ByteArray ba) _fin          -> return (W8# (indexWord8Array# ba off))

-- | Write a Word8, offset in bytes
--
-- We don't check that the offset is valid
--
-- >>> b <- newBuffer 10
-- >>> bufferWriteWord8IO b 1 123
-- >>> bufferReadWord8IO b 1 
-- 123
--
bufferWriteWord8IO :: MonadIO m => Buffer 'Mutable pin gc heap -> Word -> Word8 -> m ()
bufferWriteWord8IO b (fromIntegral -> !(I# off)) (W8# v) = case b of
   BufferM (BA.MutableByteArray ba)          -> liftIO $ IO $ \s -> case writeWord8Array# ba off v s of s2 -> (# s2 , () #)
   BufferMP (BA.MutableByteArray ba)         -> liftIO $ IO $ \s -> case writeWord8Array# ba off v s of s2 -> (# s2 , () #)
   BufferMF  (BA.MutableByteArray ba) _fin   -> liftIO $ IO $ \s -> case writeWord8Array# ba off v s of s2 -> (# s2 , () #)
   BufferMPF (BA.MutableByteArray ba) _fin   -> liftIO $ IO $ \s -> case writeWord8Array# ba off v s of s2 -> (# s2 , () #)
   BufferE  addr _sz                         -> liftIO $ IO $ \s -> case writeWord8OffAddr# addr off v s of s2 -> (# s2 , () #)
   BufferEF addr _sz _fin                    -> liftIO $ IO $ \s -> case writeWord8OffAddr# addr off v s of s2 -> (# s2 , () #)

