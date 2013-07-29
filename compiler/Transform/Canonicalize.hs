module Transform.Canonicalize (interface, metadataModule) where

import Control.Arrow (first, second, (***))
import Control.Monad.Identity
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as List
import qualified Data.Either as Either
import SourceSyntax.Module
import SourceSyntax.Expression
import SourceSyntax.Location as Loc
import SourceSyntax.Pattern
import SourceSyntax.Helpers (isOp)
import qualified SourceSyntax.Type as Type
import qualified Transform.SortDefinitions as SD
import Text.PrettyPrint

-- todo: remove these
import System.IO.Unsafe
import SourceSyntax.PrettyPrint

interface :: String -> ModuleInterface -> ModuleInterface
interface moduleName iface =
    let f x = unsafePerformIO $ do
                putStrLn "----------------------\ncanonicalize interface"
                putStr "iface  " >> print iface
                putStr "canons " >> print canons
                putStr "iface' " >> print x
                return x
    in  f $
    ModuleInterface {
      iTypes = Map.mapKeys prefix (Map.map renameType' (iTypes iface)),
      iAdts = map (both prefix renameCtors) (iAdts iface),
      iAliases = map (both prefix renameType') (iAliases iface)
    }
  where
    both f g (a,b,c) = (f a, b, g c)
    prefix name = moduleName ++ "." ++ name

    pair name = (name, moduleName ++ "." ++ name)
    canon (name,_,_) = pair name
    canons = Map.fromList $ concat
             [ map canon (iAdts iface), map canon (iAliases iface) ]

    renameCtors ctors =
        map (prefix *** map renameType') ctors
    renameType' =
        runIdentity . renameType (\name -> return $ Map.findWithDefault name name canons)

renameType :: (Monad m) => (String -> m String) -> Type.Type -> m Type.Type
renameType rename tipe =
    let rnm = renameType rename in
    case tipe of
      Type.Lambda a b -> Type.Lambda `liftM` rnm a `ap` rnm b
      Type.Var x -> return tipe
      Type.Data name ts -> Type.Data `liftM` rename name `ap` mapM rnm ts
      Type.EmptyRecord -> return tipe
      Type.Record fields ext -> Type.Record `liftM` mapM rnm' fields `ap` rnm ext
          where rnm' (f,t) = (,) f `liftM` rnm t

metadataModule :: Interfaces -> MetadataModule t v -> Either [Doc] (MetadataModule t v)
metadataModule ifaces modul =
  do let f x = unsafePerformIO $ do
                 print realImports
                 print ifaces
                 putStr "initialEnv " >> print initialEnv
                 return x
     program' <- f $ rename initialEnv (program modul)
     return $ modul { program = program' }
  where
    get1 (a,_,_) = a
    canon (name, importMethod) =
        let pair pre var = (pre ++ drop (length name + 1) var, var)
            iface = ifaces Map.! name
            allNames = concat [ Map.keys (iTypes iface)
                              , map get1 (iAliases iface)
                              , concat [ n : map fst ctors | (n,_,ctors) <- iAdts iface ] ]
        in  case importMethod of
              As alias -> map (pair (alias ++ ".")) allNames
              Hiding vars -> map (pair "") $ filter (flip Set.notMember vs) allNames
                  where vs = Set.fromList vars
              Importing vars -> f $ map (pair "") $ filter (flip Set.member vs) allNames
                  where vs = Set.fromList $ map (\v -> name ++ "." ++ v) vars
                        f y = unsafePerformIO $ do
                                print vs
                                print allNames
                                print y
                                return y

    pair n = (n,n)
    localEnv = concat [ map (pair . get1) (aliases modul)
                      , map (pair . get1) (datatypes modul) ]
    globalEnv = map pair $ [ saveEnvName, "::", "[]" ] ++ map (\n -> "_Tuple" ++ show n) [0..9]
    realImports = filter (not . List.isPrefixOf "Native." . fst) (imports modul)
    initialEnv = Map.fromList (concatMap canon realImports ++ localEnv ++ globalEnv)


type Env = Map.Map String String

extend :: Env -> Pattern -> Env
extend env pattern = Map.union (Map.fromList (zip xs xs)) env
    where xs = Set.toList (SD.boundVars pattern)


replace :: Env -> String -> Either String String
replace env v =
    if List.isPrefixOf "Native." v then return v else
    case Map.lookup v env of
      Just v' -> return v'
      Nothing -> Left $ "Could not find variable '" ++ v ++ "'." ++ msg
          where
            matches = filter (List.isInfixOf v) (Map.keys env)
            msg = if null matches then "" else
                      "\nClose matches include: " ++ List.intercalate ", " matches

rename :: Env -> LExpr t v -> Either [Doc] (LExpr t v)
rename env lexpr@(L t s expr) =
    let rnm = rename env
        throw err = Left [ text $ "Error " ++ show s ++ "\n" ++ err ]
        format = Either.either throw return
    in
    L t s `liftM`
    case expr of
      Literal lit -> return expr

      Range e1 e2 -> Range `liftM` rnm e1 `ap` rnm e2

      Access e x -> Access `liftM` rnm e `ap` return x

      Remove e x -> flip Remove x `liftM` rnm e

      Insert e x v -> flip Insert x `liftM` rnm e `ap` rnm v

      Modify e fs ->
          Modify `liftM` rnm e `ap` mapM (\(x,e) -> (,) x `liftM` rnm e) fs

      Record fs -> Record `liftM` mapM frnm fs
          where
            frnm (f,e) = (,) f `liftM` rename env e

      Binop op e1 e2 ->
          do op' <- if isOp op then return op else format (replace env op)
             Binop op' `liftM` rnm e1 `ap` rnm e2

      Lambda pattern e ->
          let env' = extend env pattern in
          Lambda pattern `liftM` rename env' e

      App e1 e2 -> App `liftM` rnm e1 `ap` rnm e2

      MultiIf ps -> MultiIf `liftM` mapM grnm ps
              where grnm (b,e) = (,) `liftM` rnm b `ap` rnm e

      Let defs e -> Let `liftM` mapM rename' defs `ap` rename env' e
          where
            env' = foldl extend env [ pattern | Def pattern _ <- defs ]
            rename' def =
                case def of
                  Def p exp ->
                      Def `liftM` format (renamePattern env' p) `ap` rename env' exp
                  TypeAnnotation name tipe ->
                      TypeAnnotation name `liftM` renameType (format . replace env') tipe

      Var x -> Var `liftM` format (replace env x)

      Data name es -> Data name `liftM` mapM rnm es

      ExplicitList es -> ExplicitList `liftM` mapM rnm es

      Case e cases -> Case `liftM` rnm e `ap` mapM branch cases
          where
            branch (pattern,e) = (,) `liftM` format (renamePattern env pattern)
                                        `ap` rename (extend env pattern) e

      Markdown _ -> return expr


renamePattern :: Env -> Pattern -> Either String Pattern
renamePattern env pattern =
    case pattern of
      PVar _ -> return pattern
      PLiteral _ -> return pattern
      PRecord _ -> return pattern
      PAnything -> return pattern
      PAlias x p -> PAlias x `liftM` renamePattern env p
      PData name ps -> PData `liftM` replace env name
                                `ap` mapM (renamePattern env) ps
