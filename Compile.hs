module Compile where
import Data.List
import qualified Data.Map as Map
import Exprs
import FGG
import Util
import RuleM
import Ctxt
import Free
import Name
import Show

-- Local var rule
var2fgg :: Var -> Type -> RuleM
var2fgg x tp =
  let fac = typeFactorName tp in
  addRule' (TmVarL x tp) [tp, tp] [Edge [0, 1] fac] [0, 1]

-- Bind a list of external nodes, and add rules for them
bindExts :: Bool -> [(Var, Type)] -> RuleM -> RuleM
bindExts addVarRules xs' (RuleM rs xs nts fs) =
  let keep = not . flip elem (map fst xs') . fst
      rm = RuleM rs (filter keep xs) nts fs in
    if addVarRules
      then foldr (\ (x, tp) r -> var2fgg x tp +> r) rm xs'
      else rm

-- Bind an external node, and add a rule for it
bindExt :: Bool -> Var -> Type -> RuleM -> RuleM
bindExt addVarRule x tp = bindExts addVarRule [(x, tp)]

-- Only takes the external nodes from one of the cases,
-- because they should all have the same externals and
-- we don't want to include them more than once.
bindCases :: [RuleM] -> RuleM
bindCases =
  foldr (\ rm rm' -> rm +> resetExts rm') returnRule


-- Add rule for a term application
tmapp2fgg :: Ctxt -> Term -> RuleM
tmapp2fgg g (TmApp tm1 tm2 tp2 tp) =
  term2fgg g tm1 +>= \ xs1 ->
  term2fgg g tm2 +>= \ xs2 ->
  let fac = pairFactorName tp2 tp
      (ns, [[itp2, itp, iarr], ixs1, ixs2]) =
        -- For " 0" et al, pick impossible var names
        combineExts [[(" 0", tp2), (" 1", tp), (" 2", TpArr tp2 tp)], xs1, xs2]
      es = [Edge (ixs2 ++ [itp2]) (show tm2),
            Edge (ixs1 ++ [iarr]) (show tm1),
            Edge [itp2, itp, iarr] fac]
      xs = nub (ixs1 ++ ixs2 ++ [itp]) in
    addRule' (TmApp tm1 tm2 tp2 tp) (map snd ns) es xs +>
    addFactor fac (getPairWeights tp2 tp)

-- Add rule for a constructor
ctorRules :: Ctxt -> Ctor -> Type -> [Ctor] -> RuleM
ctorRules g (Ctor x as) y cs =
  let ix = foldr (\ (Ctor x' _) next ix -> if x == x' then ix else next (ix + 1)) id cs 0
      as' = map (etaName x) [0..length as - 1]
      (ns, [ias, [iy]]) = combine [as, [y]]
      ias' = zip ias as'
      fac = ctorFactorName x (toTermArgs (zip as' as)) y
      es = [Edge (ias ++ [iy]) fac]
      xs = ias ++ [iy]
      tm = TmVarG CtorVar x (map (\ (a, atp) -> (TmVarL a atp, atp)) (zip as' as)) y in
    addRule' tm ns es xs +>
    addFactor (ctorFactorNameDefault x as y)
      (getCtorWeightsFlat (domainValues g) (Ctor x as) cs)

ctorsRules :: Ctxt -> [Ctor] -> Type -> RuleM
ctorsRules g cs y =
  foldr (\ (fac, ws) rm -> addFactor fac ws +> rm) returnRule
    (getCtorWeightsAll (domainValues g) cs y) +>
  foldr (\ (Ctor x as) r -> r +> ctorRules g (Ctor x as) y cs) returnRule cs +>
  addFactor (typeFactorName y) (getCtorEqWeights (domainSize g y))

-- Add a rule for this particular case in a case-of statement
caseRule :: Ctxt -> [(Var, Type)] -> Term -> Case -> RuleM
caseRule g xs_ctm (TmCase ctm y cs tp) (Case x as xtm) =
  --(\ _ -> error (show (Case x as xtm) ++ ", " ++ show tp)) $
  let g' = ctxtDeclArgs g as in
  --bindExts True as (term2fgg g' xtm) +>= \ xs_xtm ->
  bindExts True as $
  term2fgg g' xtm +>= \ xs_xtm_as ->
  let fac = ctorFactorName x (toTermArgs (getArgs x (map snd as))) y
      (ns, [[ictm, ixtm], ixs_xtm_as, ixs_ctm]) =
        combineExts [[(" 0", y), (" 1", tp)], xs_xtm_as, xs_ctm]
      (ixs_xtm, ixs_as) = foldr (\ (a, i) (ixs_xtm, ixs_as) -> if elem (fst a) (map fst as) then (ixs_xtm, i : ixs_as) else (i : ixs_xtm, ixs_as)) ([], []) (zip xs_xtm_as ixs_xtm_as)
      es = [Edge (ixs_ctm ++ [ictm]) (show ctm),
            Edge (ixs_xtm_as ++ [ixtm]) (show xtm),
            Edge (ixs_as ++ [ictm]) fac]
      xs = nub (ixs_ctm ++ ixs_xtm ++ [ixtm]) in
    addRule' (TmCase ctm y cs tp) (map snd ns) es xs
caseRule g xs _ (Case x as xtm) =
  error "caseRule expected a TmCase, but got something else"

-- Add a rule for a lambda term
lamRule :: Bool -> Var -> Type -> Term -> Type -> RuleM -> RuleM
lamRule addVarRule x tp tm tp' rm =
  bindExt addVarRule x tp rm +>= \ xs' ->
  let (ns, [[itp, itp', iarr], ixs']) = combine [[tp, tp', TpArr tp tp'], map snd xs']
      es = [Edge (ixs' ++ [itp, itp']) (show tm),
            Edge [itp, itp', iarr] (pairFactorName tp tp')]
      xs = ixs' ++ [iarr] in
    addRule' (TmLam x tp tm tp') ns es xs +>
    addFactor (pairFactorName tp tp') (getPairWeights tp tp')

-- Traverse a term and add all rules for subexpressions
term2fgg :: Ctxt -> Term -> RuleM
term2fgg g (TmVarL x tp) =
  addFactor (typeFactorName tp) (getCtorEqWeights (domainSize g tp)) +>
  addExt x tp
term2fgg g (TmFold fuf tm tp) = term2fgg g tm -- TODO: this should cause error
term2fgg g (TmVarG DefVar x as tp) =
  map (\ (a, atp) -> term2fgg g a) as +*>= \ xss ->
  let (ns, [itp] : ias : ixss) = combineExts ([(" 0", tp)] : map (\ (i, (tm, tp)) -> (' ' : show (succ i), tp)) (enumerate as) : xss)
      es = Edge (ias ++ [itp]) x : map (\ ((atm, atp), ia, ixs) -> Edge (ixs ++ [ia]) (show atm)) (zip3 as ias ixss)
      xs = nub (concat ixss) ++ [itp]
  in
    addRule' (TmVarG DefVar x as tp) (map snd ns) es xs
term2fgg g (TmVarG CtorVar x as y) =
  map (\ (a, atp) -> term2fgg g a) as +*>= \ xss ->
  let (ns, [iy] : ias : ixss) = combineExts ([(" 0", y)] : map (\ (i, (tm, tp)) -> (' ' : show (succ i), tp)) (enumerate as) : xss)
      es = Edge (ias ++ [iy]) (ctorFactorNameDefault x (map snd as) y) :
           map (\ (ixs, (a, _), itp) -> Edge (ixs ++ [itp]) (show a)) (zip3 ixss as ias)
      xs = nub (concat ixss) ++ [iy]
      Just cs = ctxtLookupType' g y
      cix = foldr (\ (Ctor x' _) next ix -> if x == x' then ix else next (ix + 1)) id cs 0 in
  addRule' (TmVarG CtorVar x as y) (map snd ns) es xs
term2fgg g (TmLam x tp tm tp') =
  lamRule True x tp tm tp' (term2fgg (ctxtDeclTerm g x tp) tm)
term2fgg g (TmApp tm1 tm2 tp2 tp) =
  tmapp2fgg g (TmApp tm1 tm2 tp2 tp)
term2fgg g (TmCase tm y cs tp) =
  term2fgg g tm +>= \ xs ->
  bindCases (map (caseRule g xs (TmCase tm y cs tp)) cs)
term2fgg g (TmSamp d tp) =
  let dvs = domainValues g tp
      dvws = vectorWeight dvs in
  case d of
    DistFail ->
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const 0) dvws))
    DistUni  ->
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const (1.0 / fromIntegral (length dvs))) dvws))
      -- +> addRule' (TmSamp d tp) [tp] [] [0]
    DistAmb  -> -- TODO: is this fine, or do we need to add a rule with one node and one edge (that has the factor below)?
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const 1) dvws))
      -- +> addRule' (TmSamp d tp) [tp] [] [0]
term2fgg g (TmLet x xtm xtp tm tp) =
  term2fgg g xtm +>= \ xtmxs ->
  bindExt True x xtp (term2fgg (ctxtDeclTerm g x xtp) tm) +>= \ tmxs ->
  let (ns, [[ixtp, itp], ixxs, ixs]) = combineExts [[(" 0", xtp), (" 1", tp)], xtmxs, tmxs]
      es = [Edge (ixxs ++ [ixtp]) (show xtm), Edge (ixs ++ [ixtp, itp]) (show tm)]
      xs = nub (ixxs ++ ixs) ++ [itp]
  in
    addRule' (TmLet x xtm xtp tm tp) (map snd ns) es xs

-- Adds the rules for a Prog
prog2fgg :: Ctxt -> Prog -> RuleM
prog2fgg g (ProgFun x ps tm tp) =
  -- TODO: args
  term2fgg g tm +> addRule' (TmVarG DefVar x [] tp) [tp] [Edge [0] (show tm)] [0]
prog2fgg g (ProgExtern x xp ps tp) =
  -- TODO: args
  let ws = ThisWeight (fmap (const 0) (vectorWeight (domainValues g tp))) in
  addRule' (TmVarG DefVar x [] tp) [tp] [Edge [0] xp] [0] +>
  addFactor xp ws
prog2fgg g (ProgData y cs) =
  ctorsRules g cs (TpVar y)

-- Goes through a program and adds all the rules for it
progs2fgg :: Ctxt -> Progs -> RuleM
progs2fgg g (Progs ps tm) = foldr (\ p rm -> rm +> prog2fgg g p) (term2fgg g tm) ps

-- Computes a list of all the possible inhabitants of a type
domainValues :: Ctxt -> Type -> [String]
domainValues g = tpVals where
  arrVals :: [Type] -> Type -> [String]
  arrVals tps tp =
    map (parensIf (not $ null tps)) $
      foldl (\ ds tp -> kronwith (\ da d -> d ++ " -> " ++ da) ds (domainValues g tp))
        (tpVals tp) tps
  
  tpVals :: Type -> [String]
  tpVals (TpVar y) =
    maybe2 (ctxtLookupType g y) [] $ \ cs ->
      concat $ flip map cs $ \ (Ctor x as) ->
        foldl (kronwith $ \ d da -> d ++ " " ++ parens da)
          [x] (map tpVals as)
  tpVals (TpArr tp1 tp2) = uncurry arrVals (splitArrows (TpArr tp1 tp2))
  tpVals TpBool = [tmFalseName, tmTrueName]
  tpVals (TpMaybe tp) =
    tmNothingName : map (\ tp -> "(" ++ tmJustName ++ " " ++ tp ++ ")") (tpVals tp)

domainSize :: Ctxt -> Type -> Int
domainSize g = length . domainValues g

addMaybeFactors :: Ctxt -> [Type] -> RuleM
addMaybeFactors g (tp : []) = ctorsRules g (maybeCtors tp) (TpMaybe tp)

addBoolFactors :: Ctxt -> [Type] -> RuleM
addBoolFactors g [] = ctorsRules g boolCtors TpBool

data InternalCtor = InternalCtor String (Ctxt -> [Type] -> RuleM) Int {- Num of type args -}
boolInternalCtor = InternalCtor tpBoolName addBoolFactors 0
maybeInternalCtor = InternalCtor tpMaybeName addMaybeFactors 1

addInternalFactors :: Ctxt -> Progs -> RuleM
addInternalFactors g ps =
  let internals = [boolInternalCtor, maybeInternalCtor]
      insts = getPolyInsts ps in
  foldr (\ (InternalCtor name addFs len) rm ->
           let tps = insts name
               msg = ("Expected " ++ show len ++ " type args for "
                        ++ name ++ ", but got " ++ show (length tps)) in
             foldr (\ as rm' -> if len == length as then addFs g as +> rm' else error msg) rm tps) returnRule internals

-- Converts an elaborated program into an FGG
file2fgg :: Progs -> FGG_JSON
file2fgg ps =
  let g = ctxtDefProgs ps
      Progs _ end = ps
      RuleM rs xs nts fs = addInternalFactors g ps +> progs2fgg g ps in
    rulesToFGG (domainValues g) (show end) (reverse rs) nts fs



-- Records an instantiation of a polymorphic type
piAppend :: Var -> [Type] -> Map.Map Var [[Type]] -> Map.Map Var [[Type]]
piAppend y tp pis = Map.insertWith (++) y [tp] pis

-- Retrieves all instantiations of polymorphic types (e.g. Maybe [...]) in a term
getPolyInstsTerm :: Map.Map Var [[Type]] -> Term -> Map.Map Var [[Type]]
getPolyInstsTerm pis (TmVarL x tp) = getPolyInstsType pis tp
getPolyInstsTerm pis (TmVarG gv x as tp) = foldl (\ pis (a, atp) -> getPolyInstsTerm pis a) (getPolyInstsType pis tp) as
getPolyInstsTerm pis (TmLam x tp tm tp') = getPolyInstsTerm (getPolyInstsType pis tp) tm -- no need to do tp' bc tm already adds all insts
getPolyInstsTerm pis (TmApp tm1 tm2 tp2 tp) = getPolyInstsTerm (getPolyInstsTerm pis tm2) tm1
getPolyInstsTerm pis (TmLet x xtm xtp tm tp) = getPolyInstsTerm (getPolyInstsTerm pis xtm) tm
getPolyInstsTerm pis (TmCase tm y cs tp) =
  foldl (\ pis (Case x as ctm) -> getPolyInstsTerm pis ctm)
    (getPolyInstsType (getPolyInstsTerm pis tm) y) cs
getPolyInstsTerm pis (TmSamp d tp) = getPolyInstsType pis tp
getPolyInstsTerm pis (TmFold fuf tm tp) = getPolyInstsTerm pis tm

-- Retrives all instantiations of polymorphic types (e.g. Maybe [...]) in a type
getPolyInstsType :: Map.Map Var [[Type]] -> Type -> Map.Map Var [[Type]]
getPolyInstsType pis (TpVar y) = pis
getPolyInstsType pis (TpArr tp1 tp2) = getPolyInstsType (getPolyInstsType pis tp1) tp2
getPolyInstsType pis TpBool = piAppend tpBoolName [] pis
getPolyInstsType pis (TpMaybe tp) = piAppend tpMaybeName [tp] (getPolyInstsType pis tp)

-- Retrives all instantiations of polymorphic types (e.g. Maybe [...]) in a Prog
getPolyInstsProg :: Map.Map Var [[Type]] -> Prog -> Map.Map Var [[Type]]
getPolyInstsProg pis (ProgFun x ps tm tp) = foldl getPolyInstsType (getPolyInstsTerm pis tm) (map snd ps)
getPolyInstsProg pis (ProgExtern x xp ps tp) = foldl getPolyInstsType (getPolyInstsType pis tp) ps
getPolyInstsProg pis (ProgData y cs) = foldl (\ pis (Ctor x as) -> foldl getPolyInstsType pis as) pis cs

getPolyInstsProgs :: Map.Map Var [[Type]] -> Progs -> Map.Map Var [[Type]]
getPolyInstsProgs pis (Progs ps tm) = Map.unionsWith (++) (getPolyInstsTerm pis tm : map (getPolyInstsProg pis) ps)

-- Retrives all instantiations of a particular polymorphic type var (e.g. Maybe [...])
getPolyInsts :: Progs -> Var -> [[Type]]
getPolyInsts ps y =
  let is = getPolyInstsProgs Map.empty ps in
    maybe [] nub (Map.lookup y is)
