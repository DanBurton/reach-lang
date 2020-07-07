{-# LANGUAGE FlexibleInstances, RecordWildCards, TemplateHaskell  #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
module Reach.VerifyZ3 where

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad
import Control.Monad.Extra
import SimpleSMT --- Maybe use Language.SMTLib2 in future
import System.IO
import System.Exit
import Data.Text.Prettyprint.Doc
import Data.Digest.CRC32
import qualified Data.ByteString.Char8 as BS
import Data.FileEmbed
import Data.IORef
import Control.Loop

import Reach.AST
import Reach.Util

{- Collect Types of IL variables -}

type ILTypeMap = S.Set ILVar

class CollectTypes a where
  cvs :: a -> ILTypeMap

instance CollectTypes a => CollectTypes [a] where
  cvs = foldMap cvs

instance CollectTypes a => CollectTypes (M.Map b a) where
  cvs = foldMap cvs

instance CollectTypes ILVar where
  cvs v = S.singleton v

instance CollectTypes (ILTail a) where
  cvs (IL_Ret _ _) = mempty
  cvs (IL_If _ _ tt ft) = cvs tt <> cvs ft
  cvs (IL_Let _ _ v _ ct) = cvs v <> cvs ct
  cvs (IL_Do _ _ _ ct) = cvs ct
  cvs (IL_ToConsensus _ (_, _, _, _) mto kt) = cvs kt <> mto_vs
    where mto_vs = case mto of Nothing -> mempty
                               Just (_, tt) -> cvs tt
  cvs (IL_FromConsensus _ kt) = cvs kt
  cvs (IL_While _ loopvs _ it ct bt kt) = cvs loopvs <> cvs it <> cvs ct <> cvs bt <> cvs kt
  cvs (IL_Continue _ _) = mempty

instance CollectTypes (ILProgram a) where
  cvs (IL_Prog _ _ ps it) = cvs ps <> cvs it

{- Z3 Printing -}

z3_sortof_bt :: BaseType -> SExpr
--- FIXME switch to fixed bitvectors
z3_sortof_bt BT_UInt256 = Atom "Int"
z3_sortof_bt BT_Bool = Atom "Bool"
z3_sortof_bt BT_Bytes = Atom "Bytes"
z3_sortof_bt BT_Address = Atom "Address"

z3_sortof :: LType -> SExpr
z3_sortof (LT_BT bt) = z3_sortof_bt bt
z3_sortof (LT_FixedArray bt _hm) = List [ Atom "Array", z3_sortof_bt bt, Atom "Int" ]

z3Apply :: String -> [SExpr] -> SExpr
z3Apply f args = List (Atom f : args)

z3Eq :: SExpr -> SExpr -> SExpr
z3Eq x y = z3Apply "=" [ x, y ]

z3Var :: (S.Set ILVar) -> ILVar -> String
z3Var primed v@(n, (s, _)) = "v" ++ show n ++ (if False then "_" ++ s else "") ++ (if (S.member v primed) then "p" else "")

z3VarRef :: (S.Set ILVar) -> ILVar -> SExpr
z3VarRef primed v = Atom $ z3Var primed v

z3CTCBalance :: Int -> String
z3CTCBalance i = "ctc_balance" ++ show i

z3CTCBalanceRef :: Int -> SExpr
z3CTCBalanceRef i = Atom $ z3CTCBalance i

z3TxnValue :: Int -> String
z3TxnValue i = "txn_value" ++ show i

z3TxnValueRef :: Int -> SExpr
z3TxnValueRef i = Atom $ z3TxnValue i

{- Model Rendering -}

pretty_se :: SExpr -> Doc a
pretty_se (List l) = group $ parens $ hsep $ map pretty_se l
pretty_se (Atom a) = pretty a

pretty_se_top :: SExpr -> Doc a
pretty_se_top (List l) = group $ parens $ nest 2 $ vsep $ map pretty_se l
pretty_se_top (Atom a) = pretty a

{- Z3 Interaction -}

display_fail :: Show rolet => Show ann => Bool -> rolet -> TheoremKind -> ann -> SExpr -> IO ()
display_fail honest r tk ann a = do
  putStrLn $ "Verification failed:"
  putStrLn $ "\tin " ++ (if honest then "honest" else "dishonest") ++ " mode"
  putStrLn $ "\tfor " ++ show r
  putStrLn $ "\tof theorem " ++ show tk
  putStrLn $ "\tfrom " ++ show ann
  putStrLn $ "\tspecifically: " ++ (showsSExpr a ":")

z3_verify1 :: Show rolet => Show ann => Solver -> (Bool, rolet, TheoremKind, ann) -> SExpr -> IO VerifyResult
z3_verify1 z3 (honest, who, tk, ann) a = inNewScope z3 $ do
  assert z3 (z3Apply "not" [ a ])
  r <- check z3
  case r of
    Unknown -> impossible "Z3 verify1: Unknown"
    Unsat -> return $ VR 1 0
    Sat -> do
      display_fail honest who tk ann a
      m <- command z3 $ List [ Atom "get-model" ]
      putStrLn $ show $ pretty_se_top m
      return $ VR 0 1

z3_sat1 :: Show rolet => Show ann => Solver -> (Bool, rolet, TheoremKind, ann) -> SExpr -> IO VerifyResult
z3_sat1 z3 (honest, who, tk, ann) a = inNewScope z3 $ do
  assert z3 a
  r <- check z3
  case r of
    Unknown -> impossible "Z3 sat1: Unknown"
    Sat -> return $ VR 1 0
    Unsat -> do
      display_fail honest who tk ann a
      uc <- getUnsatCore z3
      mapM_ putStrLn uc
      return $ VR 0 1

z3_define :: Solver -> String -> LType -> SExpr -> IO ()
z3_define z3 v bt d = do
  let s = z3_sortof bt
  void $ define z3 v s d

z3_declare :: Solver -> String -> LType -> IO ()
z3_declare z3 v bt = do
  let s = z3_sortof bt
  void $ declare z3 v s
  z3_assert_declare z3 (Atom v) bt

z3_assert_declare_bt :: Solver -> SExpr -> BaseType -> IO ()
z3_assert_declare_bt z3 vs bt =
  case bt of
    BT_UInt256 -> assert z3 (z3Apply "<=" [ Atom "0", vs ])
    _ -> mempty

z3_assert_declare :: Solver -> SExpr -> LType -> IO ()
z3_assert_declare z3 vs lty =
  case lty of
    LT_BT bt -> z3_assert_declare_bt z3 vs bt
    LT_FixedArray bt hm ->
      forLoop 0 (<= hm) (+1) h
      where h i = z3_assert_declare_bt z3
                  (List [ Atom "select", vs, Atom (show i)]) bt

z3_assert_chk :: Show ann => Solver -> ann -> SExpr -> IO ()
z3_assert_chk z3 h e = do
  assert z3 e
  r <- check z3
  case r of
    Unknown -> impossible "Z3 assert_chk: Unknown"
    Sat -> mempty
    Unsat -> error $ show h ++ ": Unreachable code with addition of assumption: " ++ show e

{- Z3 Theory Generation

   The Z3 theory has to prove a few different things.

   1. The balance of CTC at the end of the protocol is 0. It will have
   to do this by employing something like the State monad to represent
   all the various modifications to the CTC value overtime and assert
   that it is 0 at the end. This ensures that the protocol doesn't
   "leave anything on the table".

   2. Verify claims (see ClaimType for details)

   SMT-LIB is documented here:
   http://smtlib.cs.uiowa.edu/standard.shtml

 -}

z3CPrim :: Int -> C_Prim -> [SExpr] -> SExpr
z3CPrim cbi cp =
  case cp of
    ADD -> app "+"
    SUB -> app "-"
    MUL -> app "*"
    DIV -> app "div"
    MOD -> app "mod"
    PLT -> app "<"
    PLE -> app "<="
    PEQ -> app "="
    PGE -> app ">="
    PGT -> app ">"
    LSH -> impossible "XXX Z3 doesn't support LSH"
    RSH -> impossible "XXX Z3 doesn't support RSH"
    BAND -> impossible "XXX Z3 doesn't support BAND"
    BIOR -> impossible "XXX Z3 doesn't support BIOR"
    BXOR -> impossible "XXX Z3 doesn't support BXOR"
    IF_THEN_ELSE -> app "ite"
    BYTES_EQ -> app "="
    BALANCE -> \case
      [] -> z3CTCBalanceRef cbi
      _ -> impossible "XXX BALANCE with nonempty [SExpr]"
    TXN_VALUE -> \case
      [] -> z3TxnValueRef cbi
      _ -> impossible "XXX TXN_VALUE with nonempty [SExpr]"
  where app n = z3Apply n

z3PrimEq :: Show a => Solver -> a -> (S.Set ILVar) -> Int -> EP_Prim -> [SExpr] -> ILVar -> IO ()
z3PrimEq z3 h primed cbi pr alt out = case pr of
  CP cp -> z3_assert_chk z3 h (z3Eq (z3VarRef primed out) (z3CPrim cbi cp alt))
  RANDOM -> return ()

data TheoremKind
  = TAssert
  | TRequire
  | TPossible
  | TBalanceZero
  | TBalanceSufficient
  | TInvariant
  | TBounds
  deriving (Show)

type Theorem = (Bool, (Role ILVar), TheoremKind)

data VerifyResult = VR Int Int

instance Semigroup VerifyResult where
  (VR s1 f1) <> (VR s2 f2) = VR (s1 + s2) (f1 + f2)

instance Monoid VerifyResult where
  mempty = VR 0 0

emit_z3_con :: Constant -> SExpr
emit_z3_con (Con_I i) = Atom $ show i
emit_z3_con (Con_B True) = Atom "true"
emit_z3_con (Con_B False) = Atom "false"
emit_z3_con (Con_BS bs) = z3Apply "bytes-literal" [ Atom (show $ crc32 bs) ]

emit_z3_arg :: (S.Set ILVar) -> ILArg a -> SExpr
emit_z3_arg _ (IL_Con _ c) = emit_z3_con c
emit_z3_arg primed (IL_Var _ v) = z3VarRef primed v

z3_vardecl :: Solver -> ILVar -> IO ()
z3_vardecl z3 iv@(_, (_, bt)) = do
  z3_declare z3 (z3Var S.empty iv) bt
  z3_declare z3 (z3Var (S.singleton iv) iv) bt

z3_expr :: Show rolet => Show a => Solver -> (Bool, rolet) -> (S.Set ILVar) -> Int -> ILVar -> ILExpr a -> IO VerifyResult
z3_expr z3 (honest, who) primed cbi out how = case how of
  IL_Declassify h a -> do
    z3_assert_chk z3 h (z3Eq (z3VarRef primed out) (emit_z3_arg primed a))
    return mempty
  IL_PrimApp h pr al -> do
    z3PrimEq z3 h primed cbi pr alt out
    return mempty
    where alt = map (emit_z3_arg primed) al
  IL_Interact _ _ _ _ -> return mempty
  IL_Digest h al -> do
    z3_assert_chk z3 h (z3Eq (z3VarRef primed out) (z3Apply "digest" [ z3DigestCombine primed al ]))
    return mempty
  IL_ArrayRef h ae ee -> do
    let hm = case ilarg_type ae of
               LT_FixedArray _ x -> x
               _ -> impossible $ "IL_ArrayRef called with no Array"
    z3_assert_chk z3 h (z3Eq (z3VarRef primed out) (z3Apply "select" [ (emit_z3_arg primed ae), (emit_z3_arg primed ee) ]))
    z3_verify1 z3 (honest, who, TBounds, h) (z3CPrim cbi PLT [ (emit_z3_arg primed ee), (emit_z3_con $ Con_I hm) ])

z3DigestCombine :: Show a => (S.Set ILVar) -> [ILArg a] -> SExpr
z3DigestCombine primed ys =
  case ys of
    [] -> z3Apply "bytes0" []
    [ x ] -> convert1 x
    (x : xs) -> z3Apply "msg-cat" [ convert1 x , z3DigestCombine primed xs ]
  where convert1 a = z3Apply (toBytes a) [ emit_z3_arg primed a ]
        toBytes (IL_Var _ (_, (_, bt))) = "toBytes_" ++ s
          where s = case z3_sortof bt of
                  Atom a -> a
                  _ -> error "Expected an Atom" -- XXX
        toBytes (IL_Con _ c) = "toBytes_" ++ s
          where s= case c of
                     Con_I _ -> "Int"
                     Con_B _ -> "Bool"
                     Con_BS _ -> "Bytes"

z3_stmt :: Show rolet => Show a => Solver -> Bool -> rolet -> (S.Set ILVar) -> Int -> ILStmt a -> IO (Int, VerifyResult)
z3_stmt z3 honest r primed cbi how =
  case how of
    IL_Transfer h _who amount -> do vr <- z3_verify1 z3 (honest, r, TBalanceSufficient, h) (z3Apply "<=" [ amountt, cbit ])
                                    z3_define z3 cb' (LT_BT BT_UInt256) (z3Apply "-" [ cbit, amountt ])
                                    return (cbi', vr)
      where cbi' = cbi + 1
            cbit = z3CTCBalanceRef cbi
            cb' = z3CTCBalance cbi'
            amountt = emit_z3_arg primed amount
    IL_Claim h CT_Possible a -> do vr <- z3_sat1 z3 (honest, r, TPossible, h) at
                                   return ( cbi, vr )
      where at = emit_z3_arg primed a
    IL_Claim h ct a -> do vr <- this_check
                          assert z3 at
                          return ( cbi, vr )
      where at = emit_z3_arg primed a
            this_check = case mct of
              Just tk -> z3_verify1 z3 (honest, r, tk, h) at
              Nothing -> return mempty
            mct = case ct of
              CT_Assert -> Just TAssert
              CT_Assume -> Nothing
              CT_Require | honest -> Just TRequire
              CT_Require -> Nothing
              CT_Possible -> impossible $ "CT_Possible in previous case"

data VerifyCtxt a
  = VC_Top
  | VC_AssignCheckInv Bool [ILVar] (ILTail a)
  | VC_CheckRet
  | VC_WhileBody_AssumeNotUntil [ILVar] (ILTail a) (ILTail a) (VerifyCtxt a)
  | VC_WhileBody_AssumeInv [ILVar] (ILTail a) (ILTail a) (VerifyCtxt a)
  | VC_WhileBody_Eval [ILVar] (ILTail a) (VerifyCtxt a)
  | VC_WhileTail_AssumeUntil (ILTail a) (VerifyCtxt a, (ILTail a))
  | VC_WhileTail_AssumeInv (VerifyCtxt a, (ILTail a))
  deriving (Show)

extract_invariant_variables :: ILTail a -> [ILVar]
extract_invariant_variables invt =
  case invt of
    IL_Ret _ _ -> []
    IL_Let _ _ v _ t -> v : extract_invariant_variables t
    _ -> impossible $ "Z3: invalid invariant structure"

z3_it_top :: Show a => Solver -> ILTail a -> (Bool, (Role ILVar)) -> IO VerifyResult
z3_it_top z3 it_top (honest, me) = inNewScope z3 $ do
  putStrLn $ "Verifying with honest = " ++ show honest ++ "; role = " ++ show me
  z3_declare z3 cb0 (LT_BT BT_UInt256)
  meta_iter mempty [(True, VC_Top, it_top)]
  where zero = emit_z3_con (Con_I 0)
        cb0 = z3CTCBalance 0
        meta_iter :: Show a => VerifyResult -> [(Bool, VerifyCtxt a, ILTail a)] -> IO VerifyResult
        meta_iter vr0 [] = return vr0
        meta_iter vr0 ( (assume_cb_zero, ctxt, it) : more0 ) = do
          putStrLn $ "...checking " ++ take 32 (show ctxt)
          (more1, vr1) <- inNewScope z3 $ (do (if assume_cb_zero then assert z3 (z3Eq (z3CTCBalanceRef 0) zero) else mempty)
                                              iter (S.empty) 0 ctxt it)
          let vr = vr0 <> vr1
          let more = more0 ++ more1
          meta_iter vr more
        iter :: Show a => (S.Set ILVar) -> Int -> VerifyCtxt a -> ILTail a -> IO ([(Bool, VerifyCtxt a, ILTail a)], VerifyResult)
        iter primed cbi ctxt it = case it of
          IL_Ret h al -> do
            case ctxt of
              VC_Top -> do
                let cbi_balance = z3Eq (z3CTCBalanceRef cbi) zero
                vr <- z3_verify1 z3 (honest, me, TBalanceZero, h) cbi_balance
                return ([], vr)
              VC_AssignCheckInv should_prime loopvs invt -> do
                let invt_vs = extract_invariant_variables invt
                let primed' = if should_prime then S.unions [primed, S.fromList loopvs, S.fromList invt_vs] else primed
                mapM_ (\(loopv, a) ->
                         z3_assert_chk z3 h (z3Eq (z3VarRef primed' loopv) (emit_z3_arg primed a)))
                      (zip loopvs al)
                iter primed' cbi VC_CheckRet invt
              VC_CheckRet -> do
                a <- case al of
                  [ x ] -> return x
                  _ -> fail "Expected [ILArg] to have exactly one element"  -- XXX
                vr <- z3_verify1 z3 (honest, me, TInvariant, h) (emit_z3_arg primed a)
                return ([], vr)
              VC_WhileBody_AssumeNotUntil loopvs invt bodyt kctxt -> do
                a <- case al of
                  [ x ] -> return x
                  _ -> fail "Expected [ILArg] to have exactly one element"  -- XXX
                z3_assert_chk z3 h (z3Apply "not" [ emit_z3_arg primed a ])
                iter primed cbi (VC_WhileBody_AssumeInv loopvs invt bodyt kctxt) invt
              VC_WhileBody_AssumeInv loopvs invt bodyt kctxt -> do
                a <- case al of
                  [ x ] -> return x
                  _ -> fail "Expected [ILArg] to have exactly one element"  -- XXX
                z3_assert_chk z3 h (emit_z3_arg primed a)
                iter primed cbi (VC_WhileBody_Eval loopvs invt kctxt) bodyt
              VC_WhileBody_Eval _ _ kctxt ->
                iter primed cbi kctxt it
              VC_WhileTail_AssumeUntil invt ki -> do
                a <- case al of
                  [ x ] -> return x
                  _ -> fail "Expected [ILArg] to have exactly one element"  -- XXX
                z3_assert_chk z3 h (emit_z3_arg primed a)
                iter primed cbi (VC_WhileTail_AssumeInv ki) invt
              VC_WhileTail_AssumeInv (kctxt, kt) -> do
                a <- case al of
                  [ x ] -> return x
                  _ -> fail "Expected [ILArg] to have exactly one element"  -- XXX
                z3_assert_chk z3 h (emit_z3_arg primed a)
                iter primed cbi kctxt kt
          IL_If h ca tt ft -> do
            mconcatMapM (inNewScope z3 . f) (zip [True, False] [tt, ft])
            where ca' = emit_z3_arg primed ca
                  f (v, kt) = do z3_assert_chk z3 h (z3Eq ca' cav)
                                 iter primed cbi ctxt kt
                    where cav = emit_z3_con (Con_B v)
          IL_Let _ who what how kt ->
            do vr <- if (honest || role_me me who) then z3_expr z3 (honest, who) primed cbi what how else return mempty
               (mt, vr') <- iter primed cbi ctxt kt
               return (mt, vr <> vr')
          IL_Do _ who how kt ->
            if (honest || role_me me who) then
              do (cbi', vr) <- z3_stmt z3 honest me primed cbi how
                 (mt, vr') <- iter primed cbi' ctxt kt
                 return (mt, vr <> vr')
            else
              iter primed cbi ctxt kt
          IL_ToConsensus h (_ok_ij, _who, _msg, amount) mto kt ->
            mconcatMapM (inNewScope z3) [timeout, notimeout]
            where
              timeout = case mto of
                          Nothing -> mempty
                          Just (_da, tt) -> do
                            iter primed cbi ctxt tt
              notimeout = do
                z3_declare z3 pvv (LT_BT BT_UInt256)
                z3_define z3 cb'v (LT_BT BT_UInt256) (z3Apply "+" [cbr, pvr])
                z3_assert_chk z3 h thisc
                iter primed cbi' ctxt kt
              cbi' = cbi + 1
              cb'v = z3CTCBalance cbi'
              cbr = z3CTCBalanceRef cbi
              amountt = emit_z3_arg primed amount
              pvv = z3TxnValue cbi'
              pvr = z3TxnValueRef cbi'
              thisc = if honest then
                        z3Eq pvr amountt
                      else
                        z3Apply "<=" [ zero, pvr ]
          IL_FromConsensus _ kt -> iter primed cbi ctxt kt
          IL_While x loopvs initas untilt invt bodyt kt -> do
            (mt, vr) <- iter primed cbi (VC_AssignCheckInv False loopvs invt) (IL_Ret x initas)
            let bodyj = (False, VC_WhileBody_AssumeNotUntil loopvs invt bodyt ctxt, untilt)
            let tailj = (False, VC_WhileTail_AssumeUntil invt (ctxt, kt), untilt)
            let mt' = mt ++ [ bodyj, tailj ]
            return (mt ++ mt', vr)
          IL_Continue x newas ->
            case ctxt of
              VC_WhileBody_Eval loopvs invt _kctxt ->
                iter primed cbi (VC_AssignCheckInv True loopvs invt) (IL_Ret x newas)
              _ ->
                impossible $ "VerifyZ3 IL_Continue must only occur inside While"

z3StdLib :: String
z3StdLib = BS.unpack $(embedFile "./z3/z3-runtime.smt2")

_verify_z3 :: Show a => Solver -> ILProgram a -> IO ExitCode
_verify_z3 z3 tp = do
  loadString z3 z3StdLib
  mapM_ (z3_vardecl z3) $ S.toList $ cvs tp
  VR ss fs <- mconcatMapM (z3_it_top z3 it) (liftM2 (,) [True, False] ps)
  putStr $ "Checked " ++ (show $ ss + fs) ++ " theorems;"
  (if ( fs == 0 ) then
      do putStrLn $ " No failures!"
         return ExitSuccess
   else
      do putStrLn $ " " ++ show fs ++ " failures. :'("
         return $ ExitFailure 1)
  where IL_Prog _ _ ipi it = tp
        ps = RoleContract : (map RolePart $ M.keys ipi)

newFileLogger :: FilePath -> IO (IO (), Logger)
newFileLogger p = do
  logh <- openFile p WriteMode
  tabr <- newIORef 0
  let logLevel = return 0
      logSetLevel _ = return ()
      logTab = modifyIORef tabr $ \x -> x + 1
      logUntab = modifyIORef tabr $ \x -> x - 1
      printTab = do
        tab <- readIORef tabr
        mapM_ (\_ -> hPutStr logh " ") $ take tab $ repeat ()
      send_tag = "[send->]"
      recv_tag = "[<-recv]"
      logMessage m' = do
        let (which, m) = splitAt (length send_tag) m'
        let short_which = if which == send_tag then "+" else "-"
        if (which == recv_tag && m == " success") then
          return ()
        else if (m == " (push 1 )") then do
          printTab
          hPutStrLn logh $ "(push"
          hFlush logh
          logTab
        else if (m == " (pop 1 )") then do
          logUntab
          printTab
          hPutStrLn logh $ ")"
          hFlush logh
        else do
          printTab
          hPutStrLn logh $ "(" ++ short_which ++ m ++ ")"
          hFlush logh
      close = hClose logh
  return (close, Logger { .. })

verify_z3 :: Show a => FilePath -> ILProgram a -> IO ()
verify_z3 logp tp = do
  (close, logpl) <- newFileLogger logp
  z3 <- newSolver "z3" ["-smt2", "-in"] (Just logpl)
  unlessM (produceUnsatCores z3) $ impossible "Prover doesn't support possible?"
  vec <- _verify_z3 z3 tp
  zec <- stop z3
  close
  maybeDie $ return zec
  maybeDie $ return vec
