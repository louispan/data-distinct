{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Data.Diverse.Nary.Internal (
    -- * 'Nary' type
      Nary(..) -- Exporting constructor unsafely!

      -- * Construction
    , blank
    , (.|)
    , singleton
    , prefix
    , (./)
    , postfix
    , (\.)
    , append
    , (/./)

    -- * Simple queries
    , front
    , back
    , aft
    , fore

    -- * Single field
    -- ** Getter for single field
    , fetch
    , (.^.)
    , fetchN
    , (!^.)
    , fetchL
    , (#^.)
    -- ** Setter for single field
    , replace
    , (..~)
    , replaceN
    , (!.~)
    , replaceL
    , (#.~)
    -- ** Lens for a single field
    , item
    , itemN
    , itemL

    -- * Multiple fields
    -- ** Getter for multiple fields
    , Narrow
    , narrow
    , (\^.)
    , NarrowN
    , narrowN
    , (!\^.)
    , NarrowL
    , narrowL
    , (#\^.)
    -- ** Setter for multiple fields
    , Amend
    , amend
    , (\.~)
    , AmendN
    , amendN
    , (!\.~)
    , AmendL
    , amendL
    , (#\.~)
    -- ** Lens for multiple fields
    , project
    , projectN
    , projectL

    -- * Destruction
    -- ** By type
    , Via -- no constructor
    , via -- safe construction
    , forNary
    , collect
    -- * By Nat index offset
    , ViaN -- no constructor
    , viaN -- safe construction
    , forNaryN
    , collectN
    ) where

import Control.Applicative
import Control.Lens
import Data.Bool
import Data.Diverse.AFoldable
import Data.Diverse.Case
import Data.Diverse.Collector
import Data.Diverse.Emit
import Data.Diverse.Reiterate
import Data.Diverse.Type
import Data.Kind
import qualified Data.Map.Strict as M
import Data.Proxy
import GHC.Prim (Any, coerce)
import GHC.TypeLits
import Text.ParserCombinators.ReadPrec
import Text.Read
import qualified Text.Read.Lex as L
import Unsafe.Coerce

-- This module uses the partial 'head', 'tail' from Prelude.
-- I like to highlight them as partial by using them in the namespace Partial.head
-- These usages in this are safe due to size guarantees provided by the typelist
-- as long as the initial of the list matches the typelist.
import Prelude as Partial

newtype Key = Key Int deriving (Eq, Ord, Show)
newtype LeftOffset = LeftOffset Int
newtype LeftSize = LeftSize Int
newtype RightOffset = RightOffset Int
newtype NewRightOffset = NewRightOffset { unNewRightOffset :: Int }

-- | A Nary is an anonymous product type (also know as polymorphic record), with the ability to contain
-- an arbitrary number of fields.
-- When it has fields of distinct types, extra functions applied via TypeApplications
-- become available to be used:
--
-- * 'fetch' and 'replace' getter/setter functions
-- * 'narrow' and 'amend' getter/setter of multiple fields
--
-- This means labels are not required, since the type itself (with type annotations or -XTypeApplications)
-- can be used to get and set fields in the Nary.
-- It is a compile error to use those functions if there are duplicate fields.
-- For duplicate fields, there are indexed version of the gettter/setter functions.
--
-- This encoding stores the fields as Any in a Map, where the key is index + offset of the type in the typelist.
-- The offset is used to allow efficient cons.
--
-- @Key = Index of type in typelist + Offset@
--
-- The constructor will guarantee the correct number and types of the elements.
data Nary (xs :: [Type]) = Nary {-# UNPACK #-} !Int (M.Map Key Any)

-- | Inferred role is phantom which is incorrect
type role Nary representational

-----------------------------------------------------------------------

-- | When appending two maps together, get the function to 'M.mapKeys' the RightMap
-- when adding RightMap into LeftMap.
-- The existing contents of LeftMap will not be changed.
-- LeftMap Offset will also not change.
-- The desired key for element from the RightMap = RightIndex (of the element) + LeftOffset + LeftSize
-- OldRightKey = RightIndex + RightOffset, therefore RightIndex = OldRightKey - RightOffset
-- So we need to adjust the existing index on the RightMap by
-- \OldRightKey -> RightIndex + LeftOffset + LeftSize (as above)
-- \OldRightKey -> OldRightKey - RightOffset + LeftOffset + LeftSize
rightKeyForSnoc :: LeftOffset -> LeftSize -> RightOffset -> Key -> Key
rightKeyForSnoc (LeftOffset lo) (LeftSize ld) (RightOffset ro) (Key rk) =
    Key (rk - ro + lo + ld)

-- | When appending two maps together, get the function to modify the RightMap's offset
-- when adding LeftMap into RightMap.
-- The existing contents of RightMap will not be changed.
-- NewRightOffset = OldRightOffset - LeftSize
rightOffsetForCons :: LeftSize -> RightOffset -> NewRightOffset
rightOffsetForCons (LeftSize ld) (RightOffset ro) = NewRightOffset (ro - ld)

-- | When appending two maps together, get the function to 'M.mapKeys' the LeftMap
-- when adding LeftMap into RightMap.
-- The existing contents of RightMap will not be changed.
-- The RightMap's offset will be adjusted using 'rightOffsetWithRightMapUnchanged'
-- The desired key for the elements in the the LeftMap = LeftIndex (of the element) + NewRightOffset
-- OldLeftKey = LeftIndex + LeftOffset, therefore LeftIndex = OldLeftKey - LeftOffset
-- So we need to adjust the existing index on the LeftMap by
-- \OldLeftKey -> LeftIndex + NewRightOffset (as above)
-- \OldLeftKey -> OldLeftKey - LeftOffset + NewRightOffset (as above)
leftKeyForCons :: LeftOffset -> NewRightOffset -> Key -> Key
leftKeyForCons (LeftOffset lo) (NewRightOffset ro) (Key lk) = Key (lk - lo + ro)

-- | Analogous to 'Prelude.null'. Named 'blank' to avoid conflicting with 'Prelude.null'.
blank :: Nary '[]
blank = Nary 0 M.empty
infixr 5 `blank` -- to be the same as cons

-- | 'blank' memonic: A blank wall '.|' stops.
(.|) :: Nary '[]
(.|) = blank

-- | Create a Nary from a single value. Analogous to 'M.singleton'
singleton :: x -> Nary '[x]
singleton v = Nary 0 (M.singleton (Key 0) (unsafeCoerce v))

-- | Add an element to the left of a Nary.
-- Not named 'cons' to avoid conflict with lens.
prefix :: x -> Nary xs -> Nary (x ': xs)
prefix x (Nary ro rm) = Nary (unNewRightOffset nro)
    (M.insert
        (leftKeyForCons (LeftOffset 0) nro (Key 0))
        (unsafeCoerce x)
        rm)
  where
    nro = rightOffsetForCons (LeftSize 1) (RightOffset ro)
infixr 5 `prefix`

-- | 'prefix' mnemonic: Element is smaller than './' the larger Nary
(./) :: x -> Nary xs -> Nary (x ': xs)
(./) = prefix
infixr 5 ./ -- like Data.List.(:)

-- | Add an element to the right of a Nary
-- Not named 'snoc' to avoid conflict with lens
postfix :: Nary xs -> y -> Nary (Concat xs '[y])
postfix (Nary lo lm) y = Nary lo
    (M.insert (rightKeyForSnoc (LeftOffset lo) (LeftSize (M.size lm)) (RightOffset 0) (Key 0))
        (unsafeCoerce y)
        lm)
infixl 5 `postfix`

-- | 'snoc' mnemonic: Nary is larger '\.' than the smaller element
(\.) :: Nary xs -> y -> Nary (Concat xs '[y])
(\.) = postfix
infixl 5 \.

-- | 'append' mnemonic: 'cons' './' with an extra slash (meaning 'Nary') in front.
(/./) :: Nary xs -> Nary ys -> Nary (Concat xs ys)
(/./) = append
infixl 5 /./

-- | Contains two Narys together
append :: Nary xs -> Nary ys -> Nary (Concat xs ys)
append (Nary lo lm) (Nary ro rm) = if ld >= rd
    then Nary
         lo
         (lm `M.union` (M.mapKeys (rightKeyForSnoc (LeftOffset lo) (LeftSize ld) (RightOffset ro)) rm))
    else Nary
         (unNewRightOffset nro)
         ((M.mapKeys (leftKeyForCons (LeftOffset lo) nro) lm) `M.union` rm)
  where
    ld = M.size lm
    rd = M.size rm
    nro = rightOffsetForCons (LeftSize ld) (RightOffset ro)
infixr 5 `append` -- like Data.List (++)

-----------------------------------------------------------------------

-- | Extract the first element of a Nary, which guaranteed to be non-empty.
-- Analogous to 'Partial.head'
front :: Nary (x ': xs) -> x
front (Nary o m) = unsafeCoerce (m M.! (Key o))

-- | Extract the 'back' element of a Nary, which guaranteed to be non-empty.
-- Analogous to 'Prelude.last'
back :: Nary (x ': xs) -> x
back (Nary o m) = unsafeCoerce (m M.! (Key (M.size m + o)))

-- | Extract the elements after the front of a Nary, which guaranteed to be non-empty.
-- Analogous to 'Partial.tail'
aft :: Nary (x ': xs) -> Nary xs
aft (Nary o m) = Nary (o + 1) (M.delete (Key o) m)

-- | Return all the elements of a Nary except the 'back' one, which guaranteed to be non-empty.
-- Analogous to 'Prelude.init'
fore :: Nary xs -> Nary (Init xs)
fore (Nary o m) = Nary o (M.delete (Key (o + M.size m - 1)) m)

--------------------------------------------------

-- | Getter. Use TypeApplication of the type to get
-- Only available for 'Nary' with 'Distinct' xs.
--
-- @fetch \@Int t@
fetch :: forall x xs. (Distinct xs, KnownNat (IndexOf x xs)) => Nary xs -> x
fetch (Nary o m) = unsafeCoerce (m M.! (Key (o + i)))
  where i = fromInteger (natVal @(IndexOf x xs) Proxy)

-- | infix version of 'fetch', with a extra proxy to carry the destination type.
--
-- @foo .^. (Proxy \@Int)@
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra @.@ in front.
(.^.) :: forall x xs proxy. (Distinct xs, KnownNat (IndexOf x xs)) => Nary xs -> proxy x -> x
(.^.) v _ = fetch v
infixl 8 .^. -- like Control.Lens.(^.)

--------------------------------------------------

-- | Getter. Get the value of the field at index type-level Nat @n@
--
-- @getchN (Proxy \@2) t@
fetchN :: forall n xs x proxy. (KnownNat n, WithinBounds n xs, x ~ KindAtIndex n xs) => proxy n -> Nary xs -> x
fetchN p (Nary o m) = unsafeCoerce (m M.! (Key (o + i)))
  where i = fromInteger (natVal p)

-- | infix version of 'flip fetchN'
--
-- @foo !^. (Proxy \@2)@
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra @!@ in front.
(!^.) :: forall n xs x proxy. (KnownNat n, WithinBounds n xs, x ~ KindAtIndex n xs) => Nary xs -> proxy n -> x
(!^.) = flip fetchN
infixl 8 !^. -- like Control.Lens.(^.)

--------------------------------------------------

-- | Getter. Get the tagged field with Label @label@
-- This will get the field of type @tagged label value@
-- NB. This returns the entire tagged field, not the untagged value
-- so that any Tagged library can be used.
--
-- @fetchL (Proxy \@"foo") t@
fetchL
    :: forall l xs x proxy.
       (KnownNat (IndexAtLabel l xs), Distinct (LabelsOf xs), x ~ KindAtLabel l xs)
    => proxy l -> Nary xs -> x
fetchL _ (Nary o m) = unsafeCoerce (m M.! (Key (o + i)))
  where i = fromInteger (natVal @(IndexAtLabel l xs) Proxy)

-- | infix version of 'flip fetchL'
--
-- @foo #^. (Proxy \@"foo")@
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra @#@ in front.
(#^.) :: forall l xs x proxy.
       (KnownNat (IndexAtLabel l xs), Distinct (LabelsOf xs), x ~ KindAtLabel l xs)
    => Nary xs -> proxy l -> x
(#^.) = flip fetchL
infixl 8 #^. -- like Control.Lens.(^.)

--------------------------------------------------

-- | Setter. Use TypeApplication of the type to set.
--
-- @replace \@Int t@
--
replace :: forall x xs. (Distinct xs, KnownNat (IndexOf x xs)) => Nary xs -> x -> Nary xs
replace (Nary o m) v = Nary o (M.insert (Key (o + i)) (unsafeCoerce v) m)
  where i = fromInteger (natVal @(IndexOf x xs) Proxy)

-- | infix version of 'replace'
-- Only available for 'Nary' with 'Distinct' xs.
--
-- @foo ..~ x@
--
-- Mnemonic: Like 'Control.Lens.(.~)' but with an extra @.@ in front.
(..~) :: forall x xs. (Distinct xs, KnownNat (IndexOf x xs)) => Nary xs -> x -> Nary xs
(..~) = replace
infixl 1 ..~ -- like Control.Lens.(.~)

--------------------------------------------------

-- | Setter. Use TypeApplication of the Nat index to set.
--
-- @replaceN (Proxy \@1) t@
--
replaceN :: forall n xs x proxy. (KnownNat n, WithinBounds n xs, x ~ KindAtIndex n xs) => proxy n -> Nary xs -> x -> Nary xs
replaceN p (Nary o m) v = Nary o (M.insert (Key (o + i)) (unsafeCoerce v) m)
  where i = fromInteger (natVal p)

-- | infix version of 'flip replaceN'
--
-- @foo !.~ (Proxy \@2)@
--
-- Mnemonic: Like 'Control.Lens.(.~)' but with an extra @!@ in front.
(!.~) :: forall n xs x proxy. (KnownNat n, WithinBounds n xs, x ~ KindAtIndex n xs) => Nary xs -> proxy n -> x -> Nary xs
(!.~) = flip replaceN
infixl 1 !.~ -- like Control.Lens.(.~)

-----------------------------------------------------------------------

-- | Setter. Use TypeApplication of the @label@ to set.
-- This will set the field of type @tagged label value@
--
-- @replaceL (Proxy \@"foo") t@
--
replaceL :: forall l xs x proxy.
       (KnownNat (IndexAtLabel l xs), Distinct (LabelsOf xs), x ~ KindAtLabel l xs)
    => proxy l -> Nary xs -> x -> Nary xs
replaceL _ (Nary o m) v = Nary o (M.insert (Key (o + i)) (unsafeCoerce v) m)
  where i = fromInteger (natVal @(IndexAtLabel l xs) Proxy)

-- | infix version of 'flip replaceL'
--
-- @foo #.~ (Proxy \@"foo")@
--
-- Mnemonic: Like 'Control.Lens.(.~)' but with an extra @#@ in front.
(#.~) :: forall l xs x proxy.
       (KnownNat (IndexAtLabel l xs), Distinct (LabelsOf xs), x ~ KindAtLabel l xs)
    => Nary xs -> proxy l -> x -> Nary xs
(#.~) = flip replaceL
infixl 1 #.~ -- like Control.Lens.(.~)

-----------------------------------------------------------------------
-- | 'fetch' and 'replace' in lens form.
-- Use TypeApplication to specify the field type of the lens.
-- Example: @item \@Int@
item :: forall x xs. (Distinct xs, KnownNat (IndexOf x xs)) => Lens' (Nary xs) x
item = lens fetch replace
{-# INLINE item #-}

-- | 'fetchN' and 'replaceN' in lens form.
-- You can use TypeApplication to specify the index of the type of the lens.
-- Example: @itemN \@1 Proxy@
itemN ::  forall n xs x proxy. (KnownNat n, WithinBounds n xs, x ~ KindAtIndex n xs) => proxy n -> Lens' (Nary xs) x
itemN p = lens (fetchN p) (replaceN p)
{-# INLINE itemN #-}

-- | 'fetchL' and 'replaceL' in lens form.
-- Use TypeApplication to specify the index of the type of the lens.
-- Example: @itemL \@1 Proxy@
itemL :: forall l xs x proxy.
       (KnownNat (IndexAtLabel l xs), Distinct (LabelsOf xs), x ~ KindAtLabel l xs)
    => proxy l -> Lens' (Nary xs) x
itemL p = lens (fetchL p) (replaceL p)
{-# INLINE itemL #-}

-----------------------------------------------------------------------

-- | Internal function for construction - do not expose!
fromList' :: Ord k => [(k, WrappedAny)] -> M.Map k Any
fromList' xs = M.fromList (coerce xs)

-- | Wraps a 'Case' into an instance of 'Emit', feeding 'Case' with the value from the Nary and 'emit'ting the results.
-- Internally, this holds the left-over [(k, v)] from the original Nary with the remaining typelist xs.
-- That is the first v in the (k, v) is of type x, and the length of the list is equal to the length of xs.
newtype Via c (xs :: [Type]) r = Via (c xs r, [Any])

-- | Creates an 'Via' safely, so that the invariant of \"typelist to the value list type and size\" holds.
via :: forall xs c r. c xs r -> Nary xs -> Via c xs r
via c (Nary _ m) = Via (c, snd <$> M.toAscList m)

instance Reiterate c (x ': xs) => Reiterate (Via c) (x ': xs) where
    -- use of tail here is safe as we are guaranteed the length from the typelist
    reiterate (Via (c, xxs)) = Via (reiterate c, Partial.tail xxs)

instance (Case c (x ': xs) r) => Emit (Via c) (x ': xs) r where
    emit (Via (c, xxs)) = case' c (unsafeCoerce v)
      where
       -- use of front here is safe as we are guaranteed the length from the typelist
       v = Partial.head xxs

-- | Destruction for any 'Nary', even with indistinct types.
-- Given a distinct handler for the fields in 'Nary', create a 'Collector'
-- of the results of running the handler over the 'Nary'.
-- The 'Collector' is 'AFoldable' to get the results.
forNary :: c xs r -> Nary xs -> Collector (Via c) xs r
forNary c x = Collector (via c x)

-- | This is @flip forNary@
collect :: Nary xs -> c xs r -> Collector (Via c) xs r
collect = flip forNary

-----------------------------------------------------------------------

newtype ViaN c (n :: Nat) (xs :: [Type]) r = ViaN (c n xs r, [Any])

-- | Creates an 'ViaN' safely, so that the invariant of \"typelist to the value list type and size\" holds.
viaN :: forall n xs c r. c n xs r -> Nary xs -> ViaN c n xs r
viaN c (Nary _ m) = ViaN (c, snd <$> M.toAscList m)

instance ReiterateN c n (x ': xs) => ReiterateN (ViaN c) n (x ': xs) where
    -- use of tail here is safe as we are guaranteed the length from the typelist
    reiterateN (ViaN (c, xxs)) = ViaN (reiterateN c, Partial.tail xxs)

instance (Case (c n) (x ': xs) r) => Emit (ViaN c n) (x ': xs) r where
    emit (ViaN (c, xxs)) = case' c (unsafeCoerce v)
      where
       -- use of front here is safe as we are guaranteed the length from the typelist
       v = Partial.head xxs

forNaryN :: c n xs r -> Nary xs -> CollectorN (ViaN c) n xs r
forNaryN c x = CollectorN (viaN c x)

-- | This is @flip forNaryN@
collectN :: Nary xs -> c n xs r -> CollectorN (ViaN c) n xs r
collectN = flip forNaryN

-----------------------------------------------------------------------

type Narrow (smaller :: [Type]) (larger :: [Type]) =
    (AFoldable
        ( Collector (Via (CaseNarrow smaller)) larger) [(Key, WrappedAny)]
        , Distinct larger
        , Distinct smaller)

-- | Construct a 'Nary' with a smaller number of fields than the original
-- Analogous to 'fetch' getter but for multiple fields
-- Specify a typelist of fields to 'narrow' into.
--
-- @narrow \@[Int,Bool] t@
narrow :: forall smaller larger. Narrow smaller larger => Nary larger -> Nary smaller
narrow t = Nary 0 (fromList' xs')
  where
    xs' = afoldr (++) [] (forNary (CaseNarrow @smaller @larger) t)

-- | infix version of 'narrow', with a extra proxy to carry the @smaller@ type.
--
-- @foo \^. (Proxy @'[Int, Bool])@
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra '\' (narrow to the right) in front.
(\^.) :: forall smaller larger proxy. Narrow smaller larger => Nary larger -> proxy smaller -> Nary smaller
(\^.) t _ = narrow t
infixl 8 \^. -- like Control.Lens.(^.)

-- | For each type x in @larger@, generate the (k, v) in @smaller@ (if it exists)
data CaseNarrow (smaller :: [Type]) (xs :: [Type]) r = CaseNarrow

instance Reiterate (CaseNarrow smaller) (x ': xs) where
    reiterate CaseNarrow = CaseNarrow

-- | For each type x in larger, find the index in ys, and create an (incrementing key, value)
instance forall smaller x xs. KnownNat (PositionOf x smaller) =>
         Case (CaseNarrow smaller) (x ': xs) [(Key, WrappedAny)] where
    case' _ v =
        case i of
            0 -> []
            i' -> [(Key (i' - 1), WrappedAny (unsafeCoerce v))]
      where
        i = fromInteger (natVal @(PositionOf x smaller) Proxy)

-----------------------------------------------------------------------

type NarrowN (ns :: [Nat]) (smaller ::[Type]) (larger :: [Type]) =
    ( AFoldable (CollectorN (ViaN (CaseNarrowN ns)) 0 larger) [(Key, WrappedAny)]
    , smaller ~ KindsAtIndices ns larger
    , Distinct ns)

-- | Construct a 'Nary' with a smaller number of fields than the original
-- Analogous to 'fetchN' getter but for multiple fields
-- Specify a Nat-list mapping to 'narrowN' into,
-- where indices[smaller_idx] = larger_idx
--
-- @narrowN \@[6,2] Proxy t@
narrowN :: forall ns smaller larger proxy. (NarrowN ns smaller larger) => proxy ns -> Nary larger -> Nary smaller
narrowN _ xs = Nary 0 (fromList' xs')
  where
    xs' = afoldr (++) [] (forNaryN (CaseNarrowN @ns @0 @larger) xs)

-- | infix version of 'flip narrowN'
--
-- @foo !\^. (Proxy @'[6, 3])@
--
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra '!\' (indexed, narrow to the right) in front.
(!\^.) :: forall ns smaller larger proxy. (NarrowN ns smaller larger) => Nary larger -> proxy ns -> Nary smaller
(!\^.) = flip narrowN
infixl 8 !\^. -- like Control.Lens.(^.)

data CaseNarrowN (indices :: [Nat]) (n :: Nat) (xs :: [Type]) r = CaseNarrowN

instance ReiterateN (CaseNarrowN indices) n (x ': xs) where
    reiterateN CaseNarrowN = CaseNarrowN

-- | For each type x in @larger@, find the index in ys, and create an (incrementing key, value)
instance forall indices n x xs. KnownNat (PositionOf n indices) =>
         Case (CaseNarrowN indices n) (x ': xs) [(Key, WrappedAny)] where
    case' _ v =
        case i of
            0 -> []
            i' -> [(Key (i' - 1), WrappedAny (unsafeCoerce v))]
      where
        i = fromInteger (natVal @(PositionOf n indices) Proxy)

-----------------------------------------------------------------------

type NarrowL ls smaller larger = (AFoldable
                         ( Collector (Via (CaseNarrowL ls)) larger) [(Key, WrappedAny)]
                         , smaller ~ KindsAtLabels ls larger
                         , Distinct (LabelsOf larger))

-- | Construct a 'Nary' with a smaller number of fields than the original
-- Analogous to 'fetchL' getter but for multiple fields
-- Specify a typelist of labels to 'narrowL' into,
-- where labels[smaller_idx] = label of larger
--
-- @narrowL (Proxy \@["foo",Int]) t@
narrowL
    :: forall ls smaller larger proxy.
       (NarrowL ls smaller larger)
    => proxy ls -> Nary larger -> Nary smaller
narrowL _ xs = Nary 0 (fromList' xs')
  where
    xs' = afoldr (++) [] (forNary (CaseNarrowL @ls @larger) xs)

-- | infix version of 'flip narrowL'
--
-- @foo !\^. (Proxy @'[6, 3])@
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra '#\' (labelled, narrow to the right) in front.
(#\^.)
    :: forall ls smaller larger proxy.
       (NarrowL ls smaller larger)
    => Nary larger -> proxy ls -> Nary smaller
(#\^.) = flip narrowL
infixl 8 #\^. -- like Control.Lens.(^.)

data CaseNarrowL (ls :: [k]) (larger :: [Type]) r = CaseNarrowL

instance Reiterate (CaseNarrowL ls) (tagged l x ': xs) where
    reiterate CaseNarrowL = CaseNarrowL

-- | For each type x in @larger@, find the index in ys, and create an (incrementing key, value)
instance KnownNat (IndexAtLabel l ls) =>
         Case (CaseNarrowL ls) (tagged l x ': xs) [(Key, WrappedAny)] where
    case' _ v =
        case i of
            0 -> []
            i' -> [(Key (i' - 1), WrappedAny (unsafeCoerce v))]
      where
        i = fromInteger (natVal @(IndexAtLabel l ls) Proxy)

-----------------------------------------------------------------------

type Amend smaller larger = (AFoldable (Collector (Via (CaseAmend larger)) smaller) (Key, WrappedAny)
       , Distinct larger
       , Distinct smaller)

-- | Sets the subset of  'Nary' in the larger 'Nary'
-- Analogous to 'replace' setter but for multiple fields.
-- Specify a typelist of fields to 'amend'.
--
-- @amend \@[Int,Bool] t1 t2@
amend :: forall smaller larger. Amend smaller larger => Nary larger -> Nary smaller -> Nary larger
amend (Nary lo lm) t = Nary lo (fromList' xs' `M.union` lm)
  where
    xs' = afoldr (:) [] (forNary (CaseAmend @larger @smaller lo) t)

-- | infix version of 'amend'. Mnemonic: Like 'Control.Lens.(.~)' but with an extra '\' (narrow to the right) in front.
--
-- @t1 \.~ t2
--
-- Mnemonic: Like 'Control.Lens.(^.)' but with an extra '\' (narrow to the right) in front.
(\.~) :: forall smaller larger. Amend smaller larger => Nary larger -> Nary smaller -> Nary larger
(\.~) = amend
infixl 1 \.~ -- like Control.Lens.(.~)

newtype CaseAmend (larger :: [Type]) (xs :: [Type]) r = CaseAmend Int

instance Reiterate (CaseAmend larger) (x ': xs) where
    reiterate (CaseAmend lo) = CaseAmend lo

-- | for each x in @smaller@, convert it to a (k, v) to insert into the x in @Nary larger@
instance KnownNat (IndexOf x larger) => Case (CaseAmend larger) (x ': xs) (Key, WrappedAny) where
    case' (CaseAmend lo) v = (Key (lo + i), WrappedAny (unsafeCoerce v))
      where
        i = fromInteger (natVal @(IndexOf x larger) Proxy)

-----------------------------------------------------------------------

type AmendN ns smaller larger =
    ( AFoldable (CollectorN (ViaN (CaseAmendN ns)) 0 smaller) (Key, WrappedAny)
    , smaller ~ KindsAtIndices ns larger
    , Distinct ns)

-- | Sets the subset of  'Nary' in the larger 'Nary'
-- Analogous to 'replaceN' setter but for multiple fields.
-- Specify a Nat-list mapping to 'amendN' into,
-- where indices[smaller_idx] = larger_idx
--
-- @amendN \@[6,2] Proxy t1 t2@
amendN :: forall ns smaller larger proxy.
       (AmendN ns smaller larger)
    => proxy ns -> Nary larger -> Nary smaller -> Nary larger
amendN _ (Nary lo lm) t = Nary lo (fromList' xs' `M.union` lm)
  where
    xs' = afoldr (:) [] (forNaryN (CaseAmendN @ns @0 @smaller lo) t)

-- | infix version of 'flip amendN'. Mnemonic. Like 'Control.Lens.(.~)' but with an extra '!\' (index, narrow to the right) in front.
-- Specify a Nat-list of fields to 'amendN' into.
--
-- @t1 !\.~ (Proxy \@[6,2])@
(!\.~) :: forall ns smaller larger proxy.
       (AmendN ns smaller larger)
    => Nary larger -> proxy ns -> Nary smaller -> Nary larger
(!\.~) = flip amendN
infixl 1 !\.~ -- like Control.Lens.(.~)

newtype CaseAmendN (indices :: [Nat]) (n :: Nat) (xs :: [Type]) r = CaseAmendN Int

instance ReiterateN (CaseAmendN indices) n (x ': xs) where
    reiterateN (CaseAmendN lo) = CaseAmendN lo

-- | for each x in @smaller@, convert it to a (k, v) to insert into the x in @larger@
instance (KnownNat (KindAtIndex n indices)) =>
         Case (CaseAmendN indices n) (x ': xs) (Key, WrappedAny) where
    case' (CaseAmendN lo) v = (Key (lo + i), WrappedAny (unsafeCoerce v))
      where
        i = fromInteger (natVal @(KindAtIndex n indices) Proxy)

-----------------------------------------------------------------------

type AmendL ls smaller larger =
    ( AFoldable (Collector (Via (CaseAmendL (LabelsOf larger))) smaller) (Key, WrappedAny)
    , smaller ~ KindsAtLabels ls larger
    , Distinct (LabelsOf larger))

-- | Sets the subset of  'Nary' in the larger 'Nary'
-- Analogous to 'replaceL' setter but for multiple fields.
-- Specify a typelist of Labels to 'amendL' into,
-- where labels[smaller_idx] = label of larger
--
-- @amendL \@["foo",Int] Proxy t1 t2@
amendL
    :: forall ls smaller larger proxy.
       (AmendL ls smaller larger)
    => proxy ls -> Nary larger -> Nary smaller -> Nary larger
amendL _ (Nary lo lm) t = Nary lo (fromList' xs' `M.union` lm)
  where
    xs' = afoldr (:) [] (forNary (CaseAmendL @(LabelsOf larger) @smaller lo) t)

-- | infix version of 'flip amendL'. Mnemonic. Like 'Control.Lens.(.~)' but with an extra '#\' (labelled, narrow to the right) in front.
-- Specify a typelist of Labels of the original fields to 'amendL' into.
--
-- @t1 #\.~ (Proxy \@["foo",Int])@
(#\.~) :: forall ls smaller larger proxy.
       (AmendL ls smaller larger)
    => Nary larger -> proxy ls -> Nary smaller -> Nary larger
(#\.~) = flip amendL
infixl 1 #\.~ -- like Control.Lens.(.~)

newtype CaseAmendL (ls :: [k]) (xs :: [Type]) r = CaseAmendL Int

instance Reiterate (CaseAmendL ls) (tagged l x ': xs) where
    reiterate (CaseAmendL lo) = CaseAmendL lo

-- | for each x in @smaller@, convert it to a (k, v) to insert into the x in @larger@
instance KnownNat (IndexAtLabel l ls) =>
         Case (CaseAmendL ls) (tagged l x ': xs) (Key, WrappedAny) where
    case' (CaseAmendL lo) v = (Key (lo + i), WrappedAny (unsafeCoerce v))
      where
        i = fromInteger (natVal @(IndexAtLabel l ls) Proxy)

-----------------------------------------------------------------------

-- | Projection.
-- A Nary can be narrowed or have its order changed by projecting into another Nary type.
--
-- @project = lens narrow amend@
--
-- Use TypeApplication to specify the @smaller@ typelist of the lens.
--
-- @project \@'[Int, String]@
--
-- Use @_ to specify the @larger@ typelist instead.
--
-- @project \@_ \@'[Int, String]@
project
    :: forall smaller larger.
       (Narrow smaller larger, Amend smaller larger)
    => Lens' (Nary larger) (Nary smaller)
project = lens narrow amend
{-# INLINE project #-}

-- | Projection.
-- A version of 'project' using a Nat-list to specify the other Nary type.
--
-- @projectN p = lens (narrowN p) (amendN p)@
--
-- Specify a Nat-list mapping of the indicies of the original fields.
--
-- @projectN (Proxy \@'[Int, String])@
--
projectN
    :: forall ns smaller larger proxy.
       (NarrowN ns smaller larger, AmendN ns smaller larger)
    => proxy ns -> Lens' (Nary larger) (Nary smaller)
projectN p = lens (narrowN p) (amendN p)
{-# INLINE projectN #-}


-- | Projection.
-- A version of 'project' using a typelist of labels to specify the other Nary type.
--
-- @projectL p = lens (narrowL p) (amendLs p)@
--
-- Specify a typelist of the labels of the original fields.
--
-- @projectL (Proxy \@'["foo", Int])@
--
projectL
    :: forall ls smaller larger proxy.
       (NarrowL ls smaller  larger, AmendL ls smaller larger)
    => proxy ls -> Lens' (Nary larger) (Nary smaller)
projectL p = lens (narrowL p) (amendL p)
{-# INLINE projectL #-}

-----------------------------------------------------------------------

-- | Stores the left & right Nary and a list of Any which must be the same length and types in xs typelist.
newtype EmitEqNary (xs :: [Type]) r = EmitEqNary ([Any], [Any])

instance Reiterate EmitEqNary (x ': xs) where
    -- use of tail here is safe as we are guaranteed the length from the typelist
    reiterate (EmitEqNary (ls, rs)) = EmitEqNary (Partial.tail ls, Partial.tail rs)

instance Eq x => Emit EmitEqNary (x ': xs) Bool where
    emit (EmitEqNary (ls, rs)) = l == r
      where
        -- use of front here is safe as we are guaranteed the length from the typelist
        l = unsafeCoerce (Partial.head ls) :: x
        r = unsafeCoerce (Partial.head rs) :: x

eqNary
    :: forall xs.
       AFoldable (Collector EmitEqNary xs) Bool
    => Nary xs -> Nary xs -> [Bool]
eqNary (Nary _ lm) (Nary _ rm) = afoldr (:) []
    (Collector (EmitEqNary @xs (snd <$> M.toAscList lm, snd <$> M.toAscList rm)))

instance AFoldable (Collector EmitEqNary xs) Bool => Eq (Nary xs) where
    lt == rt = foldr (\e z -> bool False z e) True eqs
      where
        eqs = eqNary lt rt

-----------------------------------------------------------------------

-- | Stores the left & right Nary and a list of Any which must be the same length and types in xs typelist.
newtype EmitOrdNary (xs :: [Type]) r = EmitOrdNary ([Any], [Any])

instance Reiterate EmitOrdNary (x ': xs) where
    -- use of tail here is safe as we are guaranteed the length from the typelist
    reiterate (EmitOrdNary (ls, rs)) = EmitOrdNary (Partial.tail ls, Partial.tail rs)

instance Ord x => Emit EmitOrdNary (x ': xs) Ordering where
    emit (EmitOrdNary (ls, rs)) = compare l r
      where
        -- use of front here is safe as we are guaranteed the length from the typelist
        l = unsafeCoerce (Partial.head ls) :: x
        r = unsafeCoerce (Partial.head rs) :: x

ordNary
    :: forall xs.
       AFoldable (Collector EmitOrdNary xs) Ordering
    => Nary xs -> Nary xs -> [Ordering]
ordNary (Nary _ lm) (Nary _ rm) = afoldr (:) []
    (Collector (EmitOrdNary @xs (snd <$> M.toAscList lm, snd <$> M.toAscList rm)))

instance (Eq (Nary xs), AFoldable (Collector EmitOrdNary xs) Ordering) => Ord (Nary xs) where
    compare lt rt = foldr (\o z -> case o of
                                       EQ -> z
                                       o' -> o') EQ ords
      where
        ords = ordNary lt rt

-----------------------------------------------------------------------

-- | Internally uses [Any] like Via, except also handle the empty type list.
newtype EmitShowNary (xs :: [Type]) r = EmitShowNary [Any]

instance Reiterate EmitShowNary (x ': xs) where
    -- use of tail here is safe as we are guaranteed the length from the typelist
    reiterate (EmitShowNary xxs) = EmitShowNary (Partial.tail xxs)

instance Emit EmitShowNary '[] ShowS where
    emit _ = showString ".|"

instance Show x => Emit EmitShowNary '[x] ShowS where
    emit (EmitShowNary xs) = showsPrec (cons_prec + 1) v
      where
        -- use of front here is safe as we are guaranteed the length from the typelist
        v = unsafeCoerce (Partial.head xs) :: x
        cons_prec = 5 -- infixr 5 cons

instance Show x => Emit EmitShowNary (x ': x' ': xs) ShowS where
    emit (EmitShowNary xxs) = showsPrec (cons_prec + 1) v . showString "./"
      where
        -- use of front here is safe as we are guaranteed the length from the typelist
        v = unsafeCoerce (Partial.head xxs) :: x
        cons_prec = 5 -- infixr 5 cons

showNary
    :: forall xs.
       AFoldable (Collector EmitShowNary xs) ShowS
    => Nary xs -> ShowS
showNary (Nary _ m) = afoldr (.) id (Collector (EmitShowNary @xs (snd <$> M.toAscList m)))

instance AFoldable (Collector EmitShowNary xs) ShowS => Show (Nary xs) where
    showsPrec d t = showParen (d > cons_prec) $ showNary t
      where
        cons_prec = 5 -- infixr 5 cons

-----------------------------------------------------------------------

newtype EmitReadNary (xs :: [Type]) r = EmitReadNary Key

instance Reiterate EmitReadNary (x ': xs) where
    reiterate (EmitReadNary (Key i)) = EmitReadNary (Key (i + 1))

instance Emit EmitReadNary '[] (ReadPrec [(Key, WrappedAny)]) where
    emit (EmitReadNary _) = do
        lift $ L.expect (Symbol ".|")
        pure []

instance Read x => Emit EmitReadNary '[x] (ReadPrec [(Key, WrappedAny)]) where
    emit (EmitReadNary i) = do
        a <- readPrec @x
        -- don't read the ".|", save that for Emit '[]
        pure [(i, WrappedAny (unsafeCoerce a))]

instance Read x => Emit EmitReadNary (x ': x' ': xs) (ReadPrec [(Key, WrappedAny)]) where
    emit (EmitReadNary i) = do
        a <- readPrec @x
        lift $ L.expect (Symbol "./")
        pure [(i, WrappedAny (unsafeCoerce a))]

readNary
    :: forall xs.
       AFoldable (Collector0 EmitReadNary xs) (ReadPrec [(Key, WrappedAny)])
    => Proxy (xs :: [Type]) -> ReadPrec [(Key, WrappedAny)]
readNary _ = afoldr (liftA2 (++)) (pure []) (Collector0 (EmitReadNary @xs (Key 0)))

instance ( Distinct xs
         , AFoldable (Collector0 EmitReadNary xs) (ReadPrec [(Key, WrappedAny)])
         ) =>
         Read (Nary xs) where
    readPrec =
        parens $
        prec 10 $ do
            xs <- readNary @xs Proxy
            pure (Nary 0 (fromList' xs))

-- | 'WrappedAny' avoids the following:
-- Illegal type synonym family application in instance: Any
newtype WrappedAny = WrappedAny Any

-- FIXME: Add tuple conversion functions?