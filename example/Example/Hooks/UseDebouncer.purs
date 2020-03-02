module Example.Hooks.UseDebouncer
  ( useDebouncer
  , UseDebouncer
  )
  where

import Prelude

import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..))
import Data.Tuple.Nested ((/\))
import Effect.Aff (Fiber, Milliseconds, delay, error, forkAff, killFiber)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Halogen.EvalHookM (EvalHookM)
import Halogen.EvalHookM as EH
import Halogen.Hook (Hook, UseRef)
import Halogen.Hook as Hook

type UseDebouncer' a hooks = UseRef (Maybe a) (UseRef (Maybe Debouncer) hooks)

foreign import data UseDebouncer :: Type -> Type -> Type

type Debouncer =
  { var :: AVar Unit
  , fiber :: Fiber Unit
  }

useDebouncer
  :: forall ps o m a
   . MonadAff m
  => Milliseconds
  -> (a -> EvalHookM ps o m Unit)
  -> Hook ps o m (UseDebouncer a) (a -> EvalHookM ps o m Unit)
useDebouncer ms fn = Hook.coerce hook
  where
  hook :: Hook ps o m (UseDebouncer' a) (a -> EvalHookM ps o m Unit)
  hook = Hook.do
    _ /\ debounceRef <- Hook.useRef Nothing
    _ /\ valRef <- Hook.useRef Nothing

    let
      debounceFn x = do
        debouncer <- liftEffect do
          Ref.write (Just x) valRef
          Ref.read debounceRef

        case debouncer of
          Nothing -> do
            var <- liftAff AVar.empty
            fiber <- liftAff $ forkAff do
              delay ms
              AVar.put unit var

            _ <- EH.fork do
              _ <- liftAff $ AVar.take var
              val <- liftEffect do
                Ref.write Nothing debounceRef
                Ref.read valRef
              traverse_ fn val

            liftEffect do
              Ref.write (Just { var, fiber }) debounceRef

          Just db -> do
            let var = db.var
            fiber <- liftAff do
              killFiber (error "Time's up!") db.fiber
              forkAff do
                delay ms
                AVar.put unit var

            liftEffect $ Ref.write (Just { var, fiber }) debounceRef

    Hook.pure debounceFn
