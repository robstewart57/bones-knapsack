{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

module Knapsack
(
    skeletonSafe
  , skeletonBroadcast
  , skeletonSequential
  , sequentialInlined
  , declareStatic
  , Solution(..)
  , Item(..)
) where

import Control.Parallel.HdpH hiding (declareStatic)

import Bones.Skeletons.BranchAndBound.HdpH.Types ( BAndBFunctions(BAndBFunctions)
                                                 , BAndBFunctionsL(BAndBFunctionsL)
                                                 , PruneType(..), ToCFns(..))
-- import Bones.Skeletons.BranchAndBound.HdpH.GlobalRegistry (addGlobalSearchSpaceToRegistry)
import Bones.Skeletons.BranchAndBound.HdpH.GlobalRegistry
import qualified Bones.Skeletons.BranchAndBound.HdpH.Safe as Safe
import qualified Bones.Skeletons.BranchAndBound.HdpH.Broadcast as Broadcast
import qualified Bones.Skeletons.BranchAndBound.HdpH.Sequential as Sequential

import Control.DeepSeq (NFData)
import Control.Monad (when)

import GHC.Generics (Generic)

import Data.Serialize (Serialize)
import Data.IORef

data Solution = Solution !Integer ![Item] !Integer !Integer deriving (Generic, Show)
data Item = Item {-# UNPACK #-} !Int !Integer !Integer deriving (Generic, Show)

instance Serialize Solution where
instance Serialize Item where
instance NFData Solution where
instance NFData Item where

skeletonSafe :: [Item] -> Integer -> Int -> Bool -> Par Solution
skeletonSafe items capacity depth diversify = do
  io $ newIORef items >>= addGlobalSearchSpaceToRegistry

  Safe.search
    diversify
    depth
    (Solution capacity [] 0 0)
    items
    (0 :: Integer)
    (toClosure (BAndBFunctions
      $(mkClosure [| generateChoices |])
      $(mkClosure [| shouldPrune |])
      $(mkClosure [| shouldUpdateBound |])
      $(mkClosure [| step |])
      $(mkClosure [| removeChoice |])))
    (toClosure (ToCFns
      $(mkClosure [| toClosureSolution |])
      $(mkClosure [| toClosureInteger |])
      $(mkClosure [| toClosureItem |])
      $(mkClosure [| toClosureItemList |])))

skeletonBroadcast :: [Item] -> Integer -> Int -> Bool -> Par Solution
skeletonBroadcast items capacity depth diversify = do
  io $ newIORef items >>= addGlobalSearchSpaceToRegistry

  Broadcast.search
    depth
    (Solution capacity [] 0 0)
    items
    (0 :: Integer)
    (toClosure (BAndBFunctions
      $(mkClosure [| generateChoices |])
      $(mkClosure [| shouldPrune |])
      $(mkClosure [| shouldUpdateBound |])
      $(mkClosure [| step |])
      $(mkClosure [| removeChoice |])))
    (toClosure (ToCFns
      $(mkClosure [| toClosureSolution |])
      $(mkClosure [| toClosureInteger |])
      $(mkClosure [| toClosureItem |])
      $(mkClosure [| toClosureItemList |])))

skeletonSequential :: [Item] -> Integer -> Par Solution
skeletonSequential items capacity = do
  io $ newIORef items >>= addGlobalSearchSpaceToRegistry

  Sequential.search
    (Solution capacity [] 0 0)
    items
    (0 :: Integer)
    (BAndBFunctionsL generateChoices shouldPrune shouldUpdateBound step removeChoice)

sequentialInlined :: [Item] -> Integer -> Par Solution
sequentialInlined items capacity = do
  io $ newIORef items >>= addGlobalSearchSpaceToRegistry
  seqSearch (Solution capacity [] 0 0) items 0

-- Assumes any global space state is already initialised
seqSearch :: Solution -> [Item] -> Integer -> Par a
seqSearch ssol sspace sbnd = do
  io $ addToRegistry solutionKey (ssol, sbnd)
  io $ addToRegistry boundKey sbnd
  expand ssol sspace
  io $ fst <$> readFromRegistry solutionKey

expand :: Solution -> [Item] -> Par ()
expand = go1
  where
    go1 s r = generateChoices s r >>= go s r

    go _ _ [] = return ()

    go sol remaining (c:cs) = do
      bnd <- io $ readFromRegistry boundKey

      sp <- shouldPrune c bnd sol remaining
      case sp of
        Prune      -> do
          remaining'' <- removeChoice c remaining
          go sol remaining'' cs

        PruneLevel -> return ()

        NoPrune    -> do
          (newSol, newBnd, remaining') <- step c sol remaining

          when (shouldUpdateBound newBnd bnd) $
              updateLocalBoundAndSol newSol newBnd

          go1 newSol remaining'

          remaining'' <- removeChoice c remaining
          go sol remaining'' cs

-- TODO: Technically we don't need atomic modify when we are sequential but this
-- keeps us closer to the parallel version.
updateLocalBoundAndSol :: Solution -> Integer -> Par ()
updateLocalBoundAndSol sol bnd = do
  -- Bnd
  ref <- io $ getRefFromRegistry boundKey
  io $ atomicModifyIORef' ref $ \b ->
    if shouldUpdateBound bnd b then (bnd, ()) else (b, ())

  -- Sol
  ref <- io $ getRefFromRegistry solutionKey
  io $ atomicModifyIORef' ref $ \prev@(_,b) ->
        if shouldUpdateBound bnd b
            then ((sol, bnd), True)
            else (prev, False)

  return ()




--------------------------------------------------------------------------------
-- Skeleton Functions
--------------------------------------------------------------------------------

--  generateChoices :: Closure (Closure a -> Closure s -> Par [Closure c])
--  shouldPrune     :: Closure (Closure c -> Closure a -> Closure b -> Bool)
--  updateBound     :: Closure (Closure b -> Closure b -> Bool)
--  step            :: Closure (Closure c -> Closure a -> Closure s
--                      -> Par (Closure a, Closure b, Closure s))
--  removeChoice    :: Closure (Closure c -> Closure s-> Closure s)

-- Potential choices is simply the list of un-chosen items
generateChoices :: Solution -> [Item] -> Par [Item]
generateChoices (Solution cap _ _ curWeight) remaining =
  -- Could also combine these as a fold, but it's easier to read this way.
  return $ filter (\(Item _ _ w) -> curWeight + w <= cap) remaining

-- Calculate the bounds function
shouldPrune :: Item
            -> Integer
            -> Solution
            -> [Item]
            -> Par PruneType
shouldPrune (Item _ ip iw) bnd (Solution cap _ p w) r =
  if fromIntegral bnd > ub (p + ip) (w + iw) cap r then
    return PruneLevel
  else
    return NoPrune

  where
    ub :: Integer -> Integer -> Integer -> [Item] -> Integer
    ub p _ _ [] = p
    ub p w c (Item _ ip iw : is)
      | c - (w + iw) >= 0 = ub (p + ip) (w + iw) c is
      | otherwise = p + floor (fromIntegral (c - w) * divf ip iw)

    divf :: Integer -> Integer -> Float
    divf a b = fromIntegral a / fromIntegral b


shouldUpdateBound :: Integer -> Integer -> Bool
shouldUpdateBound x y = x > y

step :: Item -> Solution -> [Item] -> Par (Solution, Integer, [Item])
step i@(Item _ np nw) (Solution cap is p w) r = do
  rm <- removeChoice i r

  return (Solution cap (i:is) (p + np) (w + nw), p + np, rm)

removeChoice :: Item -> [Item] -> Par [Item]
removeChoice (Item v _ _ ) its = return $ filter (\(Item n _ _) -> v /= n) its

--------------------------------------------------------------------------------
-- Closure Instances
--------------------------------------------------------------------------------
instance ToClosure (BAndBFunctions Solution Integer Item [Item]) where
  locToClosure = $(here)

instance ToClosure (ToCFns Solution Integer Item [Item]) where
  locToClosure = $(here)

--------------------------------------------------------------------------------
-- Explicit ToClousre Instances (needed for performance)
--------------------------------------------------------------------------------
toClosureItem :: Item -> Closure Item
toClosureItem x = $(mkClosure [| toClosureItem_abs x |])

toClosureItem_abs :: Item -> Thunk Item
toClosureItem_abs x = Thunk x

toClosureItemList :: [Item] -> Closure [Item]
toClosureItemList x = $(mkClosure [| toClosureItemList_abs x |])

toClosureItemList_abs :: [Item] -> Thunk [Item]
toClosureItemList_abs x = Thunk x

toClosureSolution :: Solution -> Closure Solution
toClosureSolution x = $(mkClosure [| toClosureSolution_abs x |])

toClosureSolution_abs :: Solution -> Thunk Solution
toClosureSolution_abs x = Thunk x

toClosureInteger :: Integer -> Closure Integer
toClosureInteger x = $(mkClosure [| toClosureInteger_abs x |])

toClosureInteger_abs :: Integer -> Thunk Integer
toClosureInteger_abs x = Thunk x

$(return [])
declareStatic :: StaticDecl
declareStatic = mconcat
  [
    declare (staticToClosure :: StaticToClosure (BAndBFunctions Solution Integer Item [Item]))
  , declare (staticToClosure :: StaticToClosure (ToCFns Solution Integer Item [Item]))

  -- B&B Functions
  , declare $(static 'generateChoices)
  , declare $(static 'shouldPrune)
  , declare $(static 'shouldUpdateBound)
  , declare $(static 'step)
  , declare $(static 'removeChoice)

  -- Explicit toClosure
  , declare $(static 'toClosureInteger)
  , declare $(static 'toClosureInteger_abs)
  , declare $(static 'toClosureItem)
  , declare $(static 'toClosureItem_abs)
  , declare $(static 'toClosureItemList)
  , declare $(static 'toClosureItemList_abs)
  , declare $(static 'toClosureSolution)
  , declare $(static 'toClosureSolution_abs)

  , Safe.declareStatic
  ]
