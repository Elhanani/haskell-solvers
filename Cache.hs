{-# LANGUAGE MultiParamTypeClasses
           , AllowAmbiguousTypes
           , FlexibleInstances
           , FlexibleContexts
           , BangPatterns
           , NamedFieldPuns
             #-}

module Cache (Cache(..), Hashable, STHashRef,
              runNoCache, runMapCache, runHashMapCache,
              SingleHashRef, newSingleHashRef) where

import Data.Hashable
import Data.Proxy
import Control.Monad.ST
import Control.Monad.Reader
import Data.Functor.Identity
import Data.Maybe
import qualified Data.Map as M
import qualified Data.HashMap.Strict as H
import qualified Data.Array.ST as STA
import Control.Monad.State
import Control.Monad.ST

-- runNoCache = undefined
-- runMapCache = undefined
-- runHashMapCache = undefined


-- | Pure types of transposition tables

class Monad m => Cache m k v where
  readCache :: k -> m (Maybe v)
  readCacheDefault :: k -> v -> m v
  writeCache :: k -> v -> m ()
  filterCache :: (k -> v -> Bool) -> m ()

  readCacheDefault !k dv = do
    !mv <- readCache k
    return $! case mv of
      Just !jv -> jv
      Nothing -> dv

class (Cache (ReaderT r (ST s)) k v) => STHashRef r s k v

-- | Trivial implementation (i.e no table)

instance Cache Identity k v where
  readCache _ = return Nothing
  readCacheDefault _ a = return a
  writeCache _ _ = return ()
  filterCache _ = return ()

runNoCache :: (k -> Identity v) -> k -> v
runNoCache f k = runIdentity (f k)


-- | State monad with a Map

instance (Ord k) => Cache (State (M.Map k v)) k v where
  readCache !k = get >>= return . (M.lookup k)
  readCacheDefault !k !v = get >>= return . (M.findWithDefault v k)
  writeCache !k !v = get >>= put . (M.insert k v)
  filterCache !f = get >>= put . (M.filterWithKey f)

runMapCache :: (k -> State (M.Map k v) v) -> k -> v
runMapCache f k = fst $ runState (f k) M.empty


-- | State Monad with HashMap

instance (Hashable k, Eq k) => Cache (State (H.HashMap k v)) k v where
  readCache !k = get >>= return . (H.lookup k)
  readCacheDefault !k !v = get >>= return . (H.lookupDefault v k)
  writeCache !k !v = get >>= put . (H.insert k v)
  filterCache !f = get >>= put . (H.filterWithKey f)

runHashMapCache :: (k -> State (H.HashMap k v) v) -> k -> v
runHashMapCache f k = fst $ runState (f k) H.empty

-- | ST Monad with a partial hashtable

data SingleHashRef s k v = SingleHashRef {singleArray :: STA.STArray s Int (Maybe (k, v))
                                        , singleOverwrite :: (k, v) -> (k, v) -> Bool
                                        , singleSize :: !Int
                                          }

instance (Hashable k, Eq k) => Cache (ReaderT (SingleHashRef s k v) (ST s)) k v where
  readCache !k = do
    !SingleHashRef {singleArray, singleSize} <- ask
    let f (Just (k, v)) = Just v
        f _ = Nothing
    fmap f $ lift $ STA.readArray singleArray (mod (hash k) singleSize)
  writeCache !k !v = do
    !SingleHashRef {singleArray, singleOverwrite, singleSize} <- ask
    !current <- lift $ STA.readArray singleArray (mod (hash k) singleSize)
    let f Nothing = True
        f (Just (k', v')) = k' == k || singleOverwrite (k', v') (k, v)
    if f current
      then lift $ STA.writeArray singleArray (mod (hash k) singleSize) (Just (k, v))
      else return ()
  filterCache !f = do
    !SingleHashRef {singleArray, singleSize} <- ask
    let g n = do
              current <- STA.readArray singleArray (mod n singleSize)
              if isNothing current then return () else let Just (k, v) = current in
                if f k v then return () else STA.writeArray singleArray (mod n singleSize) Nothing
    lift $ mapM_ g [0..singleSize-1]

instance (Eq k, Hashable k) => STHashRef (SingleHashRef s k v) s k v -- forall s. ??

newSingleHashRef :: Int -> ((k, v) -> (k, v) -> Bool) -> ST s (SingleHashRef s k v)
newSingleHashRef singleSize singleOverwrite = do
  array <- STA.newArray (0, singleSize-1) Nothing
  return SingleHashRef {singleArray = array, singleSize, singleOverwrite}

-- runSingleHashCache :: Int -> ((k, v) -> (k, v) -> Bool) ->
--                       (k -> ReaderT (SingleHashRef s k v) (ST s) v) -> k -> v
-- runSingleHashCache singleSize singleOverwrite f k = runST $ do
--   array <- STA.newArray (0, singleSize-1) Nothing -- :: ST s (STA.STArray s Int (Maybe (k, v)))
--   runReaderT (f k) (SingleHashRef {singleArray = array, singleSize, singleOverwrite})