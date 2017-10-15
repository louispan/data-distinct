{-# LANGUAGE CPP #-}

-- | Re-export Many without the constructor
module Data.Diverse.Many (
    -- * 'Many' type
      Many -- Hiding constructor

      -- * Isomorphism
    , IsMany(..)
    , fromMany'
    , toMany'

      -- * Construction
    , nil
    , single
    , prefix
    , (./)
    , postfix
    , postfix'
    , (\.)
    , append
    , CanAppendUnique(..)
    , (/./)

    -- * Simple queries
    , viewf
    , viewb
    , front
    , back
    , aft
    , fore

    -- * Single field
    -- ** Getter for single field
    , fetch
    , fetchL
    , fetchN
    -- ** Setter for single field
    , replace
    , replace'
    , replaceL
    , replaceL'
    , replaceN
    , replaceN'

    -- * Multiple fields
    -- ** Getter for multiple fields
    , Select
    , select
    , selectL
    , SelectN
    , selectN
    -- ** Setter for multiple fields
    , Amend
    , amend
    , Amend'
    , amend'
    , amendL
    , amendL'
    , AmendN
    , amendN
    , AmendN'
    , amendN'

    -- * Destruction
    -- ** By type
    , Collect
    , Collector
    , forMany
    , collect
    -- ** By Nat index offset
    , CollectN
    , CollectorN
    , forManyN
    , collectN

    -- * Splitting operations

    -- * Splitting
    , splitBefore
    , splitBeforeL
    , splitBeforeN
    , splitAfter
    , splitAfterL
    , splitAfterN

    -- * inset multiple items
    , insetBefore
    , insetBeforeL
    , insetBeforeN
    , insetAfter
    , insetAfterL
    , insetAfterN

#if __GLASGOW_HASKELL__ >= 802
    -- * insert single item
    , insertBefore
    , insertBeforeL
    , insertBeforeN
    , insertAfter
    , insertAfterL
    , insertAfterN

    -- * Deleting single item
    , remove
    , removeL
    , removeN
#endif
    ) where

import Data.Diverse.Many.Internal
