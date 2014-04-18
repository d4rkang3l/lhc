{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Bedrock.Rename (unique) where

import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Map             (Map)
import qualified Data.Map             as Map
import Control.Applicative ( (<$>), (<*>), Applicative, pure )

import Data.Bedrock

type Env = Map Name Name

newtype Uniq a = Uniq { unUniq :: ReaderT Env (State Int) a }
    deriving ( Monad, MonadReader Env, MonadState Int, Functor
             , Applicative )

unique :: Module -> Module
unique m = evalState (runReaderT (unUniq (uniqModule m)) env) st
  where
    env = Map.empty
    st = 0



newUnique :: Uniq Int
newUnique = do
    u <- get
    put $ u+1
    return u

newName :: Name -> Uniq Name
newName name = do
    u <- newUnique
    return name{ nameUnique = u } 

rename :: Name -> Uniq a -> Uniq a
rename old action = do
    new <- newName old
    local (Map.insert old new) action

renameAll :: [Name] -> Uniq a -> Uniq a
renameAll [] action = action
renameAll (x:xs) action = rename x (renameAll xs action)

renameVariables :: [Variable] -> Uniq a -> Uniq a
renameVariables = renameAll . map variableName

resolveName :: Name -> Uniq Name
resolveName name = do
    m <- ask
    case Map.lookup name m of
        Nothing  -> error $ "Unresolved identifier: " ++ nameIdentifier name
        Just new -> return new

resolveNodeName :: NodeName -> Uniq NodeName
resolveNodeName nodeName =
    case nodeName of
        ConstructorName name ->
            ConstructorName <$> resolveName name
        FunctionName name blanks ->
            FunctionName <$> resolveName name <*> pure blanks

resolve :: Variable -> Uniq Variable
resolve var = do
    name <- resolveName (variableName var)
    return var{ variableName = name }

resolveArgument :: Argument -> Uniq Argument
resolveArgument arg =
    case arg of
        RefArg var            ->
            RefArg <$> resolve var
        LitArg lit            ->
            pure (LitArg lit)
        NodeArg nodeName vars ->
            NodeArg <$> resolveNodeName nodeName <*> mapM resolve vars

uniqModule :: Module -> Uniq Module
uniqModule m =
    renameAll [ name | NodeDefinition name _args <- nodes m ] $
    renameAll (map fnName (functions m)) $ do
        ns  <- mapM uniqNode (nodes m)
        fns <- mapM uniqFunction (functions m)
        return Module
            { nodes = ns
            , functions = fns }

uniqNode :: NodeDefinition -> Uniq NodeDefinition
uniqNode (NodeDefinition name args) =
    NodeDefinition <$> resolveName name <*> pure args

uniqFunction :: Function -> Uniq Function
uniqFunction (Function name args rets body) = renameVariables args $
    Function
        <$> resolveName name
        <*> mapM resolve args
        <*> pure rets
        <*> uniqExpression body

uniqExpression :: Expression -> Uniq Expression
uniqExpression expr =
    case expr of
        Case scrut mbBranch alts ->
            Case
                <$> resolve scrut
                <*> uniqMaybe uniqExpression mbBranch
                <*> mapM uniqAlternative alts
        Bind binds simple rest -> renameVariables binds $
            Bind
                <$> mapM resolve binds
                <*> uniqSimple simple
                <*> uniqExpression rest
        Return vars ->
            Return <$> mapM resolve vars
        Throw var ->
            Throw <$> resolve var
        TailCall fn vars ->
            TailCall <$> resolveName fn <*> mapM resolve vars
        Invoke fn vars ->
            Invoke <$> resolve fn <*> mapM resolve vars
        Exit -> pure Exit
        Panic msg -> pure (Panic msg)

uniqAlternative :: Alternative -> Uniq Alternative
uniqAlternative (Alternative pattern branch) =
    case pattern of
        LitPat{} -> Alternative pattern <$> uniqExpression branch
        NodePat nodeName vars ->
            renameVariables vars $ do
                Alternative
                    <$> (NodePat
                        <$> resolveNodeName nodeName
                        <*> mapM resolve vars)
                    <*> uniqExpression branch


uniqMaybe :: (a -> Uniq a) -> Maybe a -> Uniq (Maybe a)
uniqMaybe fn obj =
    case obj of
        Nothing  -> return Nothing
        Just val -> Just <$> fn val

uniqSimple :: SimpleExpression -> Uniq SimpleExpression
uniqSimple simple =
    case simple of
        Literal lit ->
            pure (Literal lit)
        Application fn vars ->
            Application <$> resolveName fn <*> mapM resolve vars
        WithExceptionHandler exh exhArgs fn fnArgs ->
            WithExceptionHandler
                <$> resolveName exh <*> mapM resolve exhArgs
                <*> resolveName fn <*> mapM resolve fnArgs
        Alloc n ->
            pure (Alloc n)
        SizeOf{} -> error "uniqSimple: SizeOf"
        Store nodeName vars ->
            Store <$> resolveNodeName nodeName <*> mapM resolve vars
        Fetch var ->
            Fetch <$> resolve var
        Load{} -> error "uniqSimple: Load"
        Add a b ->
            Add <$> resolve a <*> resolve b
        Print var ->
            Print <$> resolve var
        ReadGlobal{} -> error "uniqSimple: ReadGlobal"
        WriteGlobal{} -> error "uniqSimple: WriteGlobal"
        Unit args ->
            Unit <$> mapM resolveArgument args
        GCAllocate n ->
            pure (GCAllocate n)
        GCBegin -> pure GCBegin
        GCEnd -> pure GCEnd
        GCMark var ->
            GCMark <$> resolve var
        GCMarkNode var ->
            GCMarkNode <$> resolve var


