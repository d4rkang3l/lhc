{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Compiler.HaskellToCore
    ( convert
    ) where

import           Control.Monad.Reader
import           Control.Monad.RWS                (RWS, execRWS)
import           Control.Monad.State
import           Control.Monad.Writer             (MonadWriter (..))
import           Data.List                        (transpose)
import           Data.Map                         (Map)
import qualified Data.Map                         as Map
import           Data.Maybe
import qualified Data.Set                         as Set
import qualified Language.Haskell.Exts.Annotated  as HS

import           Compiler.Core
import           Data.Bedrock                     (AvailableNamespace (..),
                                                   CType (..), Foreign (..),
                                                   Name (..), Type (..))
import           Data.Bedrock.Misc
import           Language.Haskell.Scope           (GlobalName (..),
                                                   NameInfo (..), Origin (..),
                                                   QualifiedName (..),
                                                   getNameIdentifier)
import qualified Language.Haskell.Scope           as Scope
import           Language.Haskell.TypeCheck.Monad (TcEnv (..), mkBuiltIn, noSrcSpanInfo)
import           Language.Haskell.TypeCheck.Types (Coercion (..), Qual (..),
                                                   TcType (..), TcVar(..),Pred(..))

import           Debug.Trace

data Scope = Scope
    { scopeVariables    :: Map GlobalName Name
    , scopeNodes        :: Map QualifiedName Name
    , scopeConstructors :: Map GlobalName Name -- XXX: Merge with scopeNodes?
    , scopeTcEnv        :: TcEnv
    , scopeArity        :: Map GlobalName Int
    }
instance Monoid Scope where
    mempty = Scope
        { scopeVariables    = Map.empty
        , scopeNodes        = Map.empty
        , scopeConstructors = Map.empty
        , scopeTcEnv        = TcEnv
            { -- Globals such as Nothing, Just, etc
              tcEnvValues    = Map.empty
            , tcEnvUnique    = 0
            , tcEnvCoercions = Map.empty
            , tcEnvRecursive = Set.empty
            , tcEnvKnots     = []
            }
        , scopeArity         = Map.empty
        }
    mappend a b = Scope
        { scopeVariables    = w scopeVariables
        , scopeNodes        = w scopeNodes
        , scopeConstructors = w scopeConstructors
        , scopeTcEnv        = scopeTcEnv a
        , scopeArity        = w scopeArity }
        where w f = mappend (f a) (f b)

data Env = Env
    { envScope        :: Scope
    , envForeigns     :: [Foreign]
    , envNodes        :: [NodeDefinition]
    , envNewTypes     :: [NewType]
    , envDecls        :: [Decl]
    , envConstructors :: Map Name Name
    }

instance Monoid Env where
    mempty = Env
        { envScope    = mempty
        , envForeigns = mempty
        , envNodes    = mempty
        , envNewTypes = mempty
        , envDecls    = mempty
        , envConstructors = mempty
        }
    mappend a b = Env
        { envScope    = w envScope
        , envForeigns = w envForeigns
        , envNodes    = w envNodes
        , envNewTypes = w envNewTypes
        , envDecls    = w envDecls
        , envConstructors = w envConstructors
        }
        where w f = mappend (f a) (f b)

newtype M a = M { unM :: RWS Scope Env AvailableNamespace a }
    deriving
        ( Monad, Functor, Applicative
        , MonadReader Scope, MonadState AvailableNamespace
        , MonadWriter Env )

runM :: TcEnv -> M a -> (AvailableNamespace, Env)
runM tcEnv m = (ns', env)
  where
    (ns', env) = execRWS (unM m) ((envScope env){ scopeTcEnv = tcEnv }) ns
    ns = AvailableNamespace 0 0 0 0

pushForeign :: Foreign -> M ()
pushForeign f = tell mempty{ envForeigns = [f] }

pushDecl :: Decl -> M ()
pushDecl decl = tell mempty{ envDecls = [decl] }

pushNode :: NodeDefinition -> M ()
pushNode def = tell mempty{ envNodes = [def] }

pushNewType :: NewType -> M ()
pushNewType def = tell mempty{ envNewTypes = [def] }

newUnique :: M Int
newUnique = do
    ns <- get
    let (idNum, ns') = newGlobalID ns
    put ns'
    return idNum

newName :: String -> M Name
newName ident = do
    u <- newUnique
    return $ Name [] ident u

bindName :: HS.Name Origin -> M Name
bindName hsName =
    case info of
        Scope.Resolved gname@(GlobalName src qname@(QualifiedName m ident)) -> do
            let name = Name [m] (getNameIdentifier hsName) 0
            tell $ mempty{envScope = mempty
                { scopeVariables = Map.singleton gname name } }
            return name
        _ -> error "bindName"
  where
    Origin info _ = HS.ann hsName

bindVariable :: HS.Name Origin -> M Variable
bindVariable hsName = do
    name <- bindName hsName
    ty <- lookupType hsName
    return $ Variable name ty
  where
    Origin info _ = HS.ann hsName

lookupType :: HS.Name Origin -> M TcType
lookupType hsName = do
    case info of
        Resolved gname -> do
            tcEnv <- asks scopeTcEnv
            case Map.lookup gname (tcEnvValues tcEnv) of
                Nothing -> error "Missing type info"
                Just ty -> return ty
  where
    Origin info _ = HS.ann hsName

bindConstructor :: HS.Name Origin -> Int -> M Name
bindConstructor dataCon arity =
    case info of
        Resolved global@(GlobalName src qname@(QualifiedName m ident)) -> do
            let n = Name [m] ident 0
            tell $ mempty{envScope = mempty
                { scopeNodes = Map.singleton qname n
                , scopeVariables = Map.singleton global n
                , scopeArity = Map.singleton global arity } }
            return n
        _ -> error "bindName"
  where
    Origin info _ = HS.ann dataCon

resolveName :: HS.Name Origin -> M Name
resolveName hsName =
    case info of
        Scope.Resolved gname@(GlobalName src qname@(QualifiedName m ident)) -> do
            let name = Name [m] (getNameIdentifier hsName) 0
            return name
        -- Resolved gname -> do
        --     asks $ Map.findWithDefault scopeError gname . scopeVariables
        --Scope.Global gname ->
        --    asks $ Map.findWithDefault scopeError gname . scopeConstructors
        _ -> error "resolveName"
  where
    Origin info _ = HS.ann hsName
    scopeError = error $ "resolveName: Not in scope: " ++
                    getNameIdentifier hsName

-- resolveQualifiedName :: QualifiedName -> M Name
-- resolveQualifiedName qname =
--     asks $ Map.findWithDefault scopeError qname . scopeNodes
--   where
--     scopeError = error $ "resolveGlobalName: Not in scope: " ++ show qname

resolveQName :: HS.QName Origin -> M Variable
resolveQName qname =
    case qname of
        HS.Qual _ _ name          -> do
          n <- resolveName name
          ty <- lookupType name
          return $ Variable n ty
        HS.UnQual _ name          -> do
          n <- resolveName name
          ty <- lookupType name
          return $ Variable n ty
        HS.Special _ HS.UnitCon{} -> return unitCon
        HS.Special _ HS.Cons{}    -> return consCon
        -- HS.Special _ HS.ListCon{} -> return nilCon
        _ -> error $ "HaskellToCore.resolveQName: " ++ show qname

unQName :: HS.QName Origin -> HS.Name Origin
unQName qname =
    case qname of
        HS.Qual _ _ name -> name
        HS.UnQual _ name -> name

-- XXX: Ugly, ugly code.
-- resolveQGlobalName :: HS.QName Origin -> M Name
-- resolveQGlobalName qname =
--     case qname of
--         HS.Qual _ _ name          -> worker name
--         HS.UnQual _ name          -> worker name
--         HS.Special _ HS.UnitCon{} -> return unitCon
--         HS.Special _ HS.Cons{}    -> return consCon
--         HS.Special _ HS.ListCon{} -> return nilCon
--         _ -> error "HaskellToCore.resolveQName"
--   where
--     worker name =
--         let Origin (Resolved (GlobalName _ qname)) _ = HS.ann name
--         in resolveQualifiedName qname

findCoercion :: HS.SrcSpanInfo -> M Coercion
findCoercion src = do
    tiEnv <- asks scopeTcEnv
    return $ Map.findWithDefault CoerceId src (tcEnvCoercions tiEnv)

requireCoercion :: HS.SrcSpanInfo -> M Coercion
requireCoercion src = do
    tiEnv <- asks scopeTcEnv
    return $ Map.findWithDefault err src (tcEnvCoercions tiEnv)
  where
    err = error $ "Coercion required at: " ++ show src

--resolveConstructor :: HS.QName Scoped -> M Name
--resolveConstructor con = do
--    name <- resolveQName con
--    asks

convert :: TcEnv -> HS.Module Origin -> Module
convert tcEnv (HS.Module _ _ _ _ decls) = Module
    { coreForeigns  = envForeigns env
    , coreDecls     = envDecls env
    , coreNodes     = envNodes env
    , coreNewTypes  = envNewTypes env
    , coreNamespace = ns }
  where
    (ns, env) = runM tcEnv $ do
        mapM_ convertDecl decls
convert _ _ = error "HaskellToCore.convert"

-- Return function name.
matchInfo :: [HS.Match Origin] -> HS.Name Origin
matchInfo [] =
    error "Compiler.HaskellToCore.matchInfo"
matchInfo (HS.Match _ name pats _ _:_) = name
matchInfo (HS.InfixMatch _ _ name pats rhs _:_) = name

{-
Sometimes we have introduce new arguments:
fn (Just val) = ...
=>
fn arg = case arg of Just val -> ...

In the above case we cannot find a good name but in many cases we can do
better. Consider:
fn x@(Just val) = ...
=>
fn x = case x of Just val -> ...

fn [] = ...
fn lst = ...
=>
fn lst = case lst of [] -> ...; _ -> ...

matchArgNames uses heuristics to figure out which user variable names can be
reused.
-}
matchArgNames :: [HS.Match Origin] -> [Maybe (HS.Name Origin)]
matchArgNames = map collapse . transpose . map worker
  where
    collapse = listToMaybe . catMaybes
    worker (HS.Match _ _ pats _ _) = map fromPat pats
    worker (HS.InfixMatch _ pat _ pats _ _) = map fromPat (pat:pats)
    fromPat (HS.PVar _ name) = Just name
    fromPat (HS.PAsPat _ name _) = Just name
    fromPat (HS.PParen _ pat) = fromPat pat
    fromPat _ = Nothing

convertDecl :: HS.Decl Origin -> M ()
convertDecl decl =
    mapM_ pushDecl =<< convertDecl' decl

convertDecl' :: HS.Decl Origin -> M [Decl]
convertDecl' decl =
    case decl of
        HS.FunBind _ matches -> do
            let name = matchInfo matches
                fnArgNames = matchArgNames matches
                arity = length fnArgNames
            let Origin _ src = HS.ann name
            coercion <- findCoercion src
            ty <- lookupType name
            let argTys = splitTy (applyCoercion coercion ty)
            argNames <- forM fnArgNames $ \mbName ->
              case mbName of
                Nothing -> newName "arg"
                Just name -> bindName name
            let args = zipWith Variable argNames argTys
            decl <- Decl
                <$> pure ty
                <*> bindName name
                <*> (WithCoercion coercion . Lam args
                        <$> convertMatches args matches)
            return [decl]
        HS.FunBind _ [HS.Match _ name pats rhs _] -> do
            let Origin _ src = HS.ann name
            coercion <- findCoercion src
            decl <- Decl
                <$> lookupType name
                <*> bindName name
                <*> (WithCoercion coercion <$> convertPats pats rhs)
            return [decl]
        HS.FunBind _ [HS.InfixMatch _ leftPat name rightPats rhs _] -> do
            let Origin _ src = HS.ann name
            coercion <- findCoercion src
            decl <- Decl
                <$> lookupType name
                <*> bindName name
                <*> (WithCoercion coercion
                        <$> convertPats (leftPat:rightPats) rhs)
            return [decl]
        HS.PatBind _ (HS.PVar _ name) rhs _binds -> do
            decl <- Decl
                <$> lookupType name
                <*> bindName name
                <*> convertRhs rhs
            return [decl]
        HS.ForImp _ _conv _safety mbExternal name ty -> do
            let external = fromMaybe (getNameIdentifier name) mbExternal
            foreignTy <- lookupType name
            decl <- Decl
                <$> lookupType name
                <*> bindName name
                <*> convertExternal external foreignTy

            unless (isPrimitive external) $ do
                let (argTypes, _isIO, retType) = ffiTypes foreignTy
                pushForeign $ Foreign
                    { foreignName = external
                    , foreignReturn = toCType retType
                    , foreignArguments = map toCType argTypes }

            return [decl]

        HS.DataDecl _ HS.DataType{} _ctx _dhead qualCons _deriving -> do
            mapM_ (convertQualCon False) qualCons
            return []
        HS.DataDecl _ HS.NewType{} _ctx _dhead qualCons _deriving -> do
            mapM_ (convertQualCon True) qualCons
            return []
        HS.TypeSig{} -> return []
        _ -> error $ "Compiler.HaskellToCore.convertDecl: " ++ show decl

isPrimitive "realWorld" = True
isPrimitive _ = False

convertMatches :: [Variable] -> [HS.Match Origin] -> M Expr
convertMatches args [] = error "Compiler.HaskellToCore.convertMatches"
convertMatches args [HS.InfixMatch _ pat _ pats rhs mbBinds] =
    convertAltPats (zip args (pat:pats)) Nothing =<< convertRhs rhs
convertMatches args [HS.Match _ _ pats rhs mbBinds] =
    convertAltPats (zip args pats) Nothing =<< convertRhs rhs
convertMatches args (HS.Match _ _ pats rhs mbBinds:xs)
    | all isSimplePat pats = do
        rest <- convertMatches args xs
        convertAltPats (zip args pats) (Just rest) =<<
                convertRhs rhs
    | otherwise = do
        rest <- convertMatches args xs
        restBranch <- Variable <$> newName "branch" <*> exprType rest
        e <- convertAltPats (zip args pats) (Just $ Var restBranch) =<<
                convertRhs rhs
        return $ Let (NonRec restBranch rest) e

convertAltPats :: [(Variable, HS.Pat Origin)] -> Maybe Expr -> Expr -> M Expr
convertAltPats conds failBranch successBranch =
    case conds of
        [] -> pure successBranch
        ((scrut,pat) : more)
            | isSimplePat pat -> do
                convertAltPat scrut failBranch pat =<<
                    convertAltPats more failBranch successBranch
            | otherwise -> do
                rest <- convertAltPats more failBranch successBranch
                restBranch <- Variable <$> newName "branch" <*> exprType rest
                e <- convertAltPat scrut failBranch pat (Var restBranch)
                return $ Let (NonRec restBranch rest) e


-- XXX: Don't use Bool for isNewtype
convertQualCon :: Bool -> HS.QualConDecl Origin -> M ()
convertQualCon isNewtype (HS.QualConDecl _ _tyvars _ctx con) =
    convertConDecl isNewtype con

-- XXX: Don't use Bool for isNewtype
convertConDecl :: Bool -> HS.ConDecl Origin -> M ()
convertConDecl isNewtype con =
    case con of
        HS.ConDecl _ name tys -> do

            u <- newUnique
            let mkCon = Name [] ("mk" ++ getNameIdentifier name) u

            conName <- bindConstructor name (length tys)

            argNames <- replicateM (length tys) (newName "arg")
            ty <- lookupType name
            let con = Variable conName ty
            let args = zipWith Variable argNames (splitTy ty)
            -- pushDecl $ Decl ty mkCon (Lam args $ Con conName args)

            -- pushNode $ NodeDefinition conName (init $ splitTy ty)
            if isNewtype
                then pushNewType $ NewType con
                else pushNode $ NodeDefinition conName (init $ splitTy ty)
        --HS.RecDecl _ name fieldDecls -> do
        _ -> error "convertCon"

-- XXX: Temporary measure. 2014-07-11
splitTy (TcForall _ (_ :=> ty)) = splitTy ty
splitTy (TcFun a b) = a : splitTy b
splitTy ty = [ty]

applyCoercion :: Coercion -> TcType -> TcType
applyCoercion (CoerceAbs new) (TcForall old (ctx :=> ty)) =
    TcForall new (map predicate ctx :=> worker ty)
  where
    env = zip old new
    predicate (IsIn cls ty) = IsIn cls (worker ty)
    worker ty =
      case ty of
        TcForall{} ->
          error "Compiler.HaskellToCore.applyCoercion: RankNTypes not supported"
        TcFun a b -> TcFun (worker a) (worker b)
        TcApp a b -> TcApp (worker a) (worker b)
        TcRef v ->
          case lookup v env of
            Nothing -> TcRef v
            Just new -> TcRef new
        TcCon{} -> ty
        TcMetaVar{} -> ty
        TcUnboxedTuple tys -> TcUnboxedTuple (map worker tys)
        TcTuple tys -> TcTuple (map worker tys)
        TcList ty -> TcList (worker ty)
        TcUndefined -> TcUndefined
applyCoercion _ ty = ty

toCType :: TcType -> CType
toCType ty =
    case ty of
        TcApp (TcCon qname) ty'
            | qname == mkBuiltIn "LHC.Prim" "Addr" ->
                CPointer (toCType ty')
        TcCon qname
            | qname == mkBuiltIn "LHC.Prim" "I8" ->
                I8
            | qname == mkBuiltIn "LHC.Prim" "I32" ->
                I32
            | qname == mkBuiltIn "LHC.Prim" "Int32" ->
                I32
            | qname == mkBuiltIn "LHC.Prim" "I64" ->
                I64
            | qname == mkBuiltIn "LHC.Prim" "Unit" ->
                CVoid
        TcApp (TcCon qname) ty'
            | qname == mkBuiltIn "LHC.Prim" "IO" ->
                toCType ty'
        TcCon qname
            | qname == mkBuiltIn "LHC.Prim" "RealWorld#" ->
                I64
        _ -> error $ "toCType: " ++ show ty

-- convertBangType :: HS.BangType Origin -> M Type
-- convertBangType bty =
--     case bty of
--         HS.UnBangedTy _ ty -> convertType ty
--         HS.BangedTy _ ty -> convertType ty
--         _ -> error "convertBangType"

convertType :: HS.Type Origin -> M Type
convertType ty =
    case ty of
        --HS.TyCon _ qname
        --    | toGlobalName qname == GlobalName "Main" "I8"
        --    -> pure $ Primitive I8
        --    | toGlobalName qname == GlobalName "Main" "I32"
        --    -> pure $ Primitive I32
        --    | toGlobalName qname == GlobalName "Main" "I64"
        --    -> pure $ Primitive I64
        --    | toGlobalName qname == GlobalName "Main" "RealWorld"
        --    -> pure NodePtr -- $ Primitive CVoid
        --HS.TyApp _ (HS.TyCon _ qname) sub
        --    | toGlobalName qname == GlobalName "Main" "Addr"
        --    -> do
        --        subTy <- convertType sub
        --        case subTy of
        --            Primitive p -> pure $ Primitive (CPointer p)
        --            _ -> error "Addr to non-primitive type"
        HS.TyParen _ sub ->
            convertType sub
        HS.TyVar{} -> pure NodePtr
        HS.TyCon{} -> pure NodePtr
        HS.TyFun{} -> pure NodePtr
        _ -> error $ "convertType: " ++ show ty -- pure NodePtr


-- cfun :: Addr I8 -> IO ()
-- \ptr -> IO (\s -> WithExternal cfun Void [ptr,s]) (IOUnit boxed s))
-- cfun :: Addr I8 -> IO CInt
-- \ptr -> IO (\s -> WithExternal cfun CInt [ptr,s]) (IOUnit boxed s))
-- cfun :: CInt -> CInt
-- \cint -> WithExternal cfun [cint] boxed
convertExternal :: String -> TcType -> M Expr
convertExternal "realworld#" _ty = return (Lit (LitInt 0))
convertExternal cName ty
    | isIO = do
        args <- forM argTypes $ \t -> Variable <$> newName "arg" <*> pure t
        primArgs <- return args
        primOut <- Variable <$> newName "primOut" <*> pure i32
        s <- Variable
                <$> newName "s"
                <*> pure realWorld
        -- boxed <- Variable <$> newName "boxed" <*> pure retType

        return $
            Lam args $
            let action = Lam [s] $
                    WithExternal primOut cName primArgs s $
                    UnboxedTuple [Var s, App (Con int32Con) (Var primOut)]
            in action -- (App (WithCoercion (CoerceAp [retType]) (Con ioCon)) action)
    | otherwise = do -- not isIO
        args <- forM argTypes $ \t -> Variable <$> newName "arg" <*> pure t
        primOut <- Variable <$> newName "primOut" <*> pure retType
        return $
            Lam args $
            ExternalPure primOut cName args $
            Var primOut
  where
    (argTypes, isIO, retType) = ffiTypes ty
-- convertExternal cName ty
--     | isIO      = do
--         out <- newName "out"
--         boxed <- newName "boxed"
--         let outV = Variable out retType
--             boxedV = Variable boxed retType
--         io <- resolveQualifiedName $ mkBuiltIn "LHC.Prim" "IO"
--         unit <- resolveQualifiedName $ mkBuiltIn "LHC.Prim" "IOUnit"
--         cint <- resolveQualifiedName $ mkBuiltIn "LHC.Prim" "Int32"
--         pure $ Lam args $ App (Lam [tmp] (App (Con io) (Var tmp)))
--                 (Lam [s]
--             (WithExternal outV cName args s
--                 (Let (NonRec boxedV $ App (Con cint) (Var outV)) $
--                     App (App (Con unit) (Var boxedV)) (Var s))))
--     -- | otherwise = pure $ Lam args (ExternalPure cName retType args)
--   where
--     tmp = Variable (Name [] "tmp" 0) TcUndefined
--     s = Variable (Name [] "s" 0) TcUndefined -- NodePtr
--     (argTypes, isIO, retType) = ffiTypes ty
--     args =
--         [ Variable (Name [] "arg" 0) t -- (Primitive t)
--         | t <- argTypes ]

--packCType :: CType -> Expr -> M Expr
--packCType

ffiTypes :: TcType -> ([TcType], Bool, TcType)
ffiTypes = worker []
  where
    worker acc ty =
        case ty of
            TcFun t ty' -> worker (t : acc) ty'
            TcApp (TcCon qname) sub
                | qname == mkBuiltIn "LHC.Prim" "IO"
                    -> (reverse acc, True, sub)
            _ -> (reverse acc, False, ty)
            --_ -> error "ffiArguments"

convertPats :: [HS.Pat Origin] -> HS.Rhs Origin -> M Expr
convertPats [] rhs = convertRhs rhs
convertPats pats rhs =
    Lam <$> sequence [ bindVariable name
                    | HS.PVar _ name <- pats ]
        <*> (convertRhs rhs)

convertRhs :: HS.Rhs Origin -> M Expr
convertRhs rhs =
    case rhs of
        HS.UnGuardedRhs _ expr -> convertExp expr
        _ -> error "convertRhs"

convertStmts :: [HS.Stmt Origin] -> M Expr
convertStmts [] = error "convertStmts: Empty list"
convertStmts [end] =
    case end of
        -- HS.Generator _ pat expr
        HS.Qualifier _ expr -> convertExp expr
        _ -> error $ "convertStmts: " ++ show end
convertStmts (x:xs) =
    case x of
        HS.Generator (Origin _ src) (HS.PVar _ name) expr -> do
            var <- bindVariable name
            expr' <- convertExp expr
            rest <- convertStmts xs
            coercion <- findCoercion src
            return $ WithCoercion coercion primBindIO `App` expr' `App` Lam [var] rest
        HS.Qualifier (Origin _ src) expr -> do
            expr' <- convertExp expr
            rest <- convertStmts xs
            coercion <- findCoercion src
            return $ WithCoercion coercion primThenIO `App` expr' `App` rest

primThenIO :: Expr
primThenIO = Var (Variable name ty)
  where
    name = Name ["LHC.Prim"] "thenIO" 0
    ty = TcForall [aRef, bRef] ([] :=> (ioA `TcFun` ioB `TcFun` ioB))
    aRef = TcVar "a" noSrcSpanInfo
    bRef = TcVar "b" noSrcSpanInfo
    io = TcCon (mkBuiltIn "LHC.Prim" "IO")
    ioA = io `TcApp` TcRef aRef
    ioB = io `TcApp` TcRef bRef

primBindIO :: Expr
primBindIO = Var (Variable name ty)
  where
    name = Name ["LHC.Prim"] "bindIO" 0
    ty = TcForall [aRef, bRef] ([] :=> (ioA `TcFun` ioAB `TcFun` ioB))
    aRef = TcVar "a" noSrcSpanInfo
    bRef = TcVar "b" noSrcSpanInfo
    io = TcCon (mkBuiltIn "LHC.Prim" "IO")
    ioA = io `TcApp` TcRef aRef
    ioB = io `TcApp` TcRef bRef
    ioAB = TcRef aRef `TcFun` ioB

convertExp :: HS.Exp Origin -> M Expr
convertExp expr =
    case expr of
        HS.Var _ name -> do
            let Origin _ src = HS.ann name
            coercion <- findCoercion src
            var <- resolveQName name
            return $ WithCoercion coercion (Var var)
        HS.Con _ name -> do
            let Origin _ src = HS.ann name
            coercion <- findCoercion src
            var <- resolveQName name
            return $ WithCoercion coercion (Con var)
        HS.App _ a b ->
            App
                <$> convertExp a
                <*> convertExp b
        HS.InfixApp _ a (HS.QConOp _ con) b -> do
            ae <- convertExp a
            be <- convertExp b
            let Origin _ src = HS.ann con
            coercion <- findCoercion src
            var <- resolveQName con
            pure $ App (App (WithCoercion coercion (Con var)) ae) be
        HS.InfixApp _ a (HS.QVarOp _ var) b -> do
            ae <- convertExp a
            be <- convertExp b
            let Origin _ src = HS.ann var
            coercion <- findCoercion src
            var <- resolveQName var
            pure $ App (App (WithCoercion coercion (Var var)) ae) be
        HS.Paren _ sub -> convertExp sub
        HS.Lambda _ pats sub ->
            Lam
                <$> sequence [ bindVariable name
                        | HS.PVar _ name <- pats ]
                <*> convertExp sub
        HS.Case _ scrut alts -> do
            scrut' <- convertExp scrut
            scrutVar <- Variable <$> newName "scrut" <*> exprType scrut'
            def <- convertAlts scrutVar alts
            return $ Case scrut' scrutVar (Just def) []
        HS.Lit _ (HS.Char _ c _) ->
            pure $ Con charCon `App` Lit (LitChar c)
        HS.Lit _ (HS.Int _ i _) ->
            pure $ Con intCon `App` (Var i64toi32 `App` Lit (LitInt i))
        HS.Lit _ lit -> pure $ Lit (convertLiteral lit)
        HS.Tuple  _ HS.Unboxed exprs -> do
            args <- mapM convertExp exprs
            return $ UnboxedTuple args
        HS.Let _ (HS.BDecls _ binds) expr -> do
            decls <- mapM convertDecl' binds
            Let (Rec [ (Variable name ty, body)
                     | Decl ty name body <- concat decls ])
                <$> convertExp expr
        HS.List (Origin _ src) [] -> do
            coercion <- requireCoercion src
            return $ WithCoercion coercion (Con nilCon)
        HS.Do _ stmts -> do
            convertStmts stmts
        _ -> error $ "H->C convertExp: " ++ show expr

convertAlts :: Variable -> [HS.Alt Origin] -> M Expr
convertAlts scrut [] = pure $ Case (Var scrut) scrut Nothing []
convertAlts scrut [HS.Alt _ pat rhs Nothing] =
    convertAltPat scrut Nothing pat =<< convertRhs rhs
convertAlts scrut (HS.Alt _ pat rhs Nothing:alts) = do
    rest <- convertAlts scrut alts
    restBranch <- Variable <$> newName "branch" <*> exprType rest
    if isSimplePat pat
        then
            convertAltPat scrut (Just rest) pat =<< convertRhs rhs
        else do
            e <- convertAltPat scrut (Just $ Var restBranch) pat =<< convertRhs rhs
            return $ Let (NonRec restBranch rest) e

isSimplePat :: HS.Pat Origin -> Bool
isSimplePat pat =
    case pat of
        HS.PApp _ name pats -> all isPVar pats
        HS.PInfixApp _ a name b -> all isPVar [a,b]
        HS.PVar{} -> True
        HS.PLit{} -> True
        HS.PParen _ pat' -> isSimplePat pat'
        HS.PList _ pats -> all isPVar pats
        _ -> False
  where
    isPVar HS.PVar{} = True
    isPVar _ = False

convertAltPat :: Variable -> Maybe Expr -> HS.Pat Origin -> Expr -> M Expr
convertAltPat scrut failBranch pat successBranch =
    case pat of
        HS.PApp _ name pats -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            alt <- Alt <$> (ConPat <$> resolveQName name <*> pure args)
                <*> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PInfixApp src a con b -> convertAltPat scrut failBranch (HS.PApp src con [a,b]) successBranch
        HS.PTuple _ HS.Unboxed pats -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            alt <- Alt (UnboxedPat args)
                <$> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PWildCard _ ->
            return successBranch
        HS.PVar _ var -> do
            var' <- Variable <$> bindName var <*> lookupType var
            -- XXX: Very hacky. We cannot compare on types yet.
            if varName var' == varName scrut
              then return successBranch
              else return $ Let (NonRec var' (Var scrut)) successBranch
        -- 0 -> ...
        -- I# i -> case i of
        --            0# -> ...
        HS.PLit _ _sign (HS.Int _ int _) -> do
            intVar <- Variable <$> newName "i" <*> pure i32
            intVar64 <- Variable <$> newName "i64" <*> pure i64
            let alt = Alt (ConPat intCon [intVar]) $
                      Case (Var i32toi64 `App` Var intVar) intVar64 failBranch
                      [Alt (LitPat (LitInt int)) successBranch]
            return $ Case (Var scrut) scrut Nothing [alt]
        HS.PLit _ _sign lit -> do
            alt <- Alt (LitPat $ convertLiteral lit)
                <$> pure successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        HS.PParen _ pat' ->
            convertAltPat scrut failBranch pat' successBranch
        HS.PList _ [] -> do
            let alt = Alt (ConPat nilCon []) successBranch
            return $ Case (Var scrut) scrut failBranch [alt]
        _ -> error $ "Compiler.HaskellToCore.convertAltPat: " ++ show pat

convertAlt :: HS.Alt Origin -> M Alt
convertAlt alt =
    case alt of
        HS.Alt _ (HS.PApp _ name pats) rhs Nothing -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            Alt <$> (ConPat <$> resolveQName name <*> pure args)
                <*> convertRhs rhs
        HS.Alt _ (HS.PTuple _ HS.Unboxed pats) rhs Nothing -> do
            args <- sequence [ Variable <$> bindName var <*> lookupType var
                             | HS.PVar _ var <- pats ]
            Alt (UnboxedPat args)
                <$> convertRhs rhs
        HS.Alt _ (HS.PLit _ _sign lit) rhs Nothing ->
            Alt (LitPat $ convertLiteral lit)
                <$> convertRhs rhs
        -- HS.Alt _ (HS.PVar _ var) rhs Nothing ->
        --     Alt <$> (VarPat <$> (Variable <$> bindName var <*> lookupType var))
        --         <*> convertRhs rhs
        _ -> error $ "convertAlt: " ++ show alt


convertLiteral :: HS.Literal Origin -> Literal
convertLiteral lit =
    case lit of
        HS.PrimString _ str _ -> LitString str
        HS.PrimInt _ int _    -> LitInt int
        HS.PrimChar _ char _  -> LitChar char
        _ -> error $ "convertLiteral: " ++ show lit

toGlobalName :: HS.QName Origin -> GlobalName
toGlobalName qname =
    case info of
        Resolved gname -> gname
        _ -> error $ "toGlobalName: " ++ show qname
  where
    Origin info _ = HS.ann qname

exprType :: Expr -> M TcType
exprType expr =
    case expr of
        Var v -> return (varType v)
        App a b -> do
            aType <- exprType a
            case aType of
                TcFun _ ret -> return ret
                TcForall _ (_ :=> TcFun _ ret) -> return ret
                _ -> return TcUndefined
        WithCoercion _ e -> exprType e
        Let _ e -> exprType e
        LetStrict _ _ e -> exprType e
        Case _ _ (Just e) _ -> exprType e
        Case _ _ Nothing (Alt _ e:_) -> exprType e
        _ -> return TcUndefined









-- LHC.Prim builtins

i32 = TcCon $ mkBuiltIn "LHC.Prim" "I32"
i64 = TcCon $ mkBuiltIn "LHC.Prim" "I64"
realWorld = TcCon $ mkBuiltIn "LHC.Prim" "RealWorld#"
io = TcCon $ mkBuiltIn "LHC.Prim" "IO"
int32 = TcCon $ mkBuiltIn "LHC.Prim" "Int32"
charTy = TcCon $ mkBuiltIn "LHC.Prim" "Char"
intTy = TcCon $ mkBuiltIn "LHC.Prim" "Int"

-- data Int = I# I32
intCon = Variable (Name ["LHC.Prim"] "I#" 0)
  (i32 `TcFun` intTy)

-- data Char = C# I32
charCon = Variable (Name ["LHC.Prim"] "C#" 0)
  (i32 `TcFun` charTy)

-- data List a = Nil | Cons a (List a)
nilCon = Variable (Name ["LHC.Prim"] "Nil" 0)
    (TcForall [a] ([] :=> TcList (TcRef a)))
  where
    a = TcVar "a" noSrcSpanInfo

-- data List a = Nil | Cons a (List a)
consCon = Variable (Name ["LHC.Prim"] "Cons" 0)
    (TcForall [a] ([] :=> (TcRef a `TcFun` TcList (TcRef a) `TcFun` TcList (TcRef a))))
  where
    a = TcVar "a" noSrcSpanInfo

-- data Unit = Unit
unitCon = Variable (Name ["LHC.Prim"] "Unit" 0)
  (TcTuple [])

-- newtype IO a = IO (RealWorld# -> (# RealWorld#, a #))
ioCon :: Variable
ioCon = Variable (Name ["LHC.Prim"] "IO" 0)
    $ TcForall [a] ([] :=> ((realWorld `TcFun` TcUnboxedTuple [realWorld, TcRef a]) `TcFun` TcApp io (TcRef a)))
  where
    a = TcVar "a" noSrcSpanInfo
  -- (RealWorld# -> (# RealWorld#, retType #)) -> IO retType

-- data Int32 = Int32 I32
int32Con = Variable (Name ["LHC.Prim"] "Int32" 0)
  (i32 `TcFun` int32)

i32toi64 = Variable (Name ["LHC.Prim"] "i32toi64" 0) (TcFun i32 i64)
i64toi32 = Variable (Name ["LHC.Prim"] "i64toi32" 0) (TcFun i64 i32)
