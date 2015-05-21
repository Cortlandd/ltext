{-# LANGUAGE
    TypeSynonymInstances
  , FlexibleInstances
  , MultiParamTypeClasses
  #-}

module LText.Internal.Inference where

import LText.Internal.Expr
import LText.Internal.Types
import LText.Internal.Classes

import           Control.Monad.State
import           Control.Monad.Trans.Except
import qualified Data.Map                   as Map
import qualified Data.Set                   as Set


newtype Context = Context (Map.Map ExpVar Prenex)

remove :: Context -> String -> Context
remove (Context env) var = Context (Map.delete var env)


instance Bindable Set.Set TypeVar Context where
  fv (Context env) = fv (Map.elems env)

instance Substitutable Map.Map TypeVar Type Context where
  apply s (Context env) = Context (fmap (apply s) env)


-- | Binds free type variables as universally quantified
generalize :: Context -> Type -> Prenex
generalize env t = Prenex vars t
  where vars = Set.toList $ fv t `difference` fv env

data TIState = TIState { tiSupply :: Int
                       , tiSubst  :: Subst TypeVar Type
                       }

-- | Inference Monad
type TI a = ExceptT String (StateT TIState IO) a

runTI :: TI a -> IO (Either String a, TIState)
runTI t = runStateT (runExceptT t) initTIState
  where initTIState = TIState { tiSupply = 0
                              , tiSubst = nullSubst
                              }

newTyVar :: TypeVar -> TI Type
newTyVar prefix = do
  s <- get
  put s { tiSupply = tiSupply s + 1
        }
  return $ TVar $ prefix ++ show (tiSupply s)

-- | Replaces bound type variables with free, fresh ones
instantiate :: Prenex -> TI Type
instantiate (Prenex vars t) = do
  nvars <- mapM newTyVar vars
  return $ apply (Map.fromList $ zip vars nvars) t

-- | Most general unifier
mgu :: Type -> Type -> TI (Subst TypeVar Type)
mgu (TFun l r) (TFun l' r')  = do s1 <- mgu l l'
                                  s2 <- mgu (apply s1 r) (apply s1 r')
                                  return (s1 `composeSubst` s2)
mgu (TVar u) t               = varBind u t
mgu t (TVar u)               = varBind u t
mgu TText TText              = return nullSubst
mgu t1 t2                    = throwE $ "Types do not unify: " ++ show t1 ++
                                        " vs. " ++ show t2

-- | Makes a substitution @[x -> t]@
varBind :: TypeVar -> Type -> TI (Subst TypeVar Type)
varBind u t | t == TVar u         = return nullSubst
            | u `Set.member` fv t = throwE $ "Occur check fails: " ++ u ++
                                             " vs. " ++ show t
            | otherwise           = return (Map.singleton u t)


-- | Type inference function
ti :: Context -> Exp -> TI (Subst TypeVar Type, Type)
ti (Context env) (EVar n) = case Map.lookup n env of
  Nothing     ->  throwE $ "unbound variable: " ++ n
  Just sigma  ->  do  t <- instantiate sigma
                      return (nullSubst, t)

ti env (EAbs n e) = do
  tv <- newTyVar "a"
  let Context env' = remove env n -- replace `n`'s type with a free type variable
      env''        = Context $ env' `Map.union` Map.singleton n (Prenex [] tv)
  (s1, t1) <- ti env'' e
  return (s1, TFun (apply s1 tv) t1)

ti env (EApp e1 e2) = do
  (s1, t1) <- ti env e1
  (s2, t2) <- ti (apply s1 env) e2
  tv       <- newTyVar "a"
  s3       <- mgu (apply s2 t1) (TFun t2 tv)
  return (s3 `composeSubst` s2 `composeSubst` s1, apply s3 tv)

ti env (ELet x e1 e2) = do
  (s1, t1) <- ti env e1
  let Context env' = remove env x
      t'           = generalize (apply s1 env) t1
      env''        = Context (Map.insert x t' env')
  (s2, t2) <- ti (apply s1 env'') e2
  return (s1 `composeSubst` s2, t2)

ti _ (EText _) = return (nullSubst, TText)

ti env (EConc e1 e2) = do
  (s1, t1) <- ti env e1
  case apply s1 t1 of
    TText -> do
      (s2, t2) <- ti env e2
      case apply s2 t2 of
        TText -> return (nullSubst, TText)
        _     -> throwE $ "Cannot concatenate expressions of type " ++ show t2
    _     -> throwE $ "Cannot concatenate expressions of type " ++ show t1

  return (nullSubst, TText)


typeInference :: Context -> Exp -> TI Type
typeInference env e = do
  (s, t) <- ti env e
  return (apply s t)

test :: Exp -> IO ()
test e = do
  (res, _) <- runTI (typeInference (Context Map.empty) e)
  case res of
    Left err  ->  putStrLn $ "error: " ++ err
    Right t   ->  putStrLn $ show e ++ " :: " ++ show t