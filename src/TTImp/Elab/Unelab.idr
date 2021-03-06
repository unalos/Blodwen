module TTImp.Elab.Unelab

import TTImp.TTImp
import Core.CaseTree
import Core.Context
import Core.Normalise
import Core.TT

import Data.List

%default covering

used : Elem x vars -> Term vars -> Bool
used el (Local _ v) = sameVar el v
used {vars} el (Bind x b sc) = usedBinder b || used (There el) sc
  where
    usedBinder : Binder (Term vars) -> Bool
    usedBinder (Let _ val ty) = used el val || used el ty
    usedBinder (PLet _ val ty) = used el val || used el ty
    usedBinder b = used el (binderType b)
used el (App f a) = used el f || used el a
used el _ = False

data IArg annot
   = Exp annot (RawImp annot)
   | Imp annot (Maybe Name) (RawImp annot)

mutual
  unelabCase : {auto c : Ref Ctxt Defs} ->
               Name -> List (IArg annot) -> RawImp annot ->
               Core annot (RawImp annot)
  unelabCase n args orig
      = do defs <- get Ctxt
           let Just glob = lookupGlobalExact n (gamma defs)
                | Nothing => pure orig
           let PMDef _ pargs _ _ pats = definition glob
                | _ => pure orig
           if length args == length pargs
              then mkCase pats (reverse args)
              else pure orig
    where
      lastArg : Env Term vars -> Term vars ->
                (vars' ** (Env Term vars', Term vars'))
      lastArg env (App f a) = (_ ** (env, a))
      lastArg env (Bind x b sc) = lastArg (b :: env) sc
      lastArg env tm = (_ ** (env, Erased))

      dropEnv : List Name -> Env Term vars -> Term vars ->
                (vars' ** (Env Term vars', Term vars'))
      dropEnv (n :: ns) env (Bind x b sc) = dropEnv ns (b :: env) sc
      dropEnv ns env tm = (_ ** (env, tm))

      mkClause : annot -> (List Name, ClosedTerm, ClosedTerm) ->
                 Core annot (ImpClause annot)
      mkClause loc (vs, lhs, rhs)
          = do let (_ ** (env, pat)) = lastArg [] lhs
               lhs' <- unelabTy True loc env pat
               let (_ ** (env, rhs)) = dropEnv vs [] rhs
               rhs' <- unelabTy True loc env rhs
               pure (PatClause loc (fst lhs') (fst rhs'))

      mkCase : List (List Name, ClosedTerm, ClosedTerm) ->
               List (IArg annot) -> Core annot (RawImp annot)
      mkCase pats (Exp loc tm :: _)
          = do pats' <- traverse (mkClause loc) pats
               pure $ ICase loc tm (Implicit loc) pats'
      mkCase _ _ = pure orig

  getFnArgs : RawImp annot -> List (IArg annot) -> 
              (RawImp annot, List (IArg annot))
  getFnArgs (IApp loc f arg) args = getFnArgs f (Exp loc arg :: args)
  getFnArgs (IImplicitApp loc f n arg) args = getFnArgs f (Imp loc n arg :: args)
  getFnArgs tm args = (tm, args)

  unelabSugar : {auto c : Ref Ctxt Defs} ->
                (sugar : Bool) ->
                (RawImp annot, Term vars) ->
                Core annot (RawImp annot, Term vars)
  unelabSugar False res = pure res
  unelabSugar True (tm, ty) 
      = let (f, args) = getFnArgs tm [] in
            case f of
             IVar loc (GN (CaseBlock n i))
                 => pure (!(unelabCase (GN (CaseBlock n i)) args tm), ty)
             _ => pure (tm, ty)

  -- Turn a term back into an unannotated TTImp. Returns the type of the
  -- unelaborated term so that we can work out where to put the implicit 
  -- applications
  unelabTy : {auto c : Ref Ctxt Defs} ->
             (sugar : Bool) ->
             annot -> Env Term vars -> Term vars -> 
             Core annot (RawImp annot, Term vars)
  unelabTy sugar loc env tm 
      = unelabSugar sugar !(unelabTy' sugar loc env tm)

  unelabTy' : {auto c : Ref Ctxt Defs} ->
              (sugar : Bool) ->
              annot -> Env Term vars -> Term vars -> 
              Core annot (RawImp annot, Term vars)
  unelabTy' sugar loc env (Local {x} _ el) 
      = pure (IVar loc x, binderType (getBinder el env))
  unelabTy' sugar loc env (Ref nt n)
      = do defs <- get Ctxt
           case lookupDefTyExact n (gamma defs) of
                Nothing => pure (IHole loc (nameRoot n),
                                 Erased) -- should never happen on a well typed term!
                                    -- may happen in error messages where we haven't saved
                                    -- holes in the context
                Just (Hole _ False _, ty) => pure (IHole loc (nameRoot n), embed ty)
                Just (_, ty) => pure (IVar loc n, embed ty)
  unelabTy' sugar loc env (Bind x b sc)
      = do (sc', scty) <- unelabTy sugar loc (b :: env) sc
           unelabBinder sugar loc env x b sc sc' scty
  unelabTy' sugar loc env (App fn arg)
      = do (fn', fnty) <- unelabTy sugar loc env fn
           case fn' of
               IHole _ _ => pure (fn', Erased)
               _ => do (arg', argty) <- unelabTy sugar loc env arg
                       defs <- get Ctxt
                       case nf defs env fnty of
                            NBind x (Pi rig Explicit ty) sc
                              => pure (IApp loc fn' arg', 
                                       quote defs env (sc (toClosure defaultOpts env arg)))
                            NBind x (Pi rig p ty) sc
                              => pure (IImplicitApp loc fn' (Just x) arg', 
                                       quote defs env (sc (toClosure defaultOpts env arg)))
                            _ => pure (IApp loc fn' arg', Erased)
  unelabTy' sugar loc env (PrimVal c) = pure (IPrimVal loc c, Erased)
  unelabTy' sugar loc env Erased = pure (Implicit loc, Erased)
  unelabTy' sugar loc env TType = pure (IType loc, TType)
  unelabTy' sugar loc _ _ = pure (Implicit loc, Erased)

  unelabBinder : {auto c : Ref Ctxt Defs} ->
                 (sugar : Bool) ->
                 annot -> Env Term vars -> (x : Name) ->
                 Binder (Term vars) -> Term (x :: vars) ->
                 RawImp annot -> Term (x :: vars) -> 
                 Core annot (RawImp annot, Term vars)
  unelabBinder sugar loc env x (Lam rig p ty) sctm sc scty
      = do (ty', _) <- unelabTy sugar loc env ty
           pure (ILam loc rig p (Just x) ty' sc, Bind x (Pi rig p ty) scty)
  unelabBinder sugar loc env x (Let rig val ty) sctm sc scty
      = do (val', vty) <- unelabTy sugar loc env val
           (ty', _) <- unelabTy sugar loc env ty
           pure (ILet loc rig x ty' val' sc, Bind x (Let rig val ty) scty)
  unelabBinder sugar loc env x (Pi rig p ty) sctm sc scty 
      = do (ty', _) <- unelabTy sugar loc env ty
           let nm = if used Here sctm || rig /= RigW
                       then Just x else Nothing
           pure (IPi loc rig p nm ty' sc, TType)
  unelabBinder sugar loc env x (PVar rig ty) sctm sc scty
      = do (ty', _) <- unelabTy sugar loc env ty
           pure (sc, Bind x (PVTy rig ty) scty)
  unelabBinder sugar loc env x (PLet rig val ty) sctm sc scty
      = do (val', vty) <- unelabTy sugar loc env val
           (ty', _) <- unelabTy sugar loc env ty
           pure (ILet loc rig x ty' val' sc, Bind x (PLet rig val ty) scty)
  unelabBinder sugar loc env x (PVTy rig ty) sctm sc scty
      = do (ty', _) <- unelabTy sugar loc env ty
           pure (sc, TType)

export
unelabNoSugar : {auto c : Ref Ctxt Defs} ->
         annot -> Env Term vars -> Term vars -> Core annot (RawImp annot)
unelabNoSugar loc env tm
    = do tm' <- unelabTy False loc env tm
         pure $ fst tm'

export
unelab : {auto c : Ref Ctxt Defs} ->
         annot -> Env Term vars -> Term vars -> Core annot (RawImp annot)
unelab loc env tm
    = do tm' <- unelabTy True loc env tm
         pure $ fst tm'
