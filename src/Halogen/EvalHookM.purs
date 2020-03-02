module Halogen.EvalHookM where

import Prelude

import Control.Applicative.Free (FreeAp, hoistFreeAp, retractFreeAp)
import Control.Monad.Free (Free, foldFree, liftF)
import Control.Parallel (parallel, sequential)
import Data.Array as Array
import Data.Maybe (Maybe(..), fromJust, maybe)
import Data.Newtype (class Newtype)
import Data.Symbol (class IsSymbol, SProxy)
import Data.Tuple.Nested (type (/\))
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Ref (Ref)
import Foreign.Object (Object)
import Halogen as H
import Halogen.Data.Slot as Slot
import Halogen.Query.ChildQuery as CQ
import Halogen.Query.EventSource as ES
import Halogen.Query.HalogenM (ForkId)
import Partial.Unsafe (unsafePartial)
import Prim.Row as Row
import Unsafe.Coerce (unsafeCoerce)
import Web.DOM (Element)
import Web.HTML (HTMLElement)
import Web.HTML.HTMLElement as HTMLElement

-- | The EvalHook API: a set of primitive building blocks that can be used as
-- | an alternate interface to HalogenM when evaluating hooks. Implemented so
-- | that multiple states can be accessed by different hooks.
data EvalHookF slots output m a
  = Modify (StateToken StateValue) (StateValue -> StateValue) (StateValue -> a)
  | Subscribe (H.SubscriptionId -> ES.EventSource m (EvalHookM slots output m Unit)) (H.SubscriptionId -> a)
  | Unsubscribe H.SubscriptionId a
  | Lift (m a)
  | ChildQuery (CQ.ChildQueryBox slots a)
  | Raise output a
  | Par (EvalHookAp slots output m a)
  | Fork (EvalHookM slots output m Unit) (H.ForkId -> a)
  | Kill H.ForkId a
  | GetRef H.RefLabel (Maybe Element -> a)

derive instance functorHookF :: Functor m => Functor (EvalHookF slots output m)

-- | The Hook effect monad, an interface to the HalogenM component eval effect monad
newtype EvalHookM slots output m a = EvalHookM (Free (EvalHookF slots output m) a)

derive newtype instance functorEvalHookM :: Functor (EvalHookM slots output m)
derive newtype instance applyEvalHookM :: Apply (EvalHookM slots output m)
derive newtype instance applicativeEvalHookM :: Applicative (EvalHookM slots output m)
derive newtype instance bindEvalHookM :: Bind (EvalHookM slots output m)
derive newtype instance monadEvalHookM :: Monad (EvalHookM slots output m)
derive newtype instance semigroupEvalHookM :: Semigroup a => Semigroup (EvalHookM slots output m a)
derive newtype instance monoidEvalHookM :: Monoid a => Monoid (EvalHookM slots output m a)

instance monadEffectEvalHookM :: MonadEffect m => MonadEffect (EvalHookM slots output m) where
  liftEffect = EvalHookM <<< liftF <<< Lift <<< liftEffect

instance monadAffEvalHookM :: MonadAff m => MonadAff (EvalHookM slots output m) where
  liftAff = EvalHookM <<< liftF <<< Lift <<< liftAff

-- | An applicative-only version of `EvalHookM` to allow for parallel evaluation.
newtype EvalHookAp slots output m a = EvalHookAp (FreeAp (EvalHookM slots output m) a)

derive instance newtypeEvalHookAp :: Newtype (EvalHookAp slots output m a) _
derive newtype instance functorEvalHookAp :: Functor (EvalHookAp slots output m)
derive newtype instance applyEvalHookAp :: Apply (EvalHookAp slots output m)
derive newtype instance applicativeEvalHookAp :: Applicative (EvalHookAp slots output m)

-- Query

foreign import data QueryValue :: Type -> Type

toQueryValue :: forall q a. q a -> QueryValue a
toQueryValue = unsafeCoerce

fromQueryValue :: forall q a. QueryValue a -> q a
fromQueryValue = unsafeCoerce

foreign import data QueryToken :: (Type -> Type) -> Type

-- Effect

newtype EffectId = EffectId Int

derive newtype instance eqEffectId :: Eq EffectId
derive newtype instance ordEffectId :: Ord EffectId
derive newtype instance showEffectId :: Show EffectId

foreign import data MemoValues :: Type

type MemoValuesImpl =
  { eq :: Object MemoValue -> Object MemoValue -> Boolean
  , memos :: Object MemoValue
  }

toMemoValues :: MemoValuesImpl -> MemoValues
toMemoValues = unsafeCoerce

fromMemoValues :: MemoValues -> MemoValuesImpl
fromMemoValues = unsafeCoerce

-- Memo

newtype MemoId = MemoId Int

derive newtype instance eqMemoId :: Eq MemoId
derive newtype instance ordMemoId :: Ord MemoId
derive newtype instance showMemoId :: Show MemoId

foreign import data MemoValue :: Type

toMemoValue :: forall memo. memo -> MemoValue
toMemoValue = unsafeCoerce

fromMemoValue :: forall memo. MemoValue -> memo
fromMemoValue = unsafeCoerce

-- Refs

newtype RefId = RefId Int

derive newtype instance eqRefId :: Eq RefId
derive newtype instance ordRefId :: Ord RefId
derive newtype instance showRefId :: Show RefId

foreign import data RefValue :: Type

toRefValue :: forall a. a -> RefValue
toRefValue = unsafeCoerce

fromRefValue :: forall a. RefValue -> a
fromRefValue = unsafeCoerce

-- State

foreign import data StateValue :: Type

toStateValue :: forall state. state -> StateValue
toStateValue = unsafeCoerce

fromStateValue :: forall state. StateValue -> state
fromStateValue = unsafeCoerce

-- Used to uniquely identify a cell in state as well as its type so it can be
-- modified safely by users but is also available in a heterogeneous collection
-- in component state. Should not have its constructor exported.
newtype StateToken state = StateToken StateId

get :: forall state slots output m. StateToken state -> EvalHookM slots output m state
get token = modify token identity

put :: forall state slots output m. StateToken state -> state -> EvalHookM slots output m Unit
put token state = modify_ token (const state)

modify_ :: forall state slots output m. StateToken state -> (state -> state) -> EvalHookM slots output m Unit
modify_ token = map (const unit) <<< modify token

modify :: forall state slots output m. StateToken state -> (state -> state) -> EvalHookM slots output m state
modify token f = EvalHookM $ liftF $ Modify token' f' state
  where
  token' :: StateToken StateValue
  token' = unsafeCoerce token

  f' :: StateValue -> StateValue
  f' = toStateValue <<< f <<< fromStateValue

  state :: StateValue -> state
  state = fromStateValue

-- Outputs

raise :: forall slots output m. output -> EvalHookM slots output m Unit
raise output = EvalHookM $ liftF $ Raise output unit

-- Refs

-- | Retrieves a `HTMLElement` value that is associated with a `Ref` in the
-- | rendered output of a component. If there is no currently rendered value (or
-- | it is not an `HTMLElement`) for the request will return `Nothing`.
getHTMLElementRef
  :: forall slots output m
   . H.RefLabel
  -> EvalHookM slots output m (Maybe HTMLElement)
getHTMLElementRef = map (HTMLElement.fromElement =<< _) <<< getRef

-- | Retrieves an `Element` value that is associated with a `Ref` in the
-- | rendered output of a component. If there is no currently rendered value for
-- | the requested ref this will return `Nothing`.
getRef :: forall slots output m. H.RefLabel -> EvalHookM slots output m (Maybe Element)
getRef p = EvalHookM $ liftF $ GetRef p identity

fork :: forall ps o m. EvalHookM ps o m Unit -> EvalHookM ps o m ForkId
fork fn = EvalHookM $ liftF $ Fork fn identity

-- Querying
query
  :: forall output m label slots query output' slot a _1
   . Row.Cons label (H.Slot query output' slot) _1 slots
  => IsSymbol label
  => Ord slot
  => SProxy label
  -> slot
  -> query a
  -> EvalHookM slots output m (Maybe a)
query label p q = EvalHookM $ liftF $ ChildQuery $ CQ.mkChildQueryBox $
  CQ.ChildQuery (\k → maybe (pure Nothing) k <<< Slot.lookup label p) q identity

-- Subscription

subscribe :: forall slots output m. ES.EventSource m (EvalHookM slots output m Unit) -> EvalHookM slots output m H.SubscriptionId
subscribe es = EvalHookM $ liftF $ Subscribe (\_ -> es) identity

subscribe' :: forall slots output m. (H.SubscriptionId -> ES.EventSource m (EvalHookM slots output m Unit)) -> EvalHookM slots output m Unit
subscribe' esc = EvalHookM $ liftF $ Subscribe esc (const unit)

unsubscribe :: forall slots output m. H.SubscriptionId -> EvalHookM slots output m Unit
unsubscribe sid = EvalHookM $ liftF $ Unsubscribe sid unit

-- Interpreter

foreign import data QueryFn :: (Type -> Type) -> # Type -> Type -> (Type -> Type) -> Type

toQueryFn :: forall q ps o m. (forall a. q a -> EvalHookM ps o m (Maybe a)) -> QueryFn q ps o m
toQueryFn = unsafeCoerce

fromQueryFn :: forall q ps o m. QueryFn q ps o m -> (forall a. q a -> EvalHookM ps o m (Maybe a))
fromQueryFn = unsafeCoerce

newtype HookState q i ps o m = HookState
  { input :: i
  , html :: H.ComponentHTML (EvalHookM ps o m Unit) ps m
  , queryFn :: Maybe (QueryFn q ps o m)
  , stateCells :: QueueState StateValue
  , effectCells :: QueueState MemoValues
  , memoCells :: QueueState (MemoValues /\ MemoValue)
  , refCells :: QueueState (Ref RefValue)
  , finalizerQueue :: Array (EvalHookM ps o m Unit)
  , evalQueue :: Array (H.HalogenM (HookState q i ps o m) (EvalHookM ps o m Unit) ps o m Unit)
  }

derive instance newtypeHookState :: Newtype (HookState q i ps o m) _

type QueueState a =
  { queue :: Array a
  , index :: Int
  }

newtype StateId = StateId Int

derive newtype instance eqStateId :: Eq StateId
derive newtype instance ordStateId :: Ord StateId
derive newtype instance showStateId :: Show StateId

evalM
  :: forall q i ps o m
   . H.HalogenM (HookState q i ps o m) (EvalHookM ps o m Unit) ps o m Unit
  -> EvalHookM ps o m
  ~> H.HalogenM (HookState q i ps o m) (EvalHookM ps o m Unit) ps o m
evalM runHooks (EvalHookM evalHookF) = foldFree interpretEvalHook evalHookF
  where
  interpretEvalHook :: EvalHookF ps o m ~> H.HalogenM (HookState q i ps o m) (EvalHookM ps o m Unit) ps o m
  interpretEvalHook = case _ of
    Modify (StateToken token) f reply -> do
      HookState state <- H.get
      let v = f (unsafeGetStateCell token state.stateCells.queue)
      H.put $ HookState $ state { stateCells { queue = unsafeSetStateCell token v state.stateCells.queue } }
      runHooks
      pure (reply v)

    Subscribe eventSource reply -> do
      H.HalogenM $ liftF $ H.Subscribe eventSource reply

    Unsubscribe sid a -> do
      H.HalogenM $ liftF $ H.Unsubscribe sid a

    Lift f ->
      H.HalogenM $ liftF $ H.Lift f

    ChildQuery box ->
      H.HalogenM $ liftF $ H.ChildQuery box

    Raise o a ->
      H.raise o *> pure a

    Par (EvalHookAp p) ->
      sequential $ retractFreeAp $ hoistFreeAp (parallel <<< evalM runHooks) p

    Fork hmu reply ->
      H.HalogenM $ liftF $ H.Fork (evalM runHooks hmu) reply

    Kill fid a ->
      H.HalogenM $ liftF $ H.Kill fid a

    GetRef p reply ->
      H.HalogenM $ liftF $ H.GetRef p reply

-- Utilities for updating state

unsafeGetStateCell :: StateId -> Array StateValue -> StateValue
unsafeGetStateCell (StateId index) array = unsafePartial (Array.unsafeIndex array index)

unsafeSetStateCell :: StateId -> StateValue -> Array StateValue -> Array StateValue
unsafeSetStateCell (StateId index) a array = unsafePartial (fromJust (Array.modifyAt index (const a) array))

unsafeGetEffectCell :: EffectId -> Array MemoValues -> MemoValues
unsafeGetEffectCell (EffectId index) array = unsafePartial (Array.unsafeIndex array index)

unsafeSetEffectCell :: EffectId -> MemoValues -> Array MemoValues -> Array MemoValues
unsafeSetEffectCell (EffectId index) a array = unsafePartial (fromJust (Array.modifyAt index (const a) array))

unsafeGetMemoCell :: MemoId -> Array (MemoValues /\ MemoValue) -> MemoValues /\ MemoValue
unsafeGetMemoCell (MemoId index) array = unsafePartial (Array.unsafeIndex array index)

unsafeSetMemoCell :: MemoId -> MemoValues /\ MemoValue -> Array (MemoValues /\ MemoValue) -> Array (MemoValues /\ MemoValue)
unsafeSetMemoCell (MemoId index) a array = unsafePartial (fromJust (Array.modifyAt index (const a) array))

unsafeGetRefCell :: RefId -> Array (Ref RefValue) -> Ref RefValue
unsafeGetRefCell (RefId index) array = unsafePartial (Array.unsafeIndex array index)

unsafeSetRefCell :: RefId -> Ref RefValue -> Array (Ref RefValue) -> Array (Ref RefValue)
unsafeSetRefCell (RefId index) a array = unsafePartial (fromJust (Array.modifyAt index (const a) array))
