{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
-- |
-- Module      : Data.Massiv.Array.Delayed.Push
-- Copyright   : (c) Alexey Kuleshevich 2019
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Data.Massiv.Array.Delayed.Push
  ( DL(..)
  , Array(..)
  , toLoadArray
  , makeLoadArrayS
  , makeLoadArray
  , unsafeMakeLoadArray
  , unsafeMakeLoadArrayAdjusted
  , fromStrideLoad
  , appendOuterM
  , concatOuterM
  ) where

import Control.Monad
import Control.Scheduler as S (traverse_)
import Data.Foldable as F
import Data.Massiv.Core.Common
import Prelude hiding (map, zipWith)

#include "massiv.h"

-- | Delayed load representation. Also known as Push array.
data DL = DL deriving Show


data instance Array DL ix e = DLArray
  { dlComp    :: !Comp
  , dlSize    :: !(Sz ix)
  , dlLoad    :: forall m . Monad m
              => Scheduler m ()
              -> Ix1 -- start loading at this linear index
              -> (Ix1 -> e -> m ()) -- linear element writing action
              -> (Ix1 -> Sz1 -> e -> m ()) -- linear region setting action
              -> m ()
  }

instance Index ix => Construct DL ix e where
  setComp c arr = arr {dlComp = c}
  {-# INLINE setComp #-}
  makeArrayLinear comp sz f = DLArray comp sz load
    where
      load :: Monad m =>
        Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
      load scheduler startAt dlWrite _ =
        splitLinearlyWithStartAtM_ scheduler startAt (totalElem sz) (pure . f) dlWrite
      {-# INLINE load #-}
  {-# INLINE makeArrayLinear #-}

instance Index ix => Resize DL ix where
  unsafeResize !sz arr = arr { dlSize = sz }
  {-# INLINE unsafeResize #-}

instance Semigroup (Array DL Ix1 e) where
  (<>) = mappendDL
  {-# INLINE (<>) #-}

instance Monoid (Array DL Ix1 e) where
  mempty = DLArray {dlComp = mempty, dlSize = zeroSz, dlLoad = \_ _ _ _ -> pure ()}
  {-# INLINE mempty #-}
  mappend = mappendDL
  {-# INLINE mappend #-}
  mconcat [] = mempty
  mconcat [x] = x
  mconcat [x, y] = x <> y
  mconcat xs = mconcatDL xs
  {-# INLINE mconcat #-}

mconcatDL :: forall e . [Array DL Ix1 e] -> Array DL Ix1 e
mconcatDL !arrs =
  DLArray {dlComp = foldMap getComp arrs, dlSize = SafeSz k, dlLoad = load}
  where
    !k = F.foldl' (+) 0 (unSz . size <$> arrs)
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler startAt dlWrite dlSet =
      let loadArr !startAtCur DLArray {dlSize = SafeSz kCur, dlLoad} = do
            let !endAtCur = startAtCur + kCur
            scheduleWork_ scheduler $ dlLoad scheduler startAtCur dlWrite dlSet
            pure endAtCur
          {-# INLINE loadArr #-}
       in foldM_ loadArr startAt arrs
    {-# INLINE load #-}
{-# INLINE mconcatDL #-}


mappendDL :: forall e . Array DL Ix1 e -> Array DL Ix1 e -> Array DL Ix1 e
mappendDL (DLArray c1 sz1 load1) (DLArray c2 sz2 load2) =
  DLArray {dlComp = c1 <> c2, dlSize = SafeSz (k1 + k2), dlLoad = load}
  where
    !k1 = unSz sz1
    !k2 = unSz sz2
    load :: Monad n =>
      Scheduler n () -> Ix1 -> (Ix1 -> e -> n ()) -> (Ix1 -> Sz1 -> e -> n ()) -> n ()
    load scheduler !startAt dlWrite dlSet = do
      scheduleWork_ scheduler $ load1 scheduler startAt dlWrite dlSet
      scheduleWork_ scheduler $ load2 scheduler (startAt + k1) dlWrite dlSet
    {-# INLINE load #-}
{-# INLINE mappendDL #-}

-- | Append two arrays together along the outer most dimension. Inner dimensions must
-- agree, otherwise `SizeMismatchException`.
--
-- @since 0.4.4
appendOuterM ::
     forall ix e m. (Index ix, MonadThrow m)
  => Array DL ix e
  -> Array DL ix e
  -> m (Array DL ix e)
appendOuterM (DLArray c1 sz1 load1) (DLArray c2 sz2 load2) = do
  let (!i1, !szl1) = unconsSz sz1
      (!i2, !szl2) = unconsSz sz2
  unless (szl1 == szl2) $ throwM $ SizeMismatchException sz1 sz2
  pure $
    DLArray {dlComp = c1 <> c2, dlSize = consSz (i1 + i2) szl1, dlLoad = load}
  where
    load :: Monad n => Scheduler n () -> Ix1 -> (Ix1 -> e -> n ()) -> (Ix1 -> Sz1 -> e -> n ()) -> n ()
    load scheduler !startAt dlWrite dlSet = do
      scheduleWork_ scheduler $ load1 scheduler startAt dlWrite dlSet
      scheduleWork_ scheduler $ load2 scheduler (startAt + totalElem sz1) dlWrite dlSet
    {-# INLINE load #-}
{-# INLINE appendOuterM #-}

-- | Concat arrays together along the outer most dimension. Inner dimensions must agree
-- for all arrays in the list, otherwise `SizeMismatchException`.
--
-- @since 0.4.4
concatOuterM ::
     forall ix e m. (Index ix, MonadThrow m)
  => [Array DL ix e]
  -> m (Array DL ix e)
concatOuterM =
  \case
    []     -> pure empty
    (x:xs) -> F.foldlM appendOuterM x xs
{-# INLINE concatOuterM #-}


-- | Describe how an array should be loaded into memory sequentially. For parallelizable
-- version see `makeLoadArray`.
--
-- @since 0.3.1
makeLoadArrayS ::
     forall ix e. Index ix
  => Sz ix
  -- ^ Size of the resulting array
  -> e
  -- ^ Default value to use for all cells that might have been ommitted by the writing function
  -> (forall m. Monad m => (ix -> e -> m Bool) -> m ())
  -- ^ Writing function that described which elements to write into the target array.
  -> Array DL ix e
makeLoadArrayS sz defVal writer = DLArray Seq sz load
  where
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load _scheduler !startAt uWrite uSet = do
      uSet startAt (toLinearSz sz) defVal
      let safeWrite !ix !e
            | isSafeIndex sz ix = uWrite (startAt + toLinearIndex sz ix) e >> pure True
            | otherwise = pure False
          {-# INLINE safeWrite #-}
      writer safeWrite
    {-# INLINE load #-}
{-# INLINE makeLoadArrayS #-}

-- | Specify how an array should be loaded into memory. Unlike `makeLoadArrayS`, loading
-- function accepts a scheduler, thus can be parallelized. If you need an unsafe version
-- of this function see `unsafeMakeLoadArray`.
--
-- @since 0.4.0
makeLoadArray ::
     forall ix e. Index ix
  => Comp
  -- ^ Computation strategy to use. Directly affects the scheduler that gets created for
  -- the loading function.
  -> Sz ix
  -- ^ Size of the resulting array
  -> e
  -- ^ Default value to use for all cells that might have been ommitted by the writing function
  -> (forall m. Monad m => Scheduler m () -> (ix -> e -> m Bool) -> m ())
  -- ^ Writing function that described which elements to write into the target array. It
  -- accepts a scheduler, that can be used for parallelization, as well as a safe element
  -- writing function.
  -> Array DL ix e
makeLoadArray comp sz defVal writer = DLArray comp sz load
  where
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler !startAt uWrite uSet = do
      uSet startAt (toLinearSz sz) defVal
      let safeWrite !ix !e
            | isSafeIndex sz ix = True <$ uWrite (startAt + toLinearIndex sz ix) e
            | otherwise = pure False
          {-# INLINE safeWrite #-}
      writer scheduler safeWrite
    {-# INLINE load #-}
{-# INLINE makeLoadArray #-}

-- | Specify how an array can be loaded/computed through creation of a `DL` array. Unlike
-- `makeLoadArrayS` or `makeLoadArray` this function is unsafe, since there is no
-- guarantee that all elements will be initialized and the supplied element writing
-- function does not perform any bounds checking.
--
-- @since 0.3.1
unsafeMakeLoadArray ::
     forall ix e. Index ix
  => Comp
  -- ^ Computation strategy to use. Directly affects the scheduler that gets created for
  -- the loading function.
  -> Sz ix
  -- ^ Size of the array
  -> Maybe e
  -- ^ An element to use for initialization of the mutable array that will be created in
  -- the future
  -> (forall m. Monad m => Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> m ())
  -- ^ This function accepts:
  --
  -- * A scheduler that can be used for parallelization of loading
  --
  -- * Linear index at which this load array will start (an offset that should be added to
  --   the linear writng function)
  --
  -- * Linear element writing function
  -> Array DL ix e
unsafeMakeLoadArray comp sz mDefVal writer = DLArray comp sz load
  where
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler startAt uWrite uSet = do
      S.traverse_ (uSet startAt (toLinearSz sz)) mDefVal
      writer scheduler startAt uWrite
    {-# INLINE load #-}
{-# INLINE unsafeMakeLoadArray #-}

-- | Same as `unsafeMakeLoadArray`, except will ensure that starting index is correctly
-- adjusted. Which means the writing function gets one less argument.
--
-- @since 0.5.2
unsafeMakeLoadArrayAdjusted ::
     forall ix e. Index ix
  => Comp
  -> Sz ix
  -> Maybe e
  -> (forall m. Monad m => Scheduler m () -> (Ix1 -> e -> m ()) -> m ())
  -> Array DL ix e
unsafeMakeLoadArrayAdjusted comp sz mDefVal writer = DLArray comp sz load
  where
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler !startAt uWrite dlSet = do
      S.traverse_ (dlSet startAt (toLinearSz sz)) mDefVal
      writer scheduler (\i -> uWrite (startAt + i))
    {-# INLINE load #-}
{-# INLINE unsafeMakeLoadArrayAdjusted #-}

-- | Convert any `Load`able array into `DL` representation.
--
-- @since 0.3.0
toLoadArray ::
     forall r ix e. Load r ix e
  => Array r ix e
  -> Array DL ix e
toLoadArray arr = DLArray (getComp arr) sz load
  where
    !sz = size arr
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler !startAt dlWrite dlSet =
      loadArrayWithSetM scheduler arr (dlWrite . (+ startAt)) (\offset -> dlSet (offset + startAt))
    {-# INLINE load #-}
{-# INLINE[1] toLoadArray #-}
{-# RULES "toLoadArray/id" toLoadArray = id #-}

-- | Convert an array that can be loaded with stride into `DL` representation.
--
-- @since 0.3.0
fromStrideLoad ::
     forall r ix e. StrideLoad r ix e
  => Stride ix
  -> Array r ix e
  -> Array DL ix e
fromStrideLoad stride arr =
  DLArray (getComp arr) newsz load
  where
    !newsz = strideSize stride (size arr)
    load :: Monad m =>
      Scheduler m () -> Ix1 -> (Ix1 -> e -> m ()) -> (Ix1 -> Sz1 -> e -> m ()) -> m ()
    load scheduler !startAt dlWrite _ =
      loadArrayWithStrideM scheduler stride newsz arr (\ !i -> dlWrite (i + startAt))
    {-# INLINE load #-}
{-# INLINE fromStrideLoad #-}

instance Index ix => Load DL ix e where
  size = dlSize
  {-# INLINE size #-}
  getComp = dlComp
  {-# INLINE getComp #-}
  loadArrayWithSetM scheduler DLArray {dlLoad} = dlLoad scheduler 0
  {-# INLINE loadArrayWithSetM #-}

instance Index ix => Functor (Array DL ix) where
  fmap f arr = arr {dlLoad = loadFunctor arr f}
  {-# INLINE fmap #-}
  (<$) = overwriteFunctor
  {-# INLINE (<$) #-}

overwriteFunctor :: forall ix a b. Index ix => a -> Array DL ix b -> Array DL ix a
overwriteFunctor e arr = arr {dlLoad = load}
  where
    load :: Scheduler m () -> Ix1 -> (Ix1 -> a -> m ()) -> (Ix1 -> Sz1 -> a -> m ()) -> m ()
    load _ !startAt _ dlSet = dlSet startAt (linearSize arr) e
    {-# INLINE load #-}
{-# INLINE overwriteFunctor #-}


loadFunctor ::
     Monad m
  => Array DL ix a
  -> (a -> b)
  -> Scheduler m ()
  -> Ix1
  -> (Ix1 -> b -> m ())
  -> (Ix1 -> Sz1 -> b -> m ())
  -> m ()
loadFunctor arr f scheduler startAt uWrite uSet =
  dlLoad arr scheduler startAt (\ !i e -> uWrite i (f e)) (\o sz e -> uSet o sz (f e))
{-# INLINE loadFunctor #-}
