{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.Typechecker.Extractor where

import           Control.Applicative        (Alternative, empty, (<|>))
import           Control.Monad              (MonadPlus, ap, join, liftM, mplus,
                                             mzero)
import           Data.Foldable
import qualified Data.List                  as List
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import qualified Unison.Blank               as B
import           Unison.Reference           (Reference)
import qualified Unison.Typechecker.Context as C
import           Unison.Util.Monoid         (whenM)
import           Debug.Trace

newtype NoteExtractor v loc a = NoteExtractor { runNote :: C.Note v loc -> Maybe a }
newtype PathExtractor v loc a = PathExtractor { runPath :: C.PathElement v loc -> Maybe a }
type SubseqExtractor v loc a = SubseqExtractor' (C.Note v loc) a

subseqExtractor :: (C.Note v loc -> [Ranged a]) -> SubseqExtractor v loc a
subseqExtractor f = SubseqExtractor' f

traceSubseq :: Show a => String -> SubseqExtractor' n a -> SubseqExtractor' n a
traceSubseq s ex = SubseqExtractor' $ \n ->
  let rs = runSubseq ex n in
  trace (if null s then show rs else s ++ ": " ++ show rs) rs

traceNote :: Show a => String -> NoteExtractor v loc a -> NoteExtractor v loc a
traceNote s ex = NoteExtractor $ \n ->
  let result = runNote ex n in
  trace (if null s then show result else s ++ ": " ++ show result) result

unique :: SubseqExtractor v loc a -> NoteExtractor v loc a
unique ex = NoteExtractor $ \note ->
  case runSubseq ex note of
    [Pure a]       -> Just a
    [Ranged a _ _] -> Just a
    _              -> Nothing

data SubseqExtractor' n a =
  SubseqExtractor' { runSubseq :: n -> [Ranged a] }

data Ranged a
  = Pure a
  | Ranged { get :: a, start :: Int, end :: Int }
  deriving (Functor, Ord, Eq, Show)

-- | collects the regions where `xa` doesn't match / aka invert a set of intervals
-- unused, but don't want to delete it yet - Aug 30, 2018
_no :: SubseqExtractor' n a -> SubseqExtractor' n ()
_no xa = SubseqExtractor' $ \note ->
  let as = runSubseq xa note in
    if null [ a | Pure a <- as ] then -- results are not full
      if null as then [Pure ()] -- results are empty, make them full
      -- not full and not empty, find the negation
      else reverse . fst $ foldl' go ([], Nothing) (List.sort $ fmap toPairs as)
    else [] -- results were full, make them empty
  where
  toPairs :: Ranged a -> (Int, Int)
  toPairs (Pure _) = error "this case should be avoided by the if!"
  toPairs (Ranged _ start end) = (start, end)

  go :: ([Ranged ()], Maybe Int) -> (Int, Int) -> ([Ranged ()], Maybe Int)
  go ([], Nothing) (0, r) = ([], Just (r + 1))
  go ([], Nothing) (l, r) = ([Ranged () 0 (l - 1)], Just r)
  go (_:_, Nothing) _    = error "state machine bug in Extractor2.no"
  go (rs, Just r0) (l, r) =
    (if r0 + 1 <= l - 1 then Ranged () (r0 + 1) (l - 1) : rs else rs, Just r)

-- unused / untested
_any :: SubseqExtractor v loc ()
_any = _any' (\n -> pathLength n - 1)
  where
  pathLength :: C.Note v loc -> Int
  pathLength = length . toList . C.path

_any' :: (n -> Int) -> SubseqExtractor' n ()
_any' getLast = SubseqExtractor' $ \note -> Pure () : do
  let last = getLast note
  start <- [0..last]
  end <- [0..last]
  pure $ Ranged () start end


-- unused / untested -- almost definitely wrong
many :: forall n a. Ord a => SubseqExtractor' n a -> SubseqExtractor' n [a]
many xa = SubseqExtractor' $ \note ->
  let as = runSubseq xa note in fmap reverse <$> toList (go Set.empty as)
  where
    -- why is this a set
    go :: Set (Ranged [a]) -> [Ranged a] -> Set (Ranged [a])
    go seen [] = seen
    go seen (rh@(Ranged h start end) : t) =
      let seen' :: Set (Ranged [a])
          seen' = Set.fromList . join . fmap (toList . go' rh) . toList $ seen
      in go (Set.insert (Ranged [h] start end) seen `Set.union` seen') t
    go seen (Pure _ : t) = go seen t
    go' :: Ranged a -> Ranged [a] -> Maybe (Ranged [a])
    go' new group =
      if isAdjacent group new
      then Just (Ranged (get new : get group) (start group) (end new))
      else Nothing
    isAdjacent :: forall a b. Ranged a -> Ranged b -> Bool
    isAdjacent (Ranged _ _ endA) (Ranged _ startB _) = endA + 1 == startB
    isAdjacent _ _                                   = False

pathStart :: SubseqExtractor' n ()
pathStart = SubseqExtractor' $ \_ -> [Ranged () (-1) (-1)]

-- Scopes --
asPathExtractor :: (C.PathElement v loc -> Maybe a) -> SubseqExtractor v loc a
asPathExtractor = fromPathExtractor . PathExtractor
  where
    fromPathExtractor :: PathExtractor v loc a -> SubseqExtractor v loc a
    fromPathExtractor ex = subseqExtractor $
      join . fmap go . (`zip` [0..]) . toList . C.path
      where go (e,i) = case runPath ex e of
              Just a  -> [Ranged a i i]
              Nothing -> []

inSynthesize :: SubseqExtractor v loc (C.Term v loc)
inSynthesize = asPathExtractor $ \case
  C.InSynthesize t -> Just t
  _ -> Nothing

inSubtype :: SubseqExtractor v loc (C.Type v loc, C.Type v loc)
inSubtype = asPathExtractor $ \case
  C.InSubtype found expected -> Just (found, expected)
  _ -> Nothing

inCheck :: SubseqExtractor v loc (C.Term v loc, C.Type v loc)
inCheck = asPathExtractor $ \case
  C.InCheck e t -> Just (e,t)
  _ -> Nothing

-- inInstantiateL
-- inInstantiateR

inSynthesizeApp :: SubseqExtractor v loc (C.Type v loc, C.Term v loc, Int)
inSynthesizeApp = asPathExtractor $ \case
  C.InSynthesizeApp t e n -> Just (t,e,n)
  _ -> Nothing

inFunctionCall :: SubseqExtractor v loc ([v], C.Term v loc, C.Type v loc, [C.Term v loc])
inFunctionCall = asPathExtractor $ \case
  C.InFunctionCall vs f ft e -> Just (vs, f, ft, e)
  _ -> Nothing

inAndApp, inOrApp, inIfCond, inMatchGuard, inMatchBody :: SubseqExtractor v loc ()
inAndApp = asPathExtractor $ \case C.InAndApp -> Just (); _ -> Nothing
inOrApp  = asPathExtractor $ \case C.InOrApp  -> Just (); _ -> Nothing
inIfCond = asPathExtractor $ \case C.InIfCond -> Just (); _ -> Nothing
inMatchGuard = asPathExtractor $ \case C.InMatchGuard -> Just (); _ -> Nothing
inMatchBody = asPathExtractor $ \case C.InMatchBody -> Just (); _ -> Nothing

inMatch, inVector, inIfBody :: SubseqExtractor v loc loc
inMatch = asPathExtractor $ \case C.InMatch loc -> Just loc; _ -> Nothing
inVector = asPathExtractor $ \case C.InVectorApp loc -> Just loc; _ -> Nothing
inIfBody = asPathExtractor $ \case C.InIfBody loc -> Just loc; _ -> Nothing

-- Causes --
cause :: NoteExtractor v loc (C.Cause v loc)
cause = NoteExtractor $ pure . C.cause

typeMismatch :: NoteExtractor v loc (C.Context v loc)
typeMismatch = cause >>= \case
  C.TypeMismatch c -> pure c
  _ -> mzero

illFormedType :: NoteExtractor v loc (C.Context v loc)
illFormedType = cause >>= \case
  C.IllFormedType c -> pure c
  _ -> mzero

unknownSymbol :: NoteExtractor v loc (loc, v)
unknownSymbol = cause >>= \case
  C.UnknownSymbol loc v -> pure (loc, v)
  _ -> mzero

unknownTerm :: NoteExtractor v loc (loc, v, [C.Suggestion v loc], C.Type v loc)
unknownTerm = cause >>= \case
  C.UnknownTerm loc v suggestions expectedType -> pure (loc, v, suggestions, expectedType)
  _ -> mzero

abilityCheckFailure :: NoteExtractor v loc ([C.Type v loc], [C.Type v loc], C.Context v loc)
abilityCheckFailure = cause >>= \case
  C.AbilityCheckFailure ambient requested ctx -> pure (ambient, requested, ctx)
  _ -> mzero

effectConstructorWrongArgCount :: NoteExtractor v loc (C.ExpectedArgCount, C.ActualArgCount, Reference, C.ConstructorId)
effectConstructorWrongArgCount = cause >>= \case
  C.EffectConstructorWrongArgCount expected actual r cid -> pure (expected, actual, r, cid)
  _ -> mzero

malformedEffectBind :: NoteExtractor v loc (C.Type v loc, C.Type v loc, [C.Type v loc])
malformedEffectBind = cause >>= \case
  C.MalformedEffectBind ctor ctorResult es -> pure (ctor, ctorResult, es)
  _ -> mzero

solvedBlank :: NoteExtractor v loc (B.Recorded loc, v, C.Type v loc)
solvedBlank = cause >>= \case
  C.SolvedBlank b v t -> pure (b, v, t)
  _ -> mzero

-- Misc --
note :: NoteExtractor v loc (C.Note v loc)
note = NoteExtractor $ Just . id

innermostTerm :: NoteExtractor v loc (C.Term v loc)
innermostTerm = NoteExtractor $ \n -> case C.innermostErrorTerm n of
  Just e  -> pure e
  Nothing -> mzero

path :: NoteExtractor v loc [C.PathElement v loc]
path = NoteExtractor $ pure . toList . C.path

-- Instances --
instance Functor (NoteExtractor v loc) where
  fmap = liftM

instance Applicative (NoteExtractor v loc) where
  (<*>) = ap
  pure = return

instance Monad (NoteExtractor v loc) where
  fail _s = empty
  return a = NoteExtractor (\_ -> Just a)
  NoteExtractor r >>= f = NoteExtractor go
    where
      go note = case r note of
        Nothing -> Nothing
        Just a  -> runNote (f a) note

instance Alternative (NoteExtractor v loc) where
  empty = mzero
  (<|>) = mplus

instance MonadPlus (NoteExtractor v loc) where
  mzero = NoteExtractor (\_ -> Nothing)
  mplus (NoteExtractor f1) (NoteExtractor f2) =
    NoteExtractor (\note -> f1 note `mplus` f2 note)

instance Functor (SubseqExtractor' n) where
  fmap = liftM

instance Applicative (SubseqExtractor' n) where
  pure = return
  (<*>) = ap

instance Monad (SubseqExtractor' n) where
  fail _ = mzero
  return a = SubseqExtractor' $ \_ -> [Pure a]
  xa >>= f = SubseqExtractor' $ \note ->
    let as = runSubseq xa note in do
      ra <- as
      case ra of
        Pure a -> runSubseq (f a) note
        Ranged a startA endA ->
          let rbs = runSubseq (f a) note in do
            rb <- rbs
            case rb of
              Pure b -> pure (Ranged b startA endA)
              Ranged b startB endB ->
                -- trace ("(" ++ show startA ++ "," ++ show endA ++ ") -> (" ++ show startB ++ "," ++ show endB ++ ")")
                whenM (startB == endA + 1) (pure (Ranged b startA endB))

instance Alternative (SubseqExtractor' n) where
  empty = mzero
  (<|>) = mplus

instance MonadPlus (SubseqExtractor' n) where
  mzero = SubseqExtractor' $ \_ -> []
  mplus (SubseqExtractor' f1) (SubseqExtractor' f2) =
    SubseqExtractor' (\n -> f1 n `mplus` f2 n)

instance Monoid (SubseqExtractor' n a) where
  mempty = mzero
  mappend = mplus

instance Semigroup (SubseqExtractor' n a) where
  (<>) = mappend
