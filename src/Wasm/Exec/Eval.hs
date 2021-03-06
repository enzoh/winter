{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

module Wasm.Exec.Eval where

import           Control.Exception
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Trans.Reader hiding (local)
import qualified Control.Monad.Trans.Reader as Reader
import           Control.Monad.Trans.State
import qualified Data.ByteString.Lazy as B
import           Data.Default.Class (Default(..))
import           Data.Fix
import           Data.Functor.Classes
import           Data.Int
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import           Data.List hiding (lookup, elem)
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Maybe
import           Data.Text.Lazy (Text, unpack)
import qualified Data.Vector as V
import           Lens.Micro.Platform
import           Prelude hiding (lookup, elem)
import           Text.Show (showListWith)

import           Wasm.Exec.EvalNumeric
import qualified Wasm.Runtime.Func as Func
import qualified Wasm.Runtime.Global as Global
import           Wasm.Runtime.Instance
import qualified Wasm.Runtime.Memory as Memory
import           Wasm.Runtime.Mutable
import           Wasm.Runtime.Table as Table
import           Wasm.Syntax.AST
import           Wasm.Syntax.Ops
import           Wasm.Syntax.Types
import           Wasm.Syntax.Values as Values
import           Wasm.Util.Source

-- import           Debug.Trace

{- Errors -}

data EvalError
  = EvalLinkError Region String
  | EvalTrapError Region String
  | EvalCrashError Region String
  | EvalMemoryError Region Memory.MemoryError
  | EvalGlobalError Region Global.GlobalError
  | EvalTableError Region Table.TableError
  | EvalExhaustionError Region String
  | EvalNumericError Region NumericError
  deriving (Show, Eq)

instance Exception EvalError

memoryErrorString :: Memory.MemoryError -> String
memoryErrorString = \case
  Memory.MemoryBoundsError  -> "out of bounds memory access"
  Memory.MemorySizeOverflow -> "memory size overflow"
  Memory.MemorySizeLimit    -> "memory size limit reached"
  Memory.MemoryTypeError    -> "type mismatch at memory access"
  Memory.MemoryOutOfMemory  -> "out of memory"

{-
numericError at = \case
  NumericError.IntegerOverflow -> "integer overflow"
  NumericError.IntegerDivideByZero -> "integer divide by zero"
  NumericError.InvalidConversionToInteger -> "invalid conversion to integer"
  EvalNumeric.TypeError (i, v, t) ->
    Crash.error at
      ("type error, expected " ^ Types.string_of_value_type t ^ " as operand " ^
       string_of_int i ^ ", got " ^ Types.string_of_value_type (type_of v))
  exn -> raise exn
-}

{- Administrative Expressions & Configurations -}

type Stack a = [a]

data Frame f m = Frame
  { _frameInst :: !(ModuleInst f m)
  , _frameLocals :: ![Mutable m Value]
  }

instance Show (Frame f m) where
  showsPrec d Frame {..}
    = showString "Frame (with "
    . showsPrec d (length _frameLocals)
    . showString " locals)"

makeLenses ''Frame

data Code f m = Code
  { _codeStack  :: !(Stack Value)
  , _codeInstrs :: ![f (AdminInstr f m)]
  }

instance (Regioned f, Show1 f) => Show (Code f m) where
  showsPrec d Code {..} =
    showParen (d > 10)
      $ showString "Code "
      . showsPrec 11 _codeStack
      . showString " "
      . showListWith (showsPrec1 11) _codeInstrs

data AdminInstr f m
  = Plain !(Instr f)
  | Invoke !(ModuleFunc f m)
  | Trapping !String
  | Returning !(Stack Value)
  | Breaking !Int !(Stack Value)
  | Label !Int ![f (Instr f)] !(Code f m)
  | Framed !Int !(Frame f m) !(Code f m)

instance (Regioned f, Show1 f) => Show (AdminInstr f m) where
  showsPrec d = showParen (d > 10) . \case
    Plain p      -> showString "Plain "     . showsPrec 11 p
    Invoke i     -> showString "Invoke "    . showsPrec1 11 i
    Trapping t   -> showString "Trapping "  . showsPrec1 11 t
    Returning r  -> showString "Returning " . showsPrec1 11 r
    Breaking i s -> showString "Breaking "  . showsPrec 11 i
                                           . showString " "
                                           . showsPrec1 11 s
    Label i l c  -> showString "Label "     . showsPrec 11 i
                                           . showString " "
                                           . showListWith (showsPrec1 11) l
                                           . showString " "
                                           . showsPrec 11 c
    Framed i f c -> showString "Framed "    . showsPrec 11 i
                                           . showString " "
                                           . showsPrec 11 f
                                           . showString " "
                                           . showsPrec 11 c

makeLenses ''Code

data Config f m = Config
  { _configModules :: !(IntMap (ModuleInst f m))
  , _configFrame   :: !(Frame f m)
  , _configBudget  :: !Int                {- to model stack overflow -}
  }

makeLenses ''Config

type EvalT m a = ExceptT EvalError m a
type CEvalT f m a = ReaderT (Config f m) (ExceptT EvalError m) a

getInst :: Monad m => ModuleRef -> CEvalT f m (ModuleInst f m)
getInst ref = do
  mres <- view (configModules.at ref)
  case mres of
    Nothing -> throwError $
      EvalCrashError def $ "Reference to unknown module #" ++ show ref
    Just x  -> return x

getFrameInst :: Monad m => CEvalT f m (ModuleInst f m)
getFrameInst = view (configFrame.frameInst)

newConfig :: IntMap (ModuleInst f m) -> ModuleInst f m -> Config f m
newConfig mods inst = Config
  { _configModules = mods
  , _configFrame   = Frame inst []
  , _configBudget  = 300
  }

plain :: Regioned f => f (Instr f) -> f (AdminInstr f m)
plain e = Plain (value e) @@ region e
{-# INLINE plain #-}

lookup :: (Regioned f, Monad m)
       => String -> s -> Lens' s [a] -> Var f -> EvalT m a
lookup category inst l x@(value -> x') =
  if fromIntegral x' < length (inst^.l)
  then pure $ inst^?!l.ix (fromIntegral x')
  else throwError $
    EvalCrashError (region x) ("undefined " <> category <> " " <> show x')

assignment :: (Regioned f, Monad m)
           => String -> s -> Lens' s [a] -> Var f -> a -> EvalT m s
assignment category inst l x@(value -> x') v =
  if fromIntegral x' < length (inst^.l)
  then pure $ inst & l.ix (fromIntegral (value x)) .~ v
  else throwError $
    EvalCrashError (region x) ("cannot assign " <> category <> " " <> show x')

type_ :: (Regioned f, Monad m)
      => ModuleInst f m -> Var f -> EvalT m FuncType
type_ inst = fmap value . lookup "type" inst (miModule.moduleTypes)

func :: (Regioned f, Monad m)
     => ModuleInst f m -> Var f -> EvalT m (ModuleFunc f m)
func inst = lookup "function" inst miFuncs

table :: (Regioned f, Monad m)
      => ModuleInst f m -> Var f -> EvalT m (TableInst m (ModuleFunc f m))
table inst = lookup "table" inst miTables

memory :: (Regioned f, Monad m)
       => ModuleInst f m -> Var f -> EvalT m (Memory.MemoryInst m)
memory inst = lookup "memory" inst miMemories

global :: (Regioned f, Monad m)
       => ModuleInst f m -> Var f -> EvalT m (Global.GlobalInst m)
global inst = lookup "global" inst miGlobals

local :: (Regioned f, Monad m)
      => Frame f m -> Var f -> EvalT m (Mutable m Value)
local frame = lookup "local" frame frameLocals

elem :: (Regioned f, MonadRef m, Monad m)
     => ModuleInst f m -> Var f -> Table.Index -> Region
     -> EvalT m (ModuleFunc f m)
elem inst x i at' = do
  t <- table inst x
  x <- lift $ Table.load t i
  case x of
    Nothing -> throwError $
      EvalTrapError at' ("uninitialized element " ++ show i)
    Just f -> pure f

funcElem :: (Regioned f, MonadRef m, Monad m)
         => ModuleInst f m -> Var f -> Table.Index -> Region
         -> EvalT m (ModuleFunc f m)
funcElem = elem
{-# INLINE funcElem #-}

takeFrom :: Monad m
         => Int -> Stack a -> Region -> EvalT m (Stack a)
takeFrom n vs at' =
  if n > length vs
  then throwError $ EvalCrashError at' "stack underflow"
  else pure $ take n vs

dropFrom :: Monad m
         => Int -> Stack a -> Region -> EvalT m (Stack a)
dropFrom n vs at' =
  if n > length vs
  then throwError $ EvalCrashError at' "stack underflow"
  else pure $ drop n vs

partialZip :: [a] -> [b] -> [Either a (Either b (a, b))]
partialZip [] [] = []
partialZip xs [] = map Left xs
partialZip [] ys = map (Right . Left) ys
partialZip (x:xs) (y:ys) = Right (Right (x, y)) : partialZip xs ys

checkTypes :: Monad m
           => Region -> [ValueType] -> [Value] -> EvalT m ()
checkTypes at ts xs = forM_ (partialZip ts xs) $ \case
  Left t ->
    throwError $ EvalCrashError at $ "missing argument of type " ++ show t
  Right (Left x) ->
    throwError $ EvalCrashError at $ "unexpected argument " ++ show x
  Right (Right (t, x)) | Values.typeOf x /= t ->
    throwError $ EvalCrashError at $ "expected type " ++ show t
      ++ " got " ++ show x
    | otherwise -> return ()


{- Evaluation -}

{-
 * Conventions:
 *   e  : instr
 *   v  : value
 *   es : instr list
 *   vs : value stack
 *   c : config
 -}

step_work :: (Regioned f, MonadRef m, Monad m, Show1 f)
          => Stack Value -> Region -> AdminInstr f m
          -> (Code f m -> CEvalT f m r)
          -> CEvalT f m r
step_work vs at i k = case i of
  Plain e' -> {-# SCC step_Plain #-} instr vs at e' k

  Trapping msg -> {-# SCC step_Trapping #-}
    throwError $ EvalTrapError at msg
  Returning _  -> {-# SCC step_Returning #-}
    throwError $ EvalCrashError at "undefined frame"
  Breaking _ _ -> {-# SCC step_Breaking #-}
    throwError $ EvalCrashError at "undefined label"

  Label _ _ (Code vs' []) -> {-# SCC step_Label1 #-}
    k $ Code (vs' ++ vs) []
  Label n es0 code'@(Code _ (t@(value -> c) : _)) -> {-# SCC step_Label2 #-}
    case c of
      Trapping msg -> {-# SCC step_Label3 #-}
        k $ Code vs [Trapping msg @@ region t]
      Returning vs0 -> {-# SCC step_Label4 #-}
        k $ Code vs [Returning vs0 @@ region t]
      Breaking 0 vs0 -> {-# SCC step_Label5 #-} do
        vs0' <- lift $ takeFrom n vs0 at
        k $ Code (vs0' ++ vs) (map plain es0)
      Breaking bk vs0 -> {-# SCC step_Label6 #-}
        k $ Code vs [Breaking (bk - 1) vs0 @@ at]
      _ -> {-# SCC step_Label7 #-} do
        step code' $ \res ->
          k $ Code vs [Label n es0 res @@ at]

  Framed _ _ (Code vs' []) -> {-# SCC step_Framed1 #-}
    k $ Code (vs' ++ vs) []
  Framed _ _ (Code _ (t@(value -> Trapping msg) : _)) -> {-# SCC step_Framed2 #-}
    k $ Code vs [Trapping msg @@ region t]
  Framed n _ (Code _ ((value -> Returning vs0) : _)) -> {-# SCC step_Framed3 #-} do
    vs0' <- lift $ takeFrom n vs0 at
    k $ Code (vs0' ++ vs) []
  Framed n frame' code' -> {-# SCC step_Framed4 #-}
    Reader.local (\c -> c & configFrame .~ frame'
                         & configBudget %~ pred) $
      step code' $ \res ->
        k $ Code vs [Framed n frame' res @@ at]

  Invoke func -> {-# SCC step_Invoke #-} do
    budget <- view configBudget
    when (budget == 0) $
      throwError $ EvalExhaustionError at "call stack exhausted"

    let FuncType ins outs = Func.typeOf func
        n = length ins

    (reverse -> args, vs') <-
      if n > length vs
      then throwError $ EvalCrashError at "stack underflow"
      else pure $ splitAt n vs

    -- traceM $ "Invoke: ins  = " ++ show ins
    -- traceM $ "Invoke: args = " ++ show args
    -- traceM $ "Invoke: outs = " ++ show outs
    -- traceM $ "Invoke: vs'  = " ++ show vs'

    lift $ checkTypes at ins args

    case func of
      Func.AstFunc _ ref f -> do
        inst' <- getInst ref
        locals' <- lift $ lift $ traverse newMut $
          args ++ map defaultValue (value f^.funcLocals)
        let code' = Code [] [Plain (Fix (Block outs (value f^.funcBody))) @@ region f]
            frame' = Frame inst' locals'
        k $ Code vs' [Framed (length outs) frame' code' @@ at]

      Func.HostFunc _ f -> do
        -- jww (2018-11-01): Need an exception handler here, so we can
        -- report host errors.
        let res = reverse (f args)
        lift $ checkTypes at outs res
        k $ Code (res ++ vs') []
        -- try (reverse (f args) ++ vs', [])
        -- with Crash (_, msg) -> EvalCrashError at msg)

      Func.HostFuncEff _ f -> do
        -- jww (2018-11-01): Need an exception handler here, so we can
        -- report host errors.
        res <- lift $ lift $ reverse <$> f args
        lift $ checkTypes at outs res
        k $ Code (res ++ vs') []
        -- try (reverse (f args) ++ vs', [])
        -- with Crash (_, msg) -> EvalCrashError at msg)

{-# SPECIALIZE step_work
      :: Stack Value -> Region -> AdminInstr Phrase IO
      -> (Code Phrase IO -> CEvalT Phrase IO r)
      -> CEvalT Phrase IO r #-}

instr :: (Regioned f, {-Show1 f,-} MonadRef m, Monad m)
      => Stack Value -> Region -> Instr f
      -> (Code f m -> CEvalT f m r)
      -> CEvalT f m r
instr vs at e' k = case (unFix e', vs) of
  (Unreachable, vs)              -> {-# SCC step_Unreachable #-}
    k $ Code vs [Trapping "unreachable executed" @@ at]
  (Nop, vs)                      -> {-# SCC step_Nop #-}
    k $ Code vs []
  (Block ts es', vs)             -> {-# SCC step_Block #-}
    k $ Code vs [Label (length ts) [] (Code [] (map plain es')) @@ at]
  (Loop _ es', vs)               -> {-# SCC step_Loop #-}
    k $ Code vs [Label 0 [e' @@ at] (Code [] (map plain es')) @@ at]
  (If ts _ es2, I32 0 : vs')     -> {-# SCC step_If1 #-}
    k $ Code vs' [Plain (Fix (Block ts es2)) @@ at]
  (If ts es1 _, I32 _ : vs')     -> {-# SCC step_If2 #-}
    k $ Code vs' [Plain (Fix (Block ts es1)) @@ at]
  (Br x, vs)                     -> {-# SCC step_Br #-}
    k $ Code [] [Breaking (value x) vs @@ at]
  (BrIf _, I32 0 : vs')          -> {-# SCC step_BrIf1 #-}
    k $ Code vs' []
  (BrIf x, I32 _ : vs')          -> {-# SCC step_BrIf2 #-}
    k $ Code vs' [Plain (Fix (Br x)) @@ at]
  (BrTable xs x, I32 i : vs')
    | i < 0 || fromIntegral i >= length xs -> {-# SCC step_BrTable1 #-}
      k $ Code vs' [Plain (Fix (Br x)) @@ at]
    | otherwise -> {-# SCC step_BrTable2 #-}
      k $ Code vs' [Plain (Fix (Br (xs !! fromIntegral i))) @@ at]
  (Return, vs)                   -> {-# SCC step_Return #-}
    k $ Code vs [Returning vs @@ at]

  (Call x, vs) -> {-# SCC step_Call #-} do
    inst <- getFrameInst
    -- traceM $ "Call " ++ show (value x)
    f <- lift $ func inst x
    k $ Code vs [Invoke f @@ at]

  (CallIndirect x, I32 i : vs) -> {-# SCC step_CallIndirect #-} do
    inst <- getFrameInst
    func <- lift $ funcElem inst (0 @@ at) i at
    t <- lift $ type_ inst x
    k $ Code vs $
      if t /= Func.typeOf func
      then [Trapping "indirect call type mismatch" @@ at]
      else [Invoke func @@ at]

  (Drop, _ : vs') -> {-# SCC step_Drop #-}
    k $ Code vs' []

  (Select, I32 0 : v2 : _ : vs') -> {-# SCC step_Select1 #-}
    k $ Code (v2 : vs') []
  (Select, I32 _ : _ : v1 : vs') -> {-# SCC step_Select2 #-}
    k $ Code (v1 : vs') []

  (GetLocal x, vs) -> {-# SCC step_GetLocal #-} do
    frame <- view configFrame
    mut <- lift $ local frame x
    l <- lift $ lift $ getMut mut
    k $ Code (l : vs) []

  (SetLocal x, v : vs') -> {-# SCC step_SetLocal #-} do
    frame <- view configFrame
    mut <- lift $ local frame x
    lift $ lift $ setMut mut v
    k $ Code vs' []

  (TeeLocal x, v : vs') -> {-# SCC step_TeeLocal #-} do
    frame <- view configFrame
    mut <- lift $ local frame x
    lift $ lift $ setMut mut v
    k $ Code (v : vs') []

  (GetGlobal x, vs) -> {-# SCC step_GetGlobal #-} do
    inst <- getFrameInst
    g <- lift . lift . Global.load =<< lift (global inst x)
    -- traceM $ "GetGlobal " ++ show (value x) ++ " = " ++ show g
    k $ Code (g : vs) []

  (SetGlobal x, v : vs') -> {-# SCC step_SetGlobal #-} do
    inst <- getFrameInst
    g <- lift $ global inst x
    eres <- lift $ lift $ runExceptT $ Global.store g v
    case eres of
      Right () -> k $ Code vs' []
      Left err -> throwError $ EvalCrashError at $ case err of
        Global.GlobalNotMutable -> "write to immutable global"
        Global.GlobalTypeError  -> "type mismatch at global write"

  (Load op, I32 i : vs') -> {-# SCC step_Load #-} do
    inst <- getFrameInst
    mem <- lift $ memory inst (0 @@ at)
    let addr = fromIntegral $ i64_extend_u_i32 (fromIntegral i)
    let off = fromIntegral (op^.memoryOffset)
    let ty = op^.memoryValueType
    eres <- lift $ lift $ runExceptT $ case op^.memorySize of
          Nothing        -> Memory.loadValue mem addr off ty
          Just (sz, ext) -> Memory.loadPacked sz ext mem addr off ty
    k $ case eres of
      Right v' -> Code (v' : vs') []
      Left exn -> Code vs' [Trapping (memoryErrorString exn) @@ at]

  (Store op, v : I32 i : vs') -> {-# SCC step_Store #-} do
    inst <- getFrameInst
    mem <- lift $ memory inst (0 @@ at)
    let addr = fromIntegral $ i64_extend_u_i32 (fromIntegral i)
    let off = fromIntegral (op^.memoryOffset)
    eres <- lift $ lift $ runExceptT $ case op^.memorySize of
          Nothing -> Memory.storeValue mem addr off v
          Just sz -> Memory.storePacked sz mem addr off v
    case eres of
      Right () -> k $ Code vs' []
      Left exn ->
        k $ Code vs' [Trapping (memoryErrorString exn) @@ at]

  (MemorySize, vs) -> {-# SCC step_MemorySize #-} do
    inst <- getFrameInst
    mem  <- lift $ memory inst (0 @@ at)
    sz   <- lift $ lift $ Memory.size mem
    k $ Code (I32 sz : vs) []

  (MemoryGrow, I32 delta : vs') -> {-# SCC step_MemoryGrow #-} do
    inst    <- getFrameInst
    mem     <- lift $ memory inst (0 @@ at)
    oldSize <- lift $ lift $ Memory.size mem
    eres    <- lift $ lift $ runExceptT $ Memory.grow mem delta
    let result = case eres of
            Left _   -> -1
            Right () -> oldSize
    k $ Code (I32 result : vs') []

  (Const v, vs) -> {-# SCC step_Const #-}
    k $ Code (value v : vs) []

  (Test testop, v : vs') -> {-# SCC step_Test #-} do
    let eres = case testop of
          I32TestOp o -> testOp @Int32 intTestOp o v
          I64TestOp o -> testOp @Int64 intTestOp o v
    k $ case eres of
      Left err -> Code vs' [Trapping (show err) @@ at]
      Right v' -> Code (v' : vs') []

  (Compare relop, v2 : v1 : vs') -> {-# SCC step_Compare #-} do
    let eres = case relop of
          I32CompareOp o -> compareOp @Int32 intRelOp o v1 v2
          I64CompareOp o -> compareOp @Int64 intRelOp o v1 v2
          F32CompareOp o -> compareOp @Float floatRelOp o v1 v2
          F64CompareOp o -> compareOp @Double floatRelOp o v1 v2
    k $ case eres of
      Left err -> Code vs' [Trapping (show err) @@ at]
      Right v' -> Code (v' : vs') []

  (Unary unop, v : vs') -> {-# SCC step_Unary #-} do
    let eres = case unop of
          I32UnaryOp o -> unaryOp @Int32 intUnOp o v
          I64UnaryOp o -> unaryOp @Int64 intUnOp o v
          F32UnaryOp o -> unaryOp @Float floatUnOp o v
          F64UnaryOp o -> unaryOp @Double floatUnOp o v
    k $ case eres of
      Left err -> Code vs' [Trapping (show err) @@ at]
      Right v' -> Code (v' : vs') []

  (Binary binop, v2 : v1 : vs') -> {-# SCC step_Binary #-} do
    let eres = case binop of
          I32BinaryOp o -> binaryOp @Int32 intBinOp o v1 v2
          I64BinaryOp o -> binaryOp @Int64 intBinOp o v1 v2
          F32BinaryOp o -> binaryOp @Float floatBinOp o v1 v2
          F64BinaryOp o -> binaryOp @Double floatBinOp o v1 v2
    k $ case eres of
      Left err -> Code vs' [Trapping (show err) @@ at]
      Right v' -> Code (v' : vs') []

  (Convert cvtop, v : vs') -> {-# SCC step_Convert #-} do
    let eres = case cvtop of
          I32ConvertOp o -> intCvtOp @Int32 o v
          I64ConvertOp o -> intCvtOp @Int64 o v
          F32ConvertOp o -> floatCvtOp @Float o v
          F64ConvertOp o -> floatCvtOp @Double o v
    k $ case eres of
      Left err -> Code vs' [Trapping (show err) @@ at]
      Right v' -> Code (v' : vs') []

  _ ->  {-# SCC step_fallthrough_ #-} do
    let s1 = show (reverse vs)
        s2 = show (map Values.typeOf (reverse vs))
    throwError $ EvalCrashError at
      ("missing or ill-typed operand on stack (" ++ s1 ++ " : " ++ s2 ++ ")")

{-# SPECIALIZE instr
      :: Stack Value -> Region -> Instr Phrase
      -> (Code Phrase IO -> CEvalT Phrase IO r)
      -> CEvalT Phrase IO r #-}

step :: (Regioned f, MonadRef m, Monad m, Show1 f)
     => Code f m -> (Code f m -> CEvalT f m r) -> CEvalT f m r
step (Code _ []) _ = error "Cannot step without instructions"
step (Code vs (e:es)) k = do
  -- traceM $ "step: " ++ showsPrec1 11 e ""
  step_work vs (region e) (value e) $ k . (codeInstrs <>~ es)

{-# SPECIALIZE step
      :: Code Phrase IO -> (Code Phrase IO -> CEvalT Phrase IO r)
      -> CEvalT Phrase IO r #-}

eval :: (Regioned f, MonadRef m, Monad m, Show1 f)
     => Code f m -> CEvalT f m (Stack Value)
eval c@(Code vs es) = case es of
  [] -> pure vs
  t@(value -> Trapping msg) : _ ->
    throwError $ EvalTrapError (region t) msg
  _ -> step c eval

{-# SPECIALIZE eval
      :: Code Phrase IO -> CEvalT Phrase IO (Stack Value) #-}

{- Functions & Constants -}

invoke :: (Regioned f, MonadRef m, Monad m, Show1 f)
       => IntMap (ModuleInst f m)
       -> ModuleInst f m
       -> ModuleFunc f m
       -> [Value]
       -> EvalT m [Value]
invoke mods inst func vs = do
  let (at, inst') = case func of
        Func.AstFunc _ i f -> (region f, mods^?!ix i)
        _ -> (def, inst)
  reverse <$> runReaderT
    (eval (Code (reverse vs) [Invoke func @@ at]))
    (newConfig mods inst')
  -- jww (2018-11-01): How do we detect stack overflow?
  -- reverse (eval c) with Stack_overflow ->
  --   Exhaustion.error at "call stack exhausted"

{-# SPECIALIZE invoke
      :: IntMap (ModuleInst Phrase IO)
      -> ModuleInst Phrase IO
      -> ModuleFunc Phrase IO
      -> [Value]
      -> EvalT IO [Value] #-}

invokeByName :: (Regioned f, MonadRef m, Monad m, Show1 f)
             => IntMap (ModuleInst f m) -> ModuleInst f m -> Text -> [Value]
             -> EvalT m [Value]
invokeByName mods inst name vs = do
  -- traceM $ "invokeByName " ++ unpack name
  case inst ^. miExports.at name of
    Just (ExternFunc f) -> invoke mods inst f vs
    e -> throwError $ EvalCrashError def $
      "Cannot invoke export " ++ unpack name ++ ": " ++ show e

{-# SPECIALIZE invokeByName
      :: IntMap (ModuleInst Phrase IO)
      -> ModuleInst Phrase IO -> Text -> [Value] -> EvalT IO [Value] #-}

getByName :: (Regioned f, Show1 f, MonadRef m, Monad m)
          => ModuleInst f m -> Text -> EvalT m Value
getByName inst name = case inst ^. miExports.at name of
  Just (ExternGlobal g) -> lift $ getMut (g^.Global.giContent)
  e -> throwError $ EvalCrashError def $
    "Cannot get exported global " ++ unpack name ++ ": " ++ show e

{-# SPECIALIZE getByName
      :: ModuleInst Phrase IO -> Text -> EvalT IO Value #-}

evalConst :: (Regioned f, MonadRef m, Monad m, Show1 f)
          => IntMap (ModuleInst f m)
          -> ModuleInst f m -> Expr f -> EvalT m Value
evalConst mods inst expr = do
  xs <- runReaderT
    (eval (Code [] (map plain (value expr))))
    (newConfig mods inst)
  case xs of
    [v] -> pure v
    _ -> throwError $
      EvalCrashError (region expr) "wrong number of results on stack"

i32 :: Monad m => Value -> Region -> EvalT m Int32
i32 v at = case v of
  I32 i -> pure i
  _ -> throwError $ EvalCrashError at "type error: i32 value expected"

{- Modules -}

createFunc :: (Regioned f, Monad m)
           => ModuleInst f m -> ModuleRef -> f (Func f)
           -> EvalT m (ModuleFunc f m)
createFunc inst ref f = do
  ty <- type_ inst (value f^.funcType)
  pure $ Func.alloc ty ref f

createHostFunc :: FuncType -> ([Value] -> [Value]) -> ModuleFunc f m
createHostFunc = Func.allocHost

createHostFuncEff :: FuncType -> ([Value] -> m [Value]) -> ModuleFunc f m
createHostFuncEff = Func.allocHostEff

createTable :: (Regioned f, MonadRef m, Monad m)
            => Table f -> EvalT m (TableInst m (ModuleFunc f m))
createTable tab = do
  eres <- lift $ runExceptT $ Table.alloc (value tab)
  case eres of
    Left err -> throwError $ EvalTableError (region tab) err
    Right g  -> pure g

liftMem :: Monad m
        => Region -> ExceptT Memory.MemoryError m a -> EvalT m a
liftMem at act = do
  eres <- lift $ runExceptT act
  case eres of
    Left err -> throwError $ EvalMemoryError at err
    Right x  -> pure x

createMemory :: (Regioned f, MonadRef m, Monad m)
             => Memory f -> EvalT m (Memory.MemoryInst m)
createMemory mem = liftMem (region mem) $ Memory.alloc (value mem)

createGlobal :: (Regioned f, MonadRef m, Monad m, Show1 f)
             => IntMap (ModuleInst f m) -> ModuleInst f m -> f (Global f)
             -> EvalT m (Global.GlobalInst m)
createGlobal mods inst x@(value -> glob) = do
  v <- evalConst mods inst (glob^.globalValue)
  eres <- lift $ runExceptT $ Global.alloc (glob^.globalType) v
  case eres of
    Left err -> throwError $ EvalGlobalError (region x) err
    Right g  -> pure g

createExport :: (Regioned f, Monad m)
             => ModuleInst f m -> f (Export f) -> EvalT m (ExportInst f m)
createExport inst (value -> ex) = do
  ext <- case ex^.exportDesc of
    FuncExport   x -> ExternFunc   <$> func inst x
    TableExport  x -> ExternTable  <$> table inst x
    MemoryExport x -> ExternMemory <$> memory inst x
    GlobalExport x -> ExternGlobal <$> global inst x
  pure $ M.singleton (ex^.exportName) ext

initTable :: (Regioned f, Show1 f, MonadRef m, Monad m)
          => IntMap (ModuleInst f m) -> ModuleInst f m -> f (TableSegment f)
          -> EvalT m ()
initTable mods inst s@(value -> seg) = do
  tab <- table inst (seg^.segmentIndex)
  c <- evalConst mods inst (seg^.segmentOffset)
  offset <- i32 c (region (seg^.segmentOffset))
  let end_ = offset + fromIntegral (length (seg^.segmentInit))
  bound <- lift $ Table.size tab
  when (bound < end_ || end_ < offset) $
    throwError $ EvalLinkError (region s) "elements segment does not fit table"
  fs <- traverse (func inst) (seg^.segmentInit)
  lift $ Table.blit tab offset (V.fromList fs)

initMemory :: (Regioned f, Show1 f, MonadRef m, Monad m)
           => IntMap (ModuleInst f m) -> ModuleInst f m -> f (MemorySegment f)
           -> EvalT m ()
initMemory mods inst s@(value -> seg) = do
  mem <- memory inst (seg^.segmentIndex)
  c <- evalConst mods inst (seg^.segmentOffset)
  offset' <- i32 c (region (seg^.segmentOffset))
  let offset = i64_extend_u_i32 (fromIntegral offset')
  let end_ = offset + fromIntegral (B.length (seg^.segmentInit))
  bound <- lift $ Memory.bound mem
  when (fromIntegral bound < end_ || end_ < fromIntegral offset) $
    throwError $ EvalLinkError (region s) "data segment does not fit memory"
  liftMem (region s) $
    Memory.storeBytes mem (fromIntegral offset)
                      (V.fromList (B.unpack (seg^.segmentInit)))

addImport :: (Regioned f, MonadRef m, Monad m)
          => ModuleInst f m
          -> Extern f m
          -> f (Import f)
          -> EvalT m (ModuleInst f m)
addImport inst ext im = do
  typ <- lift $ externTypeOf ext
  if not (matchExternType typ (importTypeFor (inst^.miModule) (value im)))
    then throwError $ EvalLinkError (region im) "incompatible import type"
    else pure $ case ext of
      ExternFunc func   -> inst & miFuncs    %~ (func :)
      ExternTable tab   -> inst & miTables   %~ (tab  :)
      ExternMemory mem  -> inst & miMemories %~ (mem  :)
      ExternGlobal glob -> inst & miGlobals  %~ (glob :)

resolveImports :: (Regioned f, Show1 f, MonadRef m, Monad m)
               => Map Text ModuleRef
               -> IntMap (ModuleInst f m)
               -> ModuleInst f m
               -> EvalT m (ModuleInst f m)
resolveImports names mods inst = flip execStateT inst $
  forM_ (reverse (inst^.miModule.moduleImports)) $ \im -> do
    let im' = value im
    case M.lookup (im'^.importModule) names of
      Nothing -> throwError $ EvalLinkError (region im) $
        "Missing module for import: " ++ show (value im)
      Just ref -> case IM.lookup ref mods of
        Nothing -> throwError $ EvalLinkError (region im) $
          "Missing module for import: " ++ show (value im)
        Just src ->
          case M.lookup (im'^.importItem) (src^.miExports) of
            Nothing -> throwError $ EvalLinkError (region im) $
              "Missing extern for import: " ++ show (value im)
            Just ext -> do
              m <- get
              m' <- lift $ addImport m ext im
              put m'

initialize :: (Regioned f, Show1 f, MonadRef m, Monad m)
           => f (Module f)
           -> Map Text ModuleRef
           -> IntMap (ModuleInst f m)
           -> EvalT m (ModuleRef, ModuleInst f m)
initialize (value -> mod) names mods = do
  inst <- resolveImports names mods (emptyModuleInst mod)
  let ref = nextKey mods
  inst' <- flip execStateT inst $ do
    ts <- lift $ traverse createTable (mod^.moduleTables)
    fs <- lift $ traverse (createFunc inst ref) (mod^.moduleFuncs)
    ms <- lift $ traverse createMemory (mod^.moduleMemories)
    gs <- lift $ traverse (createGlobal mods inst) (mod^.moduleGlobals)

    miFuncs    %= (<> (fs & traverse.Func._AstFunc._2 .~ ref))
    miTables   %= (<> ts)
    miMemories %= (<> ms)
    miGlobals  %= (<> gs)

    inst1 <- get
    let mods1 = IM.insert ref inst1 mods
    forM_ (mod^.moduleElems) $ lift . initTable mods1 inst1
    forM_ (mod^.moduleData)  $ lift . initMemory mods1 inst1

    inst2 <- get
    es <- lift $ traverse (createExport inst2) (mod^.moduleExports)
    miExports .= mconcat es

    inst3 <- get
    forM_ (mod^.moduleStart) $ \start -> do
      f <- lift $ func inst3 start
      lift $ invoke (IM.insert ref inst3 mods) inst3 f []

  pure (ref, inst')

nextKey :: IntMap a -> IM.Key
nextKey m = go (max 1 (IM.size m))
 where
  go k | IM.member k m = go (succ k)
       | otherwise = k
