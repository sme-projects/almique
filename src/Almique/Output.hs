{-# LANGUAGE ScopedTypeVariables #-}

module Almique.Output
  ( execPlan
  , makePlan
  ) where

import Text.PrettyPrint
import Control.Monad.Reader
import Data.Maybe (fromMaybe, isNothing)

import System.Directory

import Language.SMEIL
import Language.SMEIL.VHDL

import Debug.Trace

type PortList = Doc
type PortMap = Doc
type SensitivityList = Doc
type SignalList = Doc
type FunBody = Doc
type ArchitectureBody = Doc
type GenericDefs = Doc

-- TODO: Split into two modules: One for doing the file handling stuff and one
-- for rendering the actual output

data OutputFile = OutputFile { dir :: FilePath
                             , file :: FilePath
                             , output :: Doc
                             }
                  deriving Show

type OutputPlan = [OutputFile]

concatPath :: OutputFile -> FilePath
concatPath OutputFile { dir = d
                      , file = f
                      } = d ++ "/" ++ f

-- FIXME: This is really bad. Ideally, we shouldn't have to do this kind of
-- cross referencing when generating VHDL from our AST. Maybe a symptom of
-- poor data structure design choices?
findPred :: forall a b. (Network -> [a])
            -> (a -> Bool)
            -> (a -> b)
            -> Reader Network (Maybe b)
findPred n p f = asks n >>= pure . locate
  where
    locate :: [a] -> Maybe b
    locate [] = Nothing
    locate (e:es)
      | p e = Just $ f e
      | otherwise = locate es

-- ppIf :: Bool -> Doc -> Doc
-- ppIf c d = if c then d else empty

entity :: Ident -> PortList -> GenericDefs -> Doc
entity s d g = pp Entity <+> text s <+> pp Is
  $+$ indent ((if isEmpty g then empty else pp Generic <+> parens g <> semi)
              $+$ (pp Port <+> parens
                   ( indent (
                       d
                       $+$ text "rst: in std_logic;"
                       $+$ text "clk: in std_logic"
                       $+$ blank)) <> semi))
  $+$ pp End <+> text s <> semi

funPortNames :: (Ident, Ident) -> Reader Network [Doc]
funPortNames (n, t) = do
  -- FIXME: This simply returns nothing if the bus referred to
  -- 1) Do static checking in Binder to make sure this cannot fail
  ps <- findPred busses (\bn -> t == busName bn) busPorts
  return $ map (\s -> underscores [n,s]) (fromMaybe [] ps)

-- |Generates a list of input and output ports
entPorts :: Function -> Reader Network Doc
entPorts Function { funInports = ins
                  , funOutports = outs } = vcat <$> sequence (map (ports Out) outs
                                                              ++ map (ports In) ins)
  where
    ports :: VHDLKw -> (Ident, Ident) -> Reader Network Doc
    ports d ps = do
      names <- funPortNames ps
      bt <- fromMaybe AnyType <$> findPred busses (\bn -> fst ps == busName bn) busDtype
      return $ vcat $
        map (\s -> s <> colon <+> pp d <+> pp bt <> semi) names

-- TODO: Support other types than integer here
entGenerics :: Function -> Doc
entGenerics Function { funParams = p } =
  vcat $ punctuate comma $ map (\v -> pp v <> colon <+> pp Integer) (getVars p)
  where
    getVars vs = [ v | (Decl v _ _) <- vs ]

architecture :: Ident -> SignalList -> Doc -> Doc
architecture s signals body = pp Architecture <+> text "RTL" <+> pp Of <+> text s <+> pp Is
  $+$ indent signals
  $+$ pp Begin
  $+$ indent body
  $+$ pp EndArchitecture <> semi

makeVarVal :: Maybe Expr -> Doc
makeVarVal v = fromMaybe empty ((\e -> space <> pp Gets <+> pp e) <$> v)

makeVar :: Decl -> Doc
makeVar (Decl (NamedVar ty n) t v) = pp Variable <+> text n <> colon
  <+> text "type" <> makeVarVal v <> semi
makeVar (Decl (ConstVar ty n) t v) = pp Constant <+> text n <> colon
  <+> text "type" <> makeVarVal v <> semi

process :: Ident -> FunBody -> SensitivityList -> Reader Network Doc
process fname body sensitivity = do
  -- XXX: Why not pass function from caller?
  vars <- fromMaybe [] <$> findPred functions (\s -> fname == funName s) locals
  return (pp Process <+> parens ( empty $+$ sensitivity )
          -- TODO: Split definitions on constants and variables
          $+$ vcat (map makeVar vars)
          $+$ pp Begin
          $+$ indent (pp If <+> text "rst = '1'" <+> pp Then
                      $+$ indent (text "-- Reset stuff goes here")
                      $+$ pp Elsif <+> pp (RisingEdge (text "clk")) <+> pp Then
                      $+$ indent body
                      $+$ pp EndIf <> semi
                     )
          $+$ pp EndProcess <> semi)

instPortMap :: (Ident, Ident) -> Reader Network Doc
instPortMap ps = do
  bus <- findPred busses (\s -> snd ps == busName s) id
  asTopPorts <- fromMaybe (return []) (topBusPorts <$> bus)
  asFunPorts <- funPortNames ps
  return $ vcat $ map (\(a, b) -> a <+> pp MapTo <+> b <> comma) (zip asFunPorts (map fst asTopPorts))
  -- Format fun bus name => top lvl name

instParamsMap :: [(Ident, PrimVal)] -> Doc
-- FIXME: This will produce non-working VHDL code because generics without a
-- default value are left uninstantiated. Either set Decls with Nothing
-- expression to 0 by default or assign a default value to generics in
-- entities generated from external functions
instParamsMap ps = vcat $ commas $ filter (not.isEmpty) $ map (\(i, e) ->
                                          if e /= EmptyVal then
                                             text i <+> pp MapTo <+> pp e
                                          else empty) ps

inst :: Instance -> Reader Network Doc
inst Instance { instName = name
              , instFun = fun
              , inBusses = inbus
              , outBusses = outbus
              , instParams = params
              } = do
  funDef <- findPred functions (\n -> funName n == fun) id
  let funPorts = concat $ fromMaybe [] $ sequence [funInports <$> funDef, funOutports <$> funDef]
  portMaps <- vcat <$> mapM instPortMap funPorts
  let genMaps = instParamsMap params
  return $ text name <> colon <+> pp Entity <+> pp Work <> text "." <> text fun
    $+$ (if isEmpty genMaps then empty else pp GenericMap <+> parens genMaps)
    $+$ pp PortMap <+> parens (indent ( portMaps
                                        $+$ clockedMap
                                      )) <> semi

topBusPorts :: Bus -> Reader Network [(Doc, Doc)]
topBusPorts b = do
  nn <- asks netName
  let bn = busName b
  let bp = busPorts b
  let bt = busDtype b
  return $ map (\s -> (underscores [nn, bn, s], pp bt)) bp

topPorts :: Reader Network Doc
topPorts = do
  sigdefs <- asks busses >>= mapM topBusPorts
  return $ sigDefs $ concat sigdefs
  where
    sigDefs :: [(Doc, Doc)] -> Doc
    sigDefs = vcat . map (\(s, t) -> s  <> colon <+> pp InOut <+> t <> semi)

--topPortMap :: Reader Network Doc

makeTopLevel :: Reader Network Doc
makeTopLevel = do
  nname <- asks netName
  ports <- topPorts
  insts <- asks instances >>= mapM inst
  return $ entity nname ports empty
    $+$ architecture nname (text "-- signals") (vcat insts)
{-|

Toplevel: in entity, for every bus referenced by instances

-}

vhdlExt :: FilePath -> FilePath
vhdlExt = flip (++) ".vhdl"

makeFun :: Function -> Reader Network OutputFile
makeFun f = do
  let fname = funName f
  let generics = entGenerics f
  ports <- entPorts f
  procc <- process fname (pp (funBody f))(vcat [ text "clk" <> comma , text "rst" ])
  return OutputFile { dir = ""
                    , file = vhdlExt fname
                    , output = header
                      $+$ entity fname ports generics
                      $+$ architecture fname empty procc
                    }

makeNetwork :: Reader Network OutputPlan
makeNetwork = do
  nn <- asks netName
  funs <- asks functions
  outFuns <- mapM makeFun funs
  tl <- makeTopLevel
  return $  OutputFile { dir = ""
                       , file = vhdlExt nn
                       , output = header $+$ tl
                       }
    : OutputFile { dir = ""
                 , file = vhdlExt "csv_util"
                 , output = csvUtil
                 }
    : OutputFile { dir = ""
                 , file = vhdlExt "sme_types"
                  , output = smeTypes
                 }
    : outFuns

makePlan :: Network -> OutputPlan
makePlan = runReader makeNetwork

execPlan :: OutputPlan -> IO ()
execPlan = mapM_ (makeOutput . spliceDir)
  where
    makeOutput :: OutputFile -> IO ()
    makeOutput outf@OutputFile { dir = d
                               , output = o
                               } = do
      createDirectoryIfMissing True d
      let path = concatPath outf
      exists <- doesFileExist path
      if exists then
        fail $ "File " ++ path ++ " already exists"
        else
        writeFile path (render o)

    spliceDir :: OutputFile -> OutputFile
    spliceDir x = x { dir = "output" }
