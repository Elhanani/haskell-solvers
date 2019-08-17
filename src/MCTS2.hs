{-# LANGUAGE ExistentialQuantification
           , BangPatterns
           , NamedFieldPuns
           , RankNTypes #-}

-- module MCTS2 (module SolverDefs
--             , MCParams(..)
--             , defaultMCParams
--             , mctsSolver
--             , lessevilMCTS) where

module MCTS2 where

import SolverDefs
import Data.Maybe
import System.Random
import Data.Time
import Data.List
import Data.Ord
import Data.Hashable
import Data.Tuple
import Control.Monad
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.MVar
import System.IO
import qualified Data.PQueue.Max as MQ
import qualified Data.Map as M
import qualified Data.HashTable.IO as HT

class (GameState gs, Eq gs, Hashable gs, Ord gs) => HGS gs

-- | exploration/expolitation are coefficients for the UCB funtion
--   alpha, beta are values that will stop the search
--   duration is the amount of time in milliseconds to search
--   maxsim is the maximum count of simulations
--   background is True when we allow thinking in the background
--   uniform is True when we want to explore and not to exploit only for the first node
--   numrolls is the number of rollouts per leaf
--   simsperroll is the rate of increase of the rollouts per leaf per root simulations
--   inert is when we do not want to propagate terminals
--   advancechunks is how many advances to do before checking conditions
--   lessevil is the function to use in case of a terminal non-win
--   bestActions
data MCParams = MCParams
  {exploitation :: {-# UNPACK #-} !Value
 , exploration :: {-# UNPACK #-} !Value
 , alpha :: {-# UNPACK #-} !Value
 , beta :: {-# UNPACK #-} !Value
 , duration ::  {-# UNPACK #-} !Int
 , maxsim :: {-# UNPACK #-} !Int
 , numrollsI :: {-# UNPACK #-} !Int
 , numrollsSqrt :: {-# UNPACK #-} !Value
 , simsperroll :: {-# UNPACK #-} !Value
 , extracache :: {-# UNPACK #-} !Int
 , advancechunks :: {-# UNPACK #-} !Int
 , background :: !Bool
 , uniform :: !Bool
 , inert :: !Bool
 , lessevil :: forall gs. HGS gs => Maybe (gs -> [String] -> IO String)
 , bestactions :: forall gs. HGS gs => (gs, MCNode gs) -> [(gs, MCNode gs)] -> [gs]}

defaultMCParams :: MCParams
defaultMCParams = MCParams {exploitation = 1
                          , exploration = sqrt 8
                          , alpha = (-1)
                          , beta = 1
                          , duration = 1000
                          , maxsim = 100000000
                          , background = True
                          , numrollsI = 1
                          , numrollsSqrt = 1
                          , simsperroll = 1000000
                          , uniform = False
                          , inert = False
                          , lessevil = Nothing
                          , extracache = 100000
                          , advancechunks = 100
                          , bestactions = defaultBestactions 1}

-- | Cache includes the proposed size for the allocated table.
newtype MCCache gs = MCCache [(gs, MCNode gs)]

emptyCache :: MCCache gs
emptyCache = MCCache []

data MCSolvedGame gs =
     MCSolvedGame {gameState :: gs
                 , mcParams :: MCParams
                 , mcCache :: MCCache gs}

-- | Terminals are states with a known value
--   Trunks are states with fully evaluated children
--   Buds are states where some children have not yet been evaluated
data MCNode gs =
     InertTerminal {-# UNPACK #-} !Value
   | Terminal {-# UNPACK #-} !Value
   | Bud ![(gs, (Value, Value))] ![gs]
   | Trunk {sims :: {-# UNPACK #-} !Value
          , wins :: {-# UNPACK #-} !Value
          , moveq :: !(MQ.MaxQueue (PrioMove gs))
          , terminals :: [gs]
          , worstcase :: !Value} -- this can be meaningful with lcb as well.

data PrioMove gs = PrioMove {priority :: {-# UNPACK #-} !Value
                           , subsims :: {-# UNPACK #-} !Value
                           , pmove :: !gs}

instance Eq gs => Eq (PrioMove gs) where
  mc1 == mc2 = (pmove $! mc2) == (pmove $! mc1)

instance Eq gs => Ord (PrioMove gs) where
  compare mc1 mc2 = compare (priority $! mc1) (priority $! mc2)

type IOCache gs = HT.CuckooHashTable gs (MCNode gs)

playerBound :: Player -> MCParams -> Value
playerBound !Maximizer = beta
playerBound !Minimizer = alpha

-- playerObjectiveBy :: (Foldable t) => Player -> (a -> a -> Ordering) -> t a -> a
-- playerObjectiveBy !Maximizer = maximumBy
-- playerObjectiveBy !Minimizer = minimumBy

-- | Getter function from a terminal
-- terminalVal :: MCNode gs -> Maybe Value
-- terminalVal !(Terminal !v) = Just v
-- terminalVal !(InertTerminal !v) = Just v
-- terminalVal _ = Nothing

instance Show gs => Show (MCSolvedGame gs) where
  show = show . gameState

instance GameState gs => GameState (MCSolvedGame gs) where
  player = player . gameState
  terminal = terminal . gameState
  maxdepth = maxdepth . gameState
  actionfilters = (map (\(str, f) -> (str, f . gameState))) . actionfilters . gameState
  actions mcsg = map mkAction $ actions $ gs0 where
    gs0 = gameState mcsg
    MCCache cachelist = mcCache mcsg
    mkAction (str, gs1) = (str, mcsg {gameState = gs1, mcCache = cache str})
    cache str = MCCache (filter ((f str) . fst) cachelist)
    f str = fromMaybe (const True) $ lookup str $ actionfilters gs0

-- | Initialize cache in IO monad
cache2io :: (HGS gs) => MCCache gs -> Int -> IO (IOCache gs)
cache2io (MCCache cachelist) n = HT.fromListWithSizeHint (n + length cachelist) cachelist

-- | Find in cache or create new
getNode :: (HGS gs) => IOCache gs -> gs -> IO (MCNode gs)
getNode cache gs = fmap (fromMaybe (Bud [] $ map snd $ actions gs) )$ HT.lookup cache gs

instance (HGS gs) => SolvedGameState (MCSolvedGame gs) where
  action (MCSolvedGame {gameState, mcCache, mcParams}) = do
    let gsactions = actions gameState
        children = map snd gsactions
    cache <- cache2io mcCache $ extracache mcParams
    worker <- advanceUntil mcParams cache gameState
    threadDelay $ 1000 * duration mcParams
    worker
    rootnode <- getNode cache gameState
    childnodes <- mapM (getNode cache) children
    let bestgs = bestactions mcParams (gameState, rootnode) $ zip children childnodes
        best = zip (map (\gs -> fromJust $ lookup gs $ map swap $ actions gs) bestgs) bestgs
    (str, newgs) <- if length bestgs == 1 then return $ head best else do
      let f = fromMaybe (lessevilMCTS mcParams) $ lessevil mcParams
      beststr <- f gameState $ map fst best
      return $ (beststr, fromJust $ lookup beststr gsactions)
    cachelist <- HT.toList cache
    let f = fromMaybe (const True) $ lookup str $ actionfilters gameState
        newcache = MCCache (filter (f . fst) cachelist)
    return (str, MCSolvedGame {mcParams, gameState = newgs, mcCache = newcache})
  think (MCSolvedGame {gameState, mcParams, mcCache}) = do
    let gsactions = actions gameState
        children = map snd gsactions
    cache <- cache2io mcCache $ extracache mcParams
    worker <- advanceUntil (mcParams {uniform=True}) cache gameState
    return $ do
      worker
      cachelist <- HT.toList cache
      return MCSolvedGame {gameState, mcParams, mcCache = MCCache cachelist}

-- | Selects the best actions to play using lcb
defaultBestactions :: HGS gs => Value -> (gs, MCNode gs) -> [(gs, MCNode gs)] -> [gs]
defaultBestactions _ (!gs, Terminal !val) !children = filter f $! map snd $! actions gs where
  f ns = g $ fromJust $ lookup ns children
  g (!Terminal !value) = value == val
  g _ = False
defaultBestactions !ratio (!gs, Trunk {sims, moveq, terminals, worstcase}) !children = res where
  moves = MQ.toList moveq
  nodes = map (fromJust . flip lookup children . pmove) moves
  pl = player gs
  f = confidence pl False 1 ratio sims
  trunks = zip (zipWith f (map Just $ moves) nodes) (map pmove moves)
  (bestval, bestgame) = maximum trunks
  res = if bestval > worstcase then [bestgame] else terminals

-- | UCB or LCB - used to rate the moves
confidence :: HGS gs => Player -> Bool -> Value -> Value ->
                        Value -> Maybe (PrioMove gs) -> MCNode gs -> Value
confidence player upper c1 c2 num move node = c1 * p1 * mean node + c2 * p2 * stdv move where
  !maximizer = player == Maximizer
  !p1 = if maximizer then 1 else -1
  !p2 = if maximizer == upper then 1 else -1
  mean (!InertTerminal !val) = val
  mean (!Terminal !val) = val
  mean (!Bud !leaves _ ) = (sum $ map (fst . snd) leaves) / (sum $ map (snd . snd) leaves)
  mean (!Trunk {sims, wins}) = wins/sims
  stdv (!Just (!PrioMove {subsims})) = sqrt $ (log num) / (subsims)
  stdv (!Nothing) = 0

-- | Advances until the resulting function is called
advanceUntil :: HGS gs => MCParams -> IOCache gs -> gs -> IO (IO ())
advanceUntil !params !cache !gs = if background $! params then do
  mfinish <- newMVar False
  let !maxsim' = fromIntegral $! maxsim $! params
      stopcond !(Bud _ _) = False
      stopcond !(Trunk {sims}) = sims > maxsim'
      stopcond _ = True
      totalsim !(Trunk {sims}) = sims
      totalsim _ = 0
      internal = do
        Just node <- HT.lookup cache gs
        let !newrolls = floor ((totalsim node) / (simsperroll params)) + numrollsI params
            !params' = params {numrollsI = newrolls, numrollsSqrt = sqrt $! fromIntegral newrolls}
        replicateM_ (advancechunks params) $ advanceState params' cache gs
        hFlush stdout -- why?
        finish <- readMVar mfinish
        if finish || stopcond node
          then return ()
          else internal
  solver <- async $ internal
  return $ do
    swapMVar mfinish True
    wait solver
  else return $ return ()

advanceState :: HGS gs => MCParams -> IOCache gs -> gs -> IO ()
advanceState !params !cache !gs = do
  node <- getNode cache gs
  return undefined


advanceNode :: HGS gs => MCParams -> IOCache gs -> MCNode gs -> gs -> IO Value
advanceNode !params _ (InertTerminal !val) _ = return $ val * numrollsSqrt params
advanceNode !params _ (Terminal !val) _ = return $ val * numrollsSqrt params
advanceNode !params !cache (Bud !done !(ngs:rest)) _ = do
  rand <- newStdGen
  let !n = numrollsI params
      !sqrtn = numrollsSqrt params
      !w = (fst $ rollouts n ngs rand) / sqrtn
      !node = Bud ((ngs, (w, sqrtn)):done) rest
  HT.insert cache ngs node
  return w
advanceNode !params !cache (Bud !done []) !gs =
  advanceNode params cache (Trunk {sims, wins, moveq, terminals, worstcase}) gs where
    !wins = sum $ map (fst . snd) done
    !sims = sum $ map (snd . snd) done
    !moveq = MQ.fromList $ map (leaf2prio gs params) done
    !terminals = []
    !worstcase = playerBound (otherPlayer $ player gs) params

advanceNode params cache (Trunk {}) gs = do
  return undefined

leaf2prio :: (HGS gs) => gs -> MCParams -> (gs, (Value, Value)) -> PrioMove gs
leaf2prio gs params (pmove, (subsims, wins)) = PrioMove {priority, subsims, pmove} where
  !c1 = exploitation params
  !c2 = exploration params
  !absval = c1 * (wins / subsims) +
            c2 * (sqrt $ (log $ fromIntegral $ numactions gs) / subsims)
  !priority = case player gs of
    Maximizer -> absval
    Minimizer -> -absval


{-
-- reminder
data PrioMove gs = PrioMove {priority :: {-# UNPACK #-} !Value
                           , subsims :: {-# UNPACK #-} !Value
                           , pmove :: !gs}


-- | Get actions from actions types
mkActions :: MCActions -> [MCAction]
mkActions (InertTerminal _) = []
mkActions (Terminal _ xs) = xs
mkActions (Trunk xs ys) = ys ++ (map action' $ MQ.toList xs)
mkActions (Bud solved unsolved) = solved ++ (map f unsolved) where
  f (str, gs) = (str, mkLeaf False gs)


-- | Creates a new leaf for the game (a node that has no children)
mkLeaf :: GameState gs => Bool -> gs -> MCNode
mkLeaf !inert' !gameState = MCNode {gameState, simulations, wins, children} where
  !maybeval = terminal gameState
  !simulations = 0
  !wins = 0
  !children = if isJust $! maybeval
    then if inert'
      then InertTerminal $ fromJust maybeval
      else Terminal (fromJust maybeval) []
    else Bud [] (actions $! gameState)

-- | Makes a trunk out of a completed bud
mkTrunk :: Player -> MCParams -> Value -> [MCAction] -> MCActions
mkTrunk !player !params@(MCParams{exploration, exploitation}) !totalsims !xs =
  maybeTrunk $! partition nonterminal xs where
    !testval = playerBound player params
    nonterminal (_, !MCNode {children = Terminal _ _}) = False
    nonterminal _ = True
    terminalval (_, !MCNode {children = Terminal !realval _}) = realval
    evalfunc (str, !mcNode) = PrioAction {
      action' = (str, mcNode),
      priority = exploitation*(playerValue player)*(avgVal mcNode) +
                 exploration*sqrt((log totalsims)/subsims),
      subsims} where !subsims = simulations mcNode
    !objective = playerObjective player
    maybeTrunk !([], !ys) = Terminal (objective $ map terminalval ys) ys
    maybeTrunk !(!xs, !ys) = if (or $ map ((==testval) . terminalval) ys)
      then Terminal testval (xs ++ ys)
      else Trunk (MQ.fromList $ map evalfunc xs) ys


-- | Advance a node to improve heuristic
advanceNode :: (RandomGen rg) => MCParams -> MCNode -> rg -> (MCNode, rg, Value)
advanceNode !(MCParams {numrollsSqrt})
            !mgs@(MCNode {children = (Terminal !tval _)}) !rand = (mgs, rand, tval*numrollsSqrt)
advanceNode !(MCParams {numrollsSqrt})
            !mgs@(MCNode {children = (InertTerminal !tval)}) !rand = (mgs, rand, tval*numrollsSqrt)
advanceNode !params@(MCParams {numrollsI, numrollsSqrt, inert})
            !mgs@(MCNode {simulations, wins=w, gameState,
                          children = (Bud !post !pre)}) rand =
  (mgs {simulations=simulations', wins = w+val, children = f children'}, rand', val) where
    !simulations' = simulations+numrollsSqrt
    !(!str, !gs) = head pre
    !(!ngs, !rand') = rolloutNode numrollsI (mkLeaf inert gs) rand
    !val = wins ngs
    !player' = player gameState
    !testval = playerBound player' params
    !children' = Bud ((str, ngs) : post) (tail pre)
    f !(Bud !post' []) = mkTrunk player' params simulations' post'
    f !bud@(Bud !post' pre') = if terminalVal ngs == Just testval
      then Terminal testval (post' ++ map (\(!str, !g) -> (str, mkLeaf False g)) pre')
      else bud
advanceNode !params@(MCParams{numrollsSqrt, exploration, exploitation, uniform})
            !mgs@(MCNode {simulations=s, wins=w, gameState,
                          children = !(Trunk !nonterminals !terminals)}) !rand =
  (mgs {simulations = s', wins = w+val, children = f children'}, rand', val) where
    (PrioAction {action' = (!str, !child), subsims = !ss'}, !queue) =
      fromJust $! MQ.maxView nonterminals
    !params' = params {uniform = False}
    !exploitation' = if uniform then 0 else exploitation
    !player' = player gameState
    !objective = playerObjective player'
    !s' = s + numrollsSqrt
    (!child', !rand', !val) = advanceNode params' child rand
    !nact = (str, child')
    !children' = case child' of
      MCNode {children = !(Terminal !tval _)} -> if tval == playerBound player' params
        then Terminal tval (nact: (terminals ++ (map action' $ MQ.toList queue)))
        else Trunk queue (nact:terminals)
      otherwise -> Trunk (MQ.insert nprio queue) terminals where
        !priority = exploitation*(playerValue player')*(avgVal child') +
                    exploration*sqrt((log s)/ss')
        !nprio = PrioAction {priority, action'=nact, subsims = ss' + numrollsSqrt}
    f ch@(Trunk !q' nt') = if isNothing $! MQ.maxView q'
      then Terminal (objective $ map (fromJust . terminalVal . snd) nt') nt'
      else ch
    f ch = ch

-}

-- | Perform a single (uniform) rollout
rollout :: (GameState gs, RandomGen r) => gs -> r -> (Value, r)
rollout !gs !rand = if isJust tgs then (fromJust tgs, rand) else rollout gs' rand' where
  !tgs = terminal $! gs
  !ags = actions $! gs
  !nags = numactions $! gs
  !(idx, rand') = randomR (0, nags-1) $! rand
  gs' = snd $! ags !! idx

-- | Perform multiple (uniform) rollouts
rollouts :: (GameState gs, RandomGen r) => Int -> gs -> r -> (Value, r)
rollouts 0 _ !rand = (0, rand)
rollouts !n !gs !rand1 = (v + w, rand3) where
  (!v, !rand2) = rollout gs rand1
  (!w, !rand3) = rollouts (n-1) gs rand2

-- | Solve a game with MCTS
mctsSolver :: HGS gs => MCParams -> gs -> MCSolvedGame gs
mctsSolver mcParams gameState = MCSolvedGame {gameState, mcParams, mcCache} where
  mcCache = emptyCache

-- | returns the least losing action
lessevilMCTS :: HGS gs => MCParams -> gs -> [String] -> IO String
lessevilMCTS params gs strs = do
  let gsactions = actions gs
      children = map snd gsactions
  cache <- cache2io emptyCache $ extracache params
  worker <- advanceUntil (params {inert = True}) cache gs
  threadDelay $ 1000 * duration params
  worker
  rootnode <- getNode cache gs
  childnodes <- mapM (getNode cache) children
  let best = head $ bestactions params (gs, rootnode) $ zip children childnodes
  return $ fromJust $ lookup best $ map swap $ actions gs

{-
-- | Multithreaded MCTS solver
data MTMCSolvedGame = MTMCSolvedGame {mtNodes :: [MCNode], mtParams :: MCParams}

instance Show MTMCSolvedGame where
  show MTMCSolvedGame {mtNodes = (MCNode {gameState}):_} = show gameState

instance GameState MTMCSolvedGame where
  player MTMCSolvedGame {mtNodes = (MCNode {gameState}):_} = player gameState
  terminal MTMCSolvedGame {mtNodes = (MCNode {gameState}):_} = terminal gameState
  maxdepth MTMCSolvedGame {mtNodes = (MCNode {gameState}):_} = maxdepth gameState
  actions MTMCSolvedGame {mtParams, mtNodes} = map mkSolvedGame $ M.toList solutions where
    solutions = foldr addthread M.empty mtNodes
    addthread node table = foldr appendaction table $ mkActions $ children node
    appendaction (str, node) = M.alter (appendnode node) str
    appendnode node Nothing = Just [node]
    appendnode node (Just nodes) = Just $ node:nodes
    mkSolvedGame (str, mtNodes) = (str, MTMCSolvedGame {mtParams, mtNodes})

instance SolvedGameState MTMCSolvedGame where
  action (MTMCSolvedGame {mtParams, mtNodes = mtNodes@(MCNode {gameState}:_)}) = do
    nodes <- mapConcurrently (timedadvance mtParams) mtNodes
    let multiactions = map (mkActions . children) nodes
        solutions = combinedSolutions multiactions
        (possiblestr, bestval) = objective (comparing snd) solutions
        multiact str = map (fromJust . lookup str) multiactions
        mcplayer (MCNode {gameState}) = player gameState
        player' = mcplayer $ head mtNodes
        objective = playerObjectiveBy player'
        retval str = (str, MTMCSolvedGame {mtParams, mtNodes = multiact str})
        regularval (NodeValue a b) = b /= 0 || a == playerBound player' mtParams
    if regularval bestval then return $ retval possiblestr else do
      let strs = map fst $ filter ((== bestval) . snd) solutions
      str <- lessevilMTMCTS (length mtNodes) mtParams gameState strs
      return $ retval str
  think (MTMCSolvedGame {mtParams, mtNodes}) = do
    funcs <- mapM (advanceuntil mtParams) mtNodes
    return $ do
      mtNodes <- sequence funcs
      return MTMCSolvedGame {mtParams, mtNodes}

-- | The combined values of different thread solutions
combinedSolutions :: [[MCAction]] -> [(String, NodeValue)]
combinedSolutions multiactions = M.toList $ foldr addthread M.empty multiactions where
  addthread actionlist table = foldr aggaction table actionlist
  aggaction (str, node) = M.alter (aggnode node) str
  aggnode node Nothing = Just $ nodeValue node
  aggnode node (Just preval) = Just $ combineValues preval $ nodeValue node

-- | Solve a game with Multithreaded MCTS
mtmctsSolver :: GameState a => Int -> MCParams -> a -> MTMCSolvedGame
mtmctsSolver n mtParams gs = MTMCSolvedGame {mtParams, mtNodes = map (mkLeaf False) $ replicate n gs}

-- | returns the least losing action
lessevilMTMCTS :: GameState a => Int -> MCParams -> a -> [String] -> IO String
lessevilMTMCTS n params gs strs = do
  nodes <- mapConcurrently ((timedadvance $ params {inert = True}) . (mkLeaf False)) $ replicate n gs
  let solutions = combinedSolutions $ map (mkActions . children) nodes
      mcplayer (MCNode {gameState}) = player gameState
      objective = playerObjectiveBy (mcplayer $ head nodes) (comparing snd)
      valids = filter (\(str, _) -> elem str strs) solutions
  return $ fst $ objective valids
-}
