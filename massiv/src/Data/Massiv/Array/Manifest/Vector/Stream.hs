{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Data.Massiv.Array.Manifest.Vector.Stream
-- Copyright   : (c) Alexey Kuleshevich 2019
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Data.Massiv.Array.Manifest.Vector.Stream
  ( Steps(..)
  -- * Conversion
  , steps
  , isteps
  , fromStream
  , fromStreamM
  , fromStreamExactM
  , unstreamExact
  , unstreamMax
  , unstreamMaxM
  , unstreamUnknown
  , unstreamUnknownM
  , unstreamIntoM
  -- * Bundle
  , toBundle
  , fromBundle
  , fromBundleM
  -- * Operations on Steps
  , length
  , generate
  , traverse
  , mapM
  , zipWithM
  -- ** Folding
  , foldl
  , foldr
  , foldlM
  , foldrM
  -- ** Filter
  , mapMaybe
  , filter
  , filterM
  , transStepsId
  -- * Useful re-exports
  , module Data.Vector.Fusion.Bundle.Size
  , module Data.Vector.Fusion.Util
  ) where

import Control.Monad.ST
import Data.Massiv.Core.Common
import qualified Data.Traversable as Traversable (traverse)
import qualified Data.Vector.Fusion.Bundle.Monadic as B
import Data.Vector.Fusion.Bundle.Size
import qualified Data.Vector.Fusion.Stream.Monadic as S
import Data.Vector.Fusion.Util
import Prelude hiding (mapM, traverse, length, foldl, foldr, filter)

data Steps m e = Steps
  { sSteps :: S.Stream m e
  , sSize  :: Size
  }

instance Monad m => Functor (Steps m) where

  fmap f = mapM (pure . f)
  {-# INLINE fmap #-}



-- TODO: benchmark: `fmap snd . isteps`
steps :: forall r ix e m . (Monad m, Source r ix e) => Array r ix e -> Steps m e
steps arr = k `seq` arr `seq` Steps (S.Stream step 0) (Exact k)
  where
    k = totalElem $ size arr
    step i
      | i < k =
        let e = unsafeLinearIndex arr i
         in e `seq` return $ S.Yield e (i + 1)
      | otherwise = return S.Done
    {-# INLINE step #-}
{-# INLINE steps #-}


isteps :: forall r ix e m . (Monad m, Source r ix e) => Array r ix e -> Steps m (ix, e)
isteps arr = k `seq` arr `seq` Steps (S.Stream step 0) (Exact k)
  where
    sz = size arr
    k = totalElem sz
    step i
      | i < k =
        let e = unsafeLinearIndex arr i
         in e `seq` return $ S.Yield (fromLinearIndex sz i, e) (i + 1)
      | otherwise = return S.Done
    {-# INLINE step #-}
{-# INLINE isteps #-}

toBundle :: (Monad m, Source r ix e) => Array r ix e -> B.Bundle m v e
toBundle arr =
  let Steps str k = steps arr
   in B.fromStream str k
{-# INLINE toBundle #-}

fromBundle :: Mutable r Ix1 e => B.Bundle Id v e -> Array r Ix1 e
fromBundle bundle = fromStream (B.sSize bundle) (B.sElems bundle)
{-# INLINE fromBundle #-}


fromBundleM :: (Monad m, Mutable r Ix1 e) => B.Bundle m v e -> m (Array r Ix1 e)
fromBundleM bundle = fromStreamM (B.sSize bundle) (B.sElems bundle)
{-# INLINE fromBundleM #-}


fromStream :: forall r e . Mutable r Ix1 e => Size -> S.Stream Id e -> Array r Ix1 e
fromStream sz str =
  case upperBound sz of
    Nothing -> unstreamUnknown str
    Just k  -> unstreamMax k str
{-# INLINE fromStream #-}

fromStreamM :: forall r e m. (Monad m, Mutable r Ix1 e) => Size -> S.Stream m e -> m (Array r Ix1 e)
fromStreamM sz str = do
  xs <- S.toList str
  case upperBound sz of
    Nothing -> pure $! unstreamUnknown (S.fromList xs)
    Just k  -> pure $! unstreamMax k (S.fromList xs)
{-# INLINE fromStreamM #-}

fromStreamExactM ::
     forall r ix e m. (Monad m, Mutable r ix e)
  => Sz ix
  -> S.Stream m e
  -> m (Array r ix e)
fromStreamExactM sz str = do
  xs <- S.toList str
  pure $! unstreamExact sz (S.fromList xs)
{-# INLINE fromStreamExactM #-}


unstreamIntoM ::
     (Mutable r Ix1 a, PrimMonad m)
  => MArray (PrimState m) r Ix1 a
  -> Size
  -> S.Stream Id a
  -> m (MArray (PrimState m) r Ix1 a)
unstreamIntoM marr sz str =
  case sz of
    Exact _ -> marr <$ unstreamMaxM marr str
    Max _ -> unsafeLinearShrink marr . SafeSz =<< unstreamMaxM marr str
    Unknown  -> unstreamUnknownM marr str
{-# INLINE unstreamIntoM #-}



unstreamMax ::
     forall r e. (Mutable r Ix1 e)
  => Int
  -> S.Stream Id e
  -> Array r Ix1 e
unstreamMax kMax str =
  runST $ do
    marr <- unsafeNew (SafeSz kMax)
    k <- unstreamMaxM marr str
    unsafeLinearShrink marr (SafeSz k) >>= unsafeFreeze Seq
{-# INLINE unstreamMax #-}


unstreamMaxM ::
     (Mutable r ix a, PrimMonad m) => MArray (PrimState m) r ix a -> S.Stream Id a -> m Int
unstreamMaxM marr (S.Stream step s) = stepLoad s 0
  where
    stepLoad t i =
      case unId (step t) of
        S.Yield e' t' -> do
          unsafeLinearWrite marr i e'
          stepLoad t' (i + 1)
        S.Skip t' -> stepLoad t' i
        S.Done -> return i
    {-# INLINE stepLoad #-}
{-# INLINE unstreamMaxM #-}


unstreamUnknown :: Mutable r Ix1 a => S.Stream Id a -> Array r Ix1 a
unstreamUnknown str =
  runST $ do
    let kInit = 1
    marr <- unsafeNew (SafeSz kInit)
    unstreamUnknownM marr str >>= unsafeFreeze Seq
{-# INLINE unstreamUnknown #-}


unstreamUnknownM ::
     (Mutable r Ix1 a, PrimMonad m)
  => MArray (PrimState m) r Ix1 a
  -> S.Stream Id a
  -> m (MArray (PrimState m) r Ix1 a)
unstreamUnknownM marrInit (S.Stream step s) = stepLoad s 0 (unSz (msize marrInit)) marrInit
  where
    stepLoad t i kMax marr
      | i < kMax =
        case unId (step t) of
          S.Yield e' t' -> do
            unsafeLinearWrite marr i e'
            stepLoad t' (i + 1) kMax marr
          S.Skip t' -> stepLoad t' i kMax marr
          S.Done -> unsafeLinearShrink marr (SafeSz i)
      | otherwise = do
        let kMax' = kMax * 2
        marr' <- unsafeLinearGrow marr (SafeSz kMax')
        stepLoad t i kMax' marr'
    {-# INLINE stepLoad #-}
{-# INLINE unstreamUnknownM #-}


unstreamExact ::
     forall r ix e. (Mutable r ix e)
  => Sz ix
  -> S.Stream Id e
  -> Array r ix e
unstreamExact sz str =
  runST $ do
    marr <- unsafeNew sz
    _ <- unstreamMaxM marr str
    unsafeFreeze Seq marr
{-# INLINE unstreamExact #-}


streamTraverse :: (Monad m, Applicative f) => (a -> f b) -> S.Stream Id a -> f (S.Stream m b)
streamTraverse f str = S.fromList <$> Traversable.traverse f (unId (S.toList str))
{-# INLINE streamTraverse #-}

length :: Steps Id a -> Int
length (Steps str sz) =
  case sz of
    Exact k -> k
    _ -> unId (S.length str)

generate :: Monad m => Int -> (Int -> e) -> Steps m e
generate k f = Steps (S.generate k f) (Exact k)
{-# INLINE generate #-}

traverse :: (Monad m, Applicative f) => (e -> f a) -> Steps Id e -> f (Steps m a)
traverse f (Steps str k) = (`Steps` k) <$> streamTraverse f str
{-# INLINE traverse #-}


mapM :: Monad m => (e -> m a) -> Steps m e -> Steps m a
mapM f (Steps str k) = Steps (S.mapM f str) k
{-# INLINE mapM #-}


zipWithM :: Monad m => (a -> b -> m c) -> Steps m a -> Steps m b -> Steps m c
zipWithM f (Steps str1 k1) (Steps str2 k2) = Steps (S.zipWithM f str1 str2) (smaller k1 k2)
{-# INLINE zipWithM #-}

transStepsId :: Monad m => Steps Id e -> Steps m e
transStepsId (Steps sts k) = Steps (S.trans (pure . unId) sts) k
{-# INLINE transStepsId #-}


foldr :: (a -> b -> b) -> b -> Steps Id a -> b
foldr f acc sts = unId (S.foldr f acc (sSteps sts))
{-# INLINE foldr #-}


foldl :: (b -> a -> b) -> b -> Steps Id a -> b
foldl f acc sts = unId (S.foldl f acc (sSteps sts))
{-# INLINE foldl #-}


foldlM :: Monad m => (a -> b -> m a) -> a -> Steps m b -> m a
foldlM f acc (Steps sts _) = S.foldlM f acc sts
{-# INLINE foldlM #-}


foldrM :: Monad m => (b -> a -> m a) -> a -> Steps m b -> m a
foldrM f acc (Steps sts _) = S.foldrM f acc sts
{-# INLINE foldrM #-}


mapMaybe :: Monad m => (a -> Maybe e) -> Steps m a -> Steps m e
mapMaybe f (Steps str k) = Steps (S.mapMaybe f str) (toMax k)
{-# INLINE mapMaybe #-}

mapMaybeA = undefined

-- mapMaybeM :: Monad m => (a -> m (Maybe e)) -> Steps m a -> Maybe (Steps m e)
-- mapMaybeM f (Steps str k) = Steps (S.mapMaybeM f str) (toMax k)
-- {-# INLINE mapMaybeM #-}


filter :: Monad m => (a -> Bool) -> Steps m a -> Steps m a
filter f (Steps str k) = Steps (S.filter f str) (toMax k)
{-# INLINE filter #-}

filterA = undefined

filterM :: Monad m => (e -> m Bool) -> Steps m e -> Steps m e
filterM f (Steps str k) = Steps (S.filterM f str) (toMax k)
{-# INLINE filterM #-}
