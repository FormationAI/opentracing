{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE StrictData             #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}

module OpenTracing.Span
    ( SpanContext(..)
    , ctxSampled
    , ctxBaggage

    , Span
    , newSpan

    , HasSpanFields

    , ActiveSpan
    , mkActive
    , modifyActiveSpan
    , readActiveSpan

    , FinishedSpan
    , traceFinish

    , spanContext
    , spanOperation
    , spanStart
    , spanTags
    , spanRefs
    , spanLogs
    , spanDuration

    , SpanOpts(..)
    , spanOpts

    , Reference(..)
    , findParent

    , SpanRefs
    , refActiveParents
    , refPredecessors
    , refPropagated
    , childOf
    , followsFrom
    , freezeRefs

    , Sampled(..)
    , _IsSampled
    , sampled

    , Traced(..)
    )
where

import Control.Lens           hiding (op, pre, (.=))
import Control.Monad.IO.Class
import Data.Aeson             (ToJSON (..), object, (.=))
import Data.Aeson.Encoding    (int, pairs)
import Data.Bool              (bool)
import Data.Foldable
import Data.HashMap.Strict    (HashMap)
import Data.IORef
import Data.Monoid
import Data.Text              (Text)
import Data.Time.Clock
import Data.Word
import OpenTracing.Log
import OpenTracing.Tags
import OpenTracing.Types
import Prelude                hiding (span)


data SpanContext = SpanContext
    { ctxTraceID       :: TraceID
    , ctxSpanID        :: Word64
    , ctxParentSpanID  :: Maybe Word64
    , _ctxSampled      :: Sampled
    , _ctxBaggage      :: HashMap Text Text
    }

instance ToJSON SpanContext where
    toEncoding SpanContext{..} = pairs $
           "trace_id" .= view hexText ctxTraceID
        <> "span_id"  .= view hexText ctxSpanID
        <> "sampled"  .= _ctxSampled
        <> "baggage"  .= _ctxBaggage

    toJSON SpanContext{..} = object
        [ "trace_id" .= view hexText ctxTraceID
        , "span_id"  .= view hexText ctxSpanID
        , "sampled"  .= _ctxSampled
        , "baggage"  .= _ctxBaggage
        ]

data Traced a = Traced
    { tracedResult :: a
    , tracedSpan   :: ~FinishedSpan
    }

data Sampled = NotSampled | Sampled
    deriving (Eq, Show, Read, Bounded, Enum)

instance ToJSON Sampled where
    toJSON     = toJSON . fromEnum
    toEncoding = int . fromEnum

_IsSampled :: Iso' Bool Sampled
_IsSampled= iso (bool NotSampled Sampled) $ \case
    Sampled    -> True
    NotSampled -> False

data Reference
    = ChildOf     { refCtx :: SpanContext }
    | FollowsFrom { refCtx :: SpanContext }

findParent :: Foldable t => t Reference -> Maybe Reference
findParent = foldl' go Nothing
  where
    go Nothing  y = Just y
    go (Just x) y = Just $ case prec x y of { LT -> y; _ -> x }

    prec (ChildOf     _) (FollowsFrom _) = GT
    prec (FollowsFrom _) (ChildOf     _) = LT
    prec _               _               = EQ


data SpanRefs = SpanRefs
    { _refActiveParents :: [ActiveSpan  ]
    , _refPredecessors  :: [FinishedSpan]
    , _refPropagated    :: [Reference   ]
    }

instance Monoid SpanRefs where
    mempty = SpanRefs mempty mempty mempty

    (SpanRefs par pre pro) `mappend` (SpanRefs par' pre' pro') = SpanRefs
        { _refActiveParents = par <> par'
        , _refPredecessors  = pre <> pre'
        , _refPropagated    = pro <> pro'
        }

childOf :: ActiveSpan -> SpanRefs
childOf a = mempty { _refActiveParents = [a] }

followsFrom :: FinishedSpan -> SpanRefs
followsFrom a = mempty { _refPredecessors = [a] }

freezeRefs :: SpanRefs -> IO [Reference]
freezeRefs SpanRefs{..} = do
    a <- traverse (fmap (ChildOf . _sContext) . readActiveSpan) _refActiveParents
    let b = map (FollowsFrom . _fContext) _refPredecessors
    return $ a <> b <> _refPropagated


data SpanOpts = SpanOpts
    { spanOptOperation :: Text
    , spanOptRefs      :: SpanRefs
    , spanOptTags      :: [Tag]
    , spanOptSampled   :: Maybe Sampled
    -- ^ Force 'Span' to be sampled (or not).
    -- 'Nothing' denotes leave decision to 'Sampler' (the default)
    }

spanOpts :: Text -> SpanRefs -> SpanOpts
spanOpts op refs = SpanOpts
    { spanOptOperation = op
    , spanOptRefs      = refs
    , spanOptTags      = mempty
    , spanOptSampled   = Nothing
    }

data Span = Span
    { _sContext   :: SpanContext
    , _sOperation :: Text
    , _sStart     :: UTCTime
    , _sTags      :: Tags
    , _sRefs      :: SpanRefs
    , _sLogs      :: [LogRecord]
    }

newSpan
    :: ( MonadIO  m
       , Foldable t
       )
    => SpanContext
    -> Text
    -> SpanRefs
    -> t Tag
    -> m Span
newSpan ctx op refs ts = do
    t <- liftIO getCurrentTime
    pure Span
        { _sContext   = ctx
        , _sOperation = op
        , _sStart     = t
        , _sTags      = foldMap (`setTag` mempty) ts
        , _sRefs      = refs
        , _sLogs      = mempty
        }


newtype ActiveSpan = ActiveSpan { fromActiveSpan :: IORef Span }

mkActive :: Span -> IO ActiveSpan
mkActive = fmap ActiveSpan . newIORef

modifyActiveSpan :: ActiveSpan -> (Span -> Span) -> IO ()
modifyActiveSpan ActiveSpan{fromActiveSpan} f =
    atomicModifyIORef' fromActiveSpan ((,()) . f)

readActiveSpan :: ActiveSpan -> IO Span
readActiveSpan = readIORef . fromActiveSpan


data FinishedSpan = FinishedSpan
    { _fContext   :: SpanContext
    , _fOperation :: Text
    , _fStart     :: UTCTime
    , _fDuration  :: NominalDiffTime
    , _fTags      :: Tags
    , _fRefs      :: [Reference]
    , _fLogs      :: [LogRecord]
    }

traceFinish :: MonadIO m => Span -> m FinishedSpan
traceFinish s = do
    (t,refs) <- liftIO $ (,) <$> getCurrentTime <*> freezeRefs (_sRefs s)
    pure FinishedSpan
        { _fContext   = _sContext s
        , _fOperation = _sOperation s
        , _fStart     = _sStart s
        , _fDuration  = diffUTCTime t (_sStart s)
        , _fTags      = _sTags s
        , _fRefs      = refs
        , _fLogs      = _sLogs s
        }

makeLenses ''SpanContext
makeLenses ''Span
makeLenses ''FinishedSpan
makeLenses ''SpanRefs

class HasSpanFields a where
    spanContext   :: Lens' a SpanContext
    spanOperation :: Lens' a Text
    spanStart     :: Lens' a UTCTime
    spanTags      :: Lens' a Tags
    spanLogs      :: Lens' a [LogRecord]

instance HasSpanFields Span where
    spanContext   = sContext
    spanOperation = sOperation
    spanStart     = sStart
    spanTags      = sTags
    spanLogs      = sLogs

instance HasSpanFields FinishedSpan where
    spanContext   = fContext
    spanOperation = fOperation
    spanStart     = fStart
    spanTags      = fTags
    spanLogs      = fLogs

class HasSampled a where
    sampled :: Lens' a Sampled

instance HasSampled Sampled where
    sampled = id

instance HasSampled SpanContext where
    sampled = ctxSampled

instance HasSampled Span where
    sampled = spanContext . sampled

instance HasSampled FinishedSpan where
    sampled = spanContext . sampled


class HasRefs s a | s -> a where
    spanRefs :: Lens' s a

instance HasRefs Span SpanRefs where
    spanRefs = sRefs

instance HasRefs FinishedSpan [Reference] where
    spanRefs = fRefs


spanDuration :: Lens' FinishedSpan NominalDiffTime
spanDuration = fDuration
