-- Lowering.hs .. lowers AST to IR

module IR.Lowering (passLower) where

import Common.Pass
import Common.Common
import Pass.Namer
import Pass.NameTyper
import AST.AST
import IR.Syntax

import Control.Monad.State

data Context = Context {
    nameTbl :: [(TypedName, IR.Syntax.Name)],
    typeTbl :: [(IR.Syntax.Name, IR.Syntax.Type)], 
    nextName :: Int
}

passLower = Pass {pName = ["AST to IR lowering"], pFunc = runP }
    where runP ast = let r = lower ast in (messageNoLn "AST to IR lowering" (disp r) Debug, Just r)
          
lower :: AST TypedName -> IR
lower (AST defs) = let (a, b) = evalState (lowerAll defs) (Context {nameTbl = [], typeTbl = [], nextName = 0}) in IR a b
    where 
        lowerAll :: [Definition TypedName] -> State Context ([TLFunction], [(IR.Syntax.Name, IR.Syntax.Type)])
        lowerAll defs = do
            regN defs
            res <- lowerC defs
            ctx <- get
            return (res, typeTbl ctx)
        -- needs to be done first to avoid forward declaration problems
        regN (d:ds) = do
            name <- registerName (identifier d)
            regN ds
            return ()
        regN [] = do
            return ()
            
        lowerC :: [Definition TypedName] -> State Context [TLFunction]
        lowerC (d:ds) = do
            name <- registerEName (identifier d)
            newval <- lexp (value d)
            let result = case newval of
                            Abs params expr -> (TLFunction name [] params expr)
                            _ -> error "invariant bad"
            rest <- lowerC ds
            return $ result:rest
        lowerC [] = do
            return []
        
        
getTypeFunc2 = do
    ctx <- get
    let tbl = typeTbl ctx
    let namefunc name = snd $ (filter (\(n, t) -> n == name) tbl) !! 0
    return namefunc
    
convTy (AST.AST.Array ty) = IR.Syntax.Array (convTy ty)
convTy (AST.AST.Bits i) = IR.Syntax.Bits i
convTy (AST.AST.Function ty1 ty2) = IR.Syntax.Function [convTy ty1] (convTy ty2)
convTy (AST.AST.Tuple tys) = IR.Syntax.Tuple (map convTy tys)
    
-- register "new" name
registerName :: Pass.NameTyper.TypedName -> State Context IR.Syntax.Name
registerName tn@(TypedName ty (Pass.Namer.Name s i)) = do
    ctx <- get
    let nm = nextName ctx
    put $ Context { nameTbl = (tn, IR.Syntax.Name nm):(nameTbl ctx), typeTbl = (IR.Syntax.Name nm, (convTy ty)):(typeTbl ctx), nextName = nm+1}
    return (IR.Syntax.Name nm)

-- register "existing" name
registerEName :: Pass.NameTyper.TypedName -> State Context IR.Syntax.Name
registerEName tn = do
    ctx <- get
    return $ findin tn (nameTbl ctx)
    where findin tn ((t, n):r) = if tn == t then n else (findin tn r)
          findin tn [] = error "registerEName non-existing name"

-- create new name, but not associated w/ an ast variable
newName :: AST.AST.Type -> State Context IR.Syntax.Name
newName typ = do
    ctx <- get
    let nm = nextName ctx
    put $ ctx { typeTbl = (IR.Syntax.Name nm, (convTy typ)):(typeTbl ctx),  nextName = nm + 1 }
    return (IR.Syntax.Name nm)

lexp (Literal l) = do
    nexp <- llit l
    return nexp

lexp (Block ((Defn d):bs)) = do
    newname <- registerName (identifier d)
    newexpr <- lexp (value d)
    nb <- lexp (Block bs)
    return $ Let newname newexpr nb
    
lexp (Block ((Yield y):bs)) = do
    ny <- lexp y
    return ny

lexp (Block ((Return r):bs)) = do
    nr <- lexp r
    return $ Ret nr

lexp (Block ((Assignment a e):bs)) = do
    na <- registerEName a
    ne <- lexp e
    nbs <- lexp (Block bs)
    return $ Seq (Assign na ne) nbs
    
lexp (Block ((Expr b):bs)) = do
    nb <- lexp b
    nbs <- lexp (Block bs)
    return $ Seq nb nbs

lexp (Block []) = error "Block must terminate in yield or return"

lexp (FunctionCall e1 e2) = do
    ne1 <- lexp e1
    ne2 <- lexp e2
    return $ App ne1 [ne2]

lexp (Variable a) = do
    na <- registerEName a
    return $ Var na
                 
llit (Constant nt) = do
    return (Lit (IntL nt))

llit (TupleLiteral ea) = do
    nm <- mapM lexp ea
    nf <- getTypeFunc2
    return $ App (Prim (MkTuple (map (\x -> exprType x nf) nm))) nm

llit (ArrayLiteral ea) = do
    nm <- mapM lexp ea
    nf <- getTypeFunc2
    return $ App (Prim (MkArray (map (\x -> exprType x nf) nm))) nm

{--
N.B. (FunctionLiteral lowering): 
here we introduce a new name for the param, and let the old param be assigned to the new one here.
why? this simplifies some processes. for example in heap conversion, we don't have to worry about parameters being captured,
since the new variable will be promoted to heap instead, and the function signature will not change.
this also simplifies llvm codegen.
clang also does this. 
-}
    
llit (FunctionLiteral a@(TypedName ty _) ex) = do
    newname <- registerName a
    nex <- lexp ex
    newparam <- newName ty
    return $ Abs [newparam] (Let newname (Var newparam) nex)
