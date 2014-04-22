{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Bedrock.RegisterIntroduction
    ( registerIntroduction ) where

import           Control.Applicative  (Applicative, pure, (<$>), (<*>))
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Map             (Map)
import qualified Data.Map             as Map

import           Data.Bedrock
import           Data.Bedrock.Misc

type Env = Map Variable [Variable]

newtype Uniq a = Uniq { unUniq :: ReaderT Env (State AvailableNamespace) a }
    deriving ( Monad, MonadReader Env, MonadState AvailableNamespace
             , Functor, Applicative )

registerIntroduction :: Module -> Module
registerIntroduction m = evalState (runReaderT (unUniq (uniqModule m)) env) st
  where
    env = Map.empty
    st = modNamespace m



newUnique :: Maybe Type -> Uniq Int
newUnique mbTy = do
    ns <- get
    let (idNum, ns') = case mbTy of
            Nothing -> newGlobalID ns
            Just ty -> newIDByType ns ty
    put ns'
    return idNum

newName :: Maybe Type -> Name -> Uniq Name
newName mbTy name = do
    u <- newUnique mbTy
    return name{ nameUnique = u }

lower :: Variable -> Uniq a -> Uniq a
lower old action =
    case variableType old of
        StaticNode n -> do
            newNames <- replicateM n (newName (Just Node) (variableName old))
            let newVars =
                    [ Variable name Primitive | name <- newNames ]
            local (Map.insert old newVars) action
        _  -> action

lowerMany :: [Variable] -> Uniq a -> Uniq a
lowerMany xs action = foldr lower action xs

resolve :: Variable -> Uniq [Variable]
resolve var = asks $ Map.findWithDefault [var] var

resolveMany :: [Variable] -> Uniq [Variable]
resolveMany = fmap concat . mapM resolve

uniqModule :: Module -> Uniq Module
uniqModule m =
    --lowerMany [ name | NodeDefinition name _args <- nodes m ] $
    do
        ns  <- mapM uniqNode (nodes m)
        fns <- mapM uniqFunction (functions m)
        namespace <- get
        return Module
            { modForeigns = modForeigns m
            , nodes = ns
            , entryPoint = entryPoint m
            , functions = fns
            , modNamespace = namespace
            }

uniqNode :: NodeDefinition -> Uniq NodeDefinition
uniqNode = return {-
uniqNode (NodeDefinition name args) = 
    NodeDefinition <$> resolveName name <*> pure args
-}
uniqFunction :: Function -> Uniq Function
uniqFunction (Function name args rets body) = lowerMany args $
    Function
        <$> pure name -- resolveName name
        <*> resolveMany args
        <*> pure rets
        <*> uniqExpression body

bindMany lst rest = foldr (\(bind, arg) -> Bind [bind] (Unit arg)) rest lst

uniqExpression expr =
    case expr of
        Case scrut mbBranch alts -> do
            (tag:args) <- resolve scrut
            Case
                <$> pure tag
                <*> uniqMaybe uniqExpression mbBranch
                <*> mapM (uniqAlternative args) alts
        Bind [bind] (Unit (RefArg var)) rest -> lower bind $ do
            nodeBinds <- resolve bind
            varArgs   <- resolve var
            bindMany (zip nodeBinds (map RefArg varArgs))
                <$> uniqExpression rest
        Bind [bind] (Unit (LitArg lit)) rest -> lower bind $
            Bind
                <$> resolve bind
                <*> pure (Unit (LitArg lit))
                <*> uniqExpression rest
        Bind [bind] (Unit (NodeArg nodeName nodeArgs)) rest -> lower bind $ do
            nodeBinds <- resolve bind
            rest' <- uniqExpression rest
            return $ bindMany 
                (zip nodeBinds (NodeArg nodeName [] : map RefArg nodeArgs))
                rest'
        Bind binds (Fetch ptr) rest -> lowerMany binds $ do
            binds' <- resolveMany binds
            rest' <- uniqExpression rest
            return $ foldr (\(n,b) -> Bind [b] (Load ptr n)) rest' (zip [0..] binds')
        Bind [bind] (Store nodeName args) rest -> do
            args' <- resolveMany args
            rest' <- uniqExpression rest
            return $
                Bind [] (Alloc $ 1 + length args) $
                Bind [bind] (Store nodeName args') rest'
        Bind binds simple rest -> lowerMany binds $
            Bind
                <$> resolveMany binds
                <*> uniqSimple simple
                <*> uniqExpression rest
        Return vars ->
            Return <$> resolveMany vars
        Throw var ->
            pure $ Throw var
        TailCall fn vars ->
            TailCall fn <$> resolveMany vars
        Invoke fn vars ->
            Invoke <$> pure fn <*> resolveMany vars
        Exit -> pure Exit
        Panic msg -> pure (Panic msg)

uniqAlternative :: [Variable] -> Alternative -> Uniq Alternative
uniqAlternative args (Alternative pattern branch) =
    case pattern of
        LitPat{} -> Alternative pattern <$> uniqExpression branch
        NodePat nodeName vars -> lowerMany vars $
            Alternative
                <$> pure (NodePat nodeName [])
                <*> (bindMany (zip vars (map RefArg args)) <$> uniqExpression branch)


uniqMaybe :: (a -> Uniq a) -> Maybe a -> Uniq (Maybe a)
uniqMaybe fn obj =
    case obj of
        Nothing  -> return Nothing
        Just val -> Just <$> fn val

uniqSimple :: Expression -> Uniq Expression
uniqSimple simple =
    case simple of
        Literal lit ->
            pure (Literal lit)
        Application fn vars ->
            Application fn <$> resolveMany vars
        CCall fn vars ->
            CCall fn <$> resolveMany vars
        WithExceptionHandler exh exhArgs fn fnArgs ->
            WithExceptionHandler
                <$> pure exh <*> resolveMany exhArgs
                <*> pure fn <*> resolveMany fnArgs
        Alloc n ->
            pure (Alloc n)
        SizeOf{} -> error "uniqSimple: SizeOf"
        Store nodeName vars ->
            Store <$> pure nodeName <*> resolveMany vars
        Fetch var ->
            pure $ Fetch var
        Load{} -> error "uniqSimple: Load"
        Add a b ->
            pure $ Add a b
        Eval var ->
            pure $ Eval var
        Apply a b ->
            pure $ Apply a b
        ReadGlobal{} -> error "uniqSimple: ReadGlobal"
        WriteGlobal{} -> error "uniqSimple: WriteGlobal"
        Unit args ->
            pure $ Unit args
        GCAllocate n ->
            pure (GCAllocate n)
        GCBegin -> pure GCBegin
        GCEnd -> pure GCEnd
        GCMark var ->
            pure $ GCMark var
        GCMarkNode var ->
            pure $ GCMarkNode var


