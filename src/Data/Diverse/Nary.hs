-- | Re-export Nary without the constructor
module Data.Diverse.Nary (
    -- * 'Nary' type
      Nary -- Hiding constructor

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

import Data.Diverse.Nary.Internal