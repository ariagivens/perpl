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
-- TODO: use Map for externals, so we don't really need to keep track of order outside of doing combineExts?

-- If the start term is just a factor (has no rule), then we need to
-- add a rule [%start%]-(v) -> [tm]-(v)
addStartRuleIfNecessary :: Term -> RuleM -> (String, RuleM)
addStartRuleIfNecessary tm rm =
  let stm = show tm
      tp = getType tm in
    if isRule stm rm then (stm, rm) else
      (startName, addRule' (TmVarL startName tp) [tp] [Edge [0] stm] [0] +> rm)

-- Local var rule
var2fgg :: Var -> Type -> RuleM
var2fgg x tp =
  let fac = typeFactorName tp in
  addRule' (TmVarL x tp) [tp, tp] [Edge [0, 1] fac] [0, 1]

-- Bind a list of external nodes, and add rules for them
bindExts :: Bool -> [Param] -> RuleM -> RuleM
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
bindCases :: [External] -> [RuleM] -> RuleM
bindCases xs =
  setExts xs . foldr (\ rm rm' -> rm +> {-resetExts-} rm') returnRule

-- Creates dangling edges that discard a set of nodes
discardEdges :: [Var] -> [Int] -> [Int] -> [Edge]
discardEdges xs i_xs i_ns = map (\ (x, i_x, i_n) -> Edge [i_x, i_n] x) (zip3 xs i_xs i_ns)

newName :: Int -> Var
newName i = " " ++ show i

newNames :: Int -> [a] -> [Var]
newNames i as = map newName [i..length as - 1 + i]

newNames' :: [a] -> [(Var, a)]
newNames' as = zip (newNames 0 as) as

-- Add rule for a term application
tmapp2fgg :: Ctxt -> Term -> RuleM
tmapp2fgg g (TmApp tm1 tm2 tp2 tp) =
  term2fgg g tm1 +>= \ xs1 ->
  term2fgg g tm2 +>= \ xs2 ->
  let fac = pairFactorName tp2 tp
      (ns, [[itp2, itp, iarr], ixs1, ixs2]) =
        combineExts [newNames' [tp2, tp, TpArr tp2 tp], xs1, xs2]
      es = [Edge (ixs2 ++ [itp2]) (show tm2),
            Edge (ixs1 ++ [iarr]) (show tm1),
            Edge [itp2, itp, iarr] fac]
      xs = nub (ixs1 ++ ixs2 ++ [itp]) in
    addRule' (TmApp tm1 tm2 tp2 tp) (map snd ns) es xs +>
    addFactor fac (getPairWeights tp2 tp)

-- Add rule for a constructor
ctorRules :: Ctxt -> Ctor -> Type -> [Ctor] -> RuleM
ctorRules g (Ctor x as) y cs =
  let --ix = foldr (\ (Ctor x' _) next ix -> if x == x' then ix else next (ix + 1)) id cs 0
      as' = map (\ (i, a) -> (etaName x i, a)) (enumerate as)
      (ns, [ias, [iy]]) = combineExts [as', newNames' [y]]
      fac = ctorFactorNameDefault x as y -- ctorFactorName x (paramsToArgs as') y
      es = [Edge (ias ++ [iy]) fac]
      xs = ias ++ [iy]
      tm = TmVarG CtorVar x (map (\ (a, atp) -> (TmVarL a atp, atp)) as') y in
    addRule' tm (map snd ns) es xs +>
    addFactor fac -- (ctorFactorNameDefault x as y)
      (getCtorWeightsFlat (domainValues g) (Ctor x as) cs)

ctorsRules :: Ctxt -> [Ctor] -> Type -> RuleM
ctorsRules g cs y =
  foldr (\ (fac, ws) rm -> addFactor fac ws +> rm) returnRule
    (getCtorWeightsAll (domainValues g) cs y) +>
  foldr (\ (Ctor x as) r -> r +> ctorRules g (Ctor x as) y cs) returnRule cs +>
  addFactor (typeFactorName y) (getCtorEqWeights (domainSize g y))

-- Add a rule for this particular case in a case-of statement
caseRule :: Ctxt -> FreeVars -> [External] -> Term -> Var -> [Case] -> Type -> Case -> RuleM
caseRule g all_fvs xs_ctm ctm y cs tp (Case x as xtm) =
  bindExts True as $
  term2fgg (ctxtDeclArgs g as) xtm +>= \ xs_xtm_as ->
  let all_xs = Map.toList all_fvs
      (d_xs, d_tps) = unzip (Map.toList (Map.difference all_fvs (Map.fromList xs_xtm_as)))
      d_ns = newNames 2 d_xs
      fac = ctorFactorName x (paramsToArgs (nameParams x (map snd as))) (TpVar y)
      (ns, [[ictm, ixtm], ixs_xtm_as, ixs_as, ixs_ctm, all_ixs, d_ixs, d_ins]) =
        combineExts [newNames' [TpVar y, tp], xs_xtm_as, as, xs_ctm, all_xs, zip d_xs d_tps, zip d_ns d_tps]
      (ixs_xtm, ixs_as') = foldr (\ (a, i) (ixs_xtm, ixs_as) -> if elem (fst a) (map fst as) then (ixs_xtm, (fst a, i) : ixs_as) else (i : ixs_xtm, ixs_as)) ([], []) (zip xs_xtm_as ixs_xtm_as)
      es = Edge (ixs_ctm ++ [ictm]) (show ctm) :
           Edge (ixs_xtm_as ++ [ixtm]) (show xtm) :
           Edge (ixs_as ++ [ictm]) fac :
           discardEdges d_xs d_ixs d_ins
      xs = nub (ixs_ctm ++ all_ixs ++ [ixtm]) in
    addRule' (TmCase ctm y cs tp) (map snd ns) es xs

ambRule :: Ctxt -> FreeVars -> [Term] -> Type -> Term -> RuleM
ambRule g all_fvs tms tp tm =
  term2fgg g tm +>= \ tmxs ->
  let all_xs = Map.toList all_fvs
      (d_xs, d_tps) = unzip (Map.toList (Map.difference all_fvs (Map.fromList tmxs))) -- discard these
      d_ns = newNames 1 d_xs
      (ns, [itp : ixs, all_ixs, d_ixs, d_ins]) =
        combineExts [(newName 0, tp) : tmxs, all_xs, zip d_xs d_tps, zip d_ns d_tps]
      es = Edge (ixs ++ [itp]) (show tm) : discardEdges d_xs d_ixs d_ins
      xs = all_ixs ++ [itp]
  in
    addRule' (TmAmb tms tp) (map snd ns) es xs

-- Add a rule for a lambda term
lamRule :: Bool -> Var -> Type -> Term -> Type -> RuleM -> RuleM
lamRule addVarRule x tp tm tp' rm = -- TODO: new discard rule stuff?
  bindExt addVarRule x tp $
  rm +>= \ tmxs ->
  let (ns, [[itp], [itp', iarr], ixs]) = combineExts [[(x, tp)], newNames' [tp', TpArr tp tp'], tmxs]
      ixs' = delete itp ixs
      es = [Edge (ixs ++ [itp']) (show tm),
            Edge [itp, itp', iarr] (pairFactorName tp tp')]
      xs = ixs' ++ [iarr] in
    addRule' (TmLam x tp tm tp') (map snd ns) es xs +>
    addFactor (pairFactorName tp tp') (getPairWeights tp tp')

addAmpFactors :: Ctxt -> [Type] -> RuleM
addAmpFactors g tps =
  let ws = getAmpWeights (domainValues g) tps in
    foldr (\ (i, w) r -> r +> addFactor (ampFactorName tps i) w) returnRule (enumerate ws)

addProdFactors :: Ctxt -> [Type] -> RuleM
addProdFactors g tps =
  let tpvs = [domainValues g tp | tp <- tps] in
    addFactor (typeFactorName (TpProd tps)) (getCtorEqWeights (length tpvs)) +>
    addFactor (prodFactorName tps) (ThisWeight (getProdWeightsV tpvs)) +>
    foldr (\ (as', w) r -> r +> addFactor (prodFactorName' as') (ThisWeight w)) returnRule (getProdWeights tpvs)

-- Traverse a term and add all rules for subexpressions
term2fgg :: Ctxt -> Term -> RuleM
term2fgg g (TmVarL x tp) =
  addFactor (typeFactorName tp) (getCtorEqWeights (domainSize g tp)) +>
  addExt x tp
term2fgg g (TmVarG gv x [] tp) =
--  addFactor (typeFactorName tp) (getCtorEqWeights (domainSize g tp))
  returnRule -- If this is a ctor/def with no args, we already add its rule when it gets defined
term2fgg g (TmVarG gv x as y) =
  map (\ (a, atp) -> term2fgg g a) (reverse as) +*>= \ xss' ->
  -- TODO: instead of reversing, just have (+*>=) do that
  let xss = reverse xss'
      (ns, (iy : ias) : ixss) = combineExts (newNames' (y : map snd as) : xss)
      es_c = Edge (ias ++ [iy]) (ctorFactorNameDefault x (map snd as) y) :
                 map (\ (ixs, (a, _), itp) -> Edge (ixs ++ [itp]) (show a))
                     (zip3 ixss as ias)
      es_d = Edge (ias ++ [iy]) x : map (\ ((atm, atp), ia, ixs) -> Edge (ixs ++ [ia]) (show atm)) (zip3 as ias ixss)
      es = if gv == CtorVar then es_c else es_d
      xs = nub (concat ixss) ++ [iy]
  in
    addRule' (TmVarG gv x as y) (map snd ns) es xs
term2fgg g (TmLam x tp tm tp') =
  lamRule True x tp tm tp' (term2fgg (ctxtDeclTerm g x tp) tm)
term2fgg g (TmApp tm1 tm2 tp2 tp) =
  tmapp2fgg g (TmApp tm1 tm2 tp2 tp)
term2fgg g (TmCase tm y cs tp) =
  term2fgg g tm +>= \ xs ->
  let fvs = freeVarsCases' cs in
    bindCases (Map.toList (Map.union (freeVars' tm) fvs)) (map (caseRule g fvs xs tm y cs tp) cs)
term2fgg g (TmSamp d tp) =
  let dvs = domainValues g tp
      dvws = vectorWeight dvs in
  case d of
    DistFail ->
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const 0) dvws))
    DistUni  ->
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const (1.0 / fromIntegral (length dvs))) dvws))
    DistAmb  -> -- TODO: is this fine, or do we need to add a rule with one node and one edge (that has the factor below)?
      addFactor (show $ TmSamp d tp) (ThisWeight (fmap (const 1) dvws))
term2fgg g (TmAmb tms tp) =
  let fvs = Map.unions (map freeVars' tms) in
    bindCases (Map.toList fvs) (map (ambRule g fvs tms tp) tms)
term2fgg g (TmLet x xtm xtp tm tp) =
  term2fgg g xtm +>= \ xtmxs ->
  bindExt True x xtp $
  term2fgg (ctxtDeclTerm g x xtp) tm +>= \ tmxs ->
  let (ns, [[ixtp], [itp], ixxs, ixs]) =
        combineExts [[(x, xtp)], newNames' [tp], xtmxs, tmxs]
      ixs' = delete ixtp ixs
      es = [Edge (ixxs ++ [ixtp]) (show xtm), Edge (ixs ++ [itp]) (show tm)]
      xs = nub (ixxs ++ ixs') ++ [itp]
  in
    addRule' (TmLet x xtm xtp tm tp) (map snd ns) es xs
term2fgg g (TmAmpIn as) =
  -- TODO: instead of reversing, just have (+*>=) do that
  let tps = map snd as
      amp = TpAmp tps
  in
    foldr
      (\ (i, (atm, tp)) r -> r +>
        term2fgg g atm +>= \ tmxs ->
        let (ns, [[iamp, itp], ixs]) = combineExts [newNames' [amp, tp], tmxs]
            es = [Edge (ixs ++ [itp]) (show atm),
                  Edge [iamp, itp] (ampFactorName tps i)]
            xs = nub ixs ++ [iamp]
        in
          addRule' (TmAmpIn as) (map snd ns) es xs
      )
      (addAmpFactors g tps) (enumerate as)
term2fgg g (TmAmpOut tm tps o) =
  term2fgg g tm +>= \ tmxs ->
  let tp = tps !! o
      amp = TpAmp tps
      (ns, [[itp, iamp], ixs]) = combineExts [newNames' [tp, amp], tmxs]
      es = [Edge (ixs ++ [iamp]) (show tm),
            Edge [iamp, itp] (ampFactorName tps o)]
      xs = nub ixs ++ [itp]
  in
    addRule' (TmAmpOut tm tps o) (map snd ns) es xs +>
    addAmpFactors g tps
term2fgg g (TmProdIn as) =
  map (\ (a, atp) -> term2fgg g a) (reverse as) +*>= \ xss' ->
  -- TODO: instead of reversing, just have (+*>=) do that
  let xss = reverse xss'  
      tps = map snd as
      ptp = TpProd tps
      (ns, ((iptp : itps) : ixss)) = combineExts (newNames' (ptp : tps) : xss)
      es = Edge (itps ++ [iptp]) (prodFactorName {-(map fst as)-} (map snd as)) : [Edge (ixs ++ [itp]) (show atm) | ((atm, atp), itp, ixs) <- zip3 as itps ixss]
      xs = nub (concat ixss) ++ [iptp]
  in
    addProdFactors g tps +>
    addRule' (TmProdIn as) (map snd ns) es xs
term2fgg g (TmProdOut ptm ps tm tp) =
  term2fgg g ptm +>= \ ptmxs ->
  bindExts True ps $
  term2fgg (ctxtDeclArgs g ps) tm +>= \ tmxs ->
  let (pxs, tps) = unzip ps -- TODO: make sure each param gets referenced? Bc they may not occur in tmxs
      ptp = TpProd tps
      (ns, [(itp : iptp : itps), itmxs, iptmxs]) = combineExts [newNames' (tp : ptp : tps), tmxs, ptmxs]
      es = [Edge (iptmxs ++ [iptp]) (show ptm),
            Edge (itps ++ [iptp]) (prodFactorName tps), -- TODO: xs? Should probably be something else
            Edge (itmxs ++ [itp]) (show tm)]
      xs = nub (iptmxs ++ itmxs) ++ [itp]
  in
    addProdFactors g tps +>
    addRule' (TmProdOut ptm ps tm tp) (map snd ns) es xs


-- Adds the rules for a Prog
prog2fgg :: Ctxt -> Prog -> RuleM
prog2fgg g (ProgFun x ps tm tp) = -- TODO: add factor for joinArrows ps tp
  bindExts True ps $ term2fgg (ctxtDeclArgs g ps) tm +>= \ tmxs ->
  let (unused_x, unused_tp) = unzip (Map.toList (Map.difference (Map.fromList ps) (Map.fromList tmxs)))
      unused_n = map (\ i -> " " ++ show (i + 1)) [0..length unused_x - 1]
      (ns, [[itp], ixs, ips, un_n_ixs, un_x_ixs]) = combineExts [newNames' [tp], tmxs, ps, zip unused_n unused_tp, zip unused_x unused_tp]
      es = Edge (ixs ++ [itp]) (show tm) : discardEdges unused_x un_x_ixs un_n_ixs
      xs = ips ++ [itp]
  in
    addRule' (TmVarG DefVar x [] tp) (map snd ns) es xs
prog2fgg g (ProgExtern x xp ps tp) =
  let (ns, [(itp : ixs)]) = combineExts [newNames' (tp : ps)]
      es = [Edge (ixs ++ [itp]) xp]
      xs = ixs ++ [itp]
      ws = getExternWeights (domainValues g) ps tp
  in
    addRule' (TmVarG DefVar x [] tp) (map snd ns) es xs +>
    addFactor xp ws
prog2fgg g (ProgData y cs) =
  ctorsRules g cs (TpVar y)

-- Goes through a program and adds all the rules for it
progs2fgg :: Ctxt -> Progs -> RuleM
progs2fgg g (Progs ps tm) =
  foldr (\ p rm -> rm +> prog2fgg g p) (term2fgg g tm) ps
  

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
  tpVals (TpAmp tps) =
    let tpvs = map tpVals tps in
      concatMap (\ (i, vs) -> map (\ tmv -> "<" ++ delimitWith ", " [show tp | tp <- tps] ++ ">." ++ show i ++ "=" ++ tmv) vs) (enumerate tpvs)
  tpVals (TpProd tps) =
    [prodValName' tmvs | tmvs <- kronall [tpVals tp | tp <- tps]]

domainSize :: Ctxt -> Type -> Int
domainSize g = length . domainValues g

-- Converts an elaborated program into an FGG
compileFile :: Progs -> Either String String
compileFile ps =
  let g = ctxtDefProgs ps
      Progs _ end = ps
      rm = progs2fgg g ps
      (end', RuleM rs xs nts fs) = addStartRuleIfNecessary end rm in
    return (show (rulesToFGG (domainValues g) end' (reverse rs) nts fs))
