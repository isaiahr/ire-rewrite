module Pipeline.Pipeline (pipelineIO) where

{-
Pipeline.hs - functions for whole-program compilation

-}

import System.IO
import System.Exit
import System.IO.Error
import System.Console.ANSI
import Control.Monad.State
import Control.Exception (evaluate)
import Data.List

import Common.Common
import Common.Pass
import Parser.Lexer
import Parser.Parser
import AST.AST
import Pass.YieldInjection
import Pass.Typer
import Pass.Namer
import Pass.NameTyper
import Pass.TypeChecker
import IR.DirectCall
import IR.Lowering
import IR.HeapConversion
import IR.LambdaLift
import IR.CodeGen
import Pipeline.Relations
import Pipeline.Target

import Debug.Trace

data PFile = PFile {
    pLocation :: String,
    pObjLocation :: String,
    pExports :: [(String, Type)],
    pImports :: [String],
    pMsgs :: Messages,
    pFileInfo :: FileInfo
} 
instance Show PFile where
    show pf = show (pLocation pf) <> show (pExports pf) <> show (pImports pf)


-- the "pure" pipeline for compiling one target
pipeline y x fi =  passLexer >>> -- plaintext -> tokens
              passParse >>> -- tokens -> ast<string>
              passYieldInj >>> -- ast<string> -> ast<string>
              passName y >>> -- ast<string> -> ast<name>
              passType >>> -- ast<name> -> ast<typedname>
              passTypeCheck >>> -- ast<typedname> -> ast<typedname>, ensures type annotation correctness
              passLower x fi >>>  -- ast<typedname> -> IR
              passDCall >>> -- IR -> IR, direct call conversion
              passHConv >>> -- IR -> IR, promote freevars to heap 
              passLLift >>> -- IR -> IR, lift nested functions to top level
              passGenLLVM -- IR -> LLVM
            
pipelineIO target filename S_BIN outfile = do
    -- todo target etc etc etc
    files <- importDag filename
    (errs, processed_files) <- execStateT (forM (zip [1 .. (length files)] files) $ (\(idx, x) -> do 
        liftIO $ putStr $ "[" <> show idx <> " of " <> show (length files) <> "] Compiling " <> (uPath x)
        mpfiles <- get
        case mpfiles of
            ([], pfiles) -> do
                epfile <- liftIO $ tryIOError (compile False target x pfiles idx)
                case epfile of 
                    Left err -> do
                        put ([err], pfiles)
                        liftIO $ putStr $ " ["
                        liftIO $ setSGR [SetColor Foreground Dull Red]
                        liftIO $ putStr "Failed" 
                        liftIO $ setSGR [Reset]
                        liftIO $ putStrLn "]" 
                        
                    Right pfile -> do
                        put ([], (pfile:pfiles))
                        liftIO $ putStr $ " ["
                        liftIO $ setSGR [SetColor Foreground Dull Green]
                        liftIO $ putStr "OK" 
                        liftIO $ setSGR [Reset]
                        liftIO $ putStrLn "]" 
            (errs, pfiles) -> do
                liftIO $ putStr $ " ["
                liftIO $ setSGR [SetColor Foreground Dull Yellow]
                liftIO $ putStr "Skipped" 
                liftIO $ setSGR [Reset]
                liftIO $ putStrLn "]" 
                
        )) ([], [])
    if null errs then do
        libs <- getLinkedLibs target
        runLinker target (libs <> (map pObjLocation processed_files)) outfile
    else do 
        forM errs $ \y -> hPutStrLn stderr (ioeGetErrorString y)
        exitFailure
    return $ foldl (<>) mempty (map pMsgs processed_files)
    
pipelineIO target filename stage outfile = do
    files <- importDag filename
    (errs, processed) <- execStateT (forM (zip [1 .. (length files)] files) $ (\(idx, x) -> do 
        liftIO $ putStr $ "[" <> show idx <> " of " <> show (length files) <> "] Compiling " <> (uPath x)
        mpfiles <- get
        case mpfiles of
            ([], pfiles) -> do
                epfile <- liftIO $ tryIOError (compile True target x pfiles idx)
                case epfile of 
                    Left err -> do
                        put ([err], pfiles)
                        liftIO $ putStr $ " ["
                        liftIO $ setSGR [SetColor Foreground Dull Red]
                        liftIO $ putStr "Failed" 
                        liftIO $ setSGR [Reset]
                        liftIO $ putStrLn "]" 
                        
                    Right pfile -> do
                        put ([], (pfile:pfiles))
                        liftIO $ putStr $ " ["
                        liftIO $ setSGR [SetColor Foreground Dull Green]
                        liftIO $ putStr "OK" 
                        liftIO $ setSGR [Reset]
                        liftIO $ putStrLn "]" 
            (errs, pfiles) -> do
                liftIO $ putStr $ " ["
                liftIO $ setSGR [SetColor Foreground Dull Yellow]
                liftIO $ putStr "Skipped" 
                liftIO $ setSGR [Reset]
                liftIO $ putStrLn "]" 
            
        )) ([], [])
    if null errs then do
        let me = last files
        inhandle <- openFile (uPath me) ReadMode
        hSetEncoding inhandle utf8
        contents <- hGetContents inhandle
        contents_sz <- evaluate (length contents)
        hClose inhandle
        let (msg, result) = runPass contents (pipeline1 (importedSymsQ me processed))
        case result of
            Nothing -> ioError (userError $ disp msg)
            Just (AST ds) -> do
                
                let astsyms = map (\(TypedName t (Name s _)) -> (s, t)) (map (\(Plain p) -> p) (map (\d -> identifier d) ds))
                
                let allsyms = (astsyms ++ importedSyms me processed)
                if allsyms /= nub allsyms then
                    ioError (userError "Conflicting symbols")
                                        else 
                    return ()
                if (filter (\s -> s `elem` (map (\(s2, t2) -> s2) allsyms)) (uExports me)) == (uExports me) then
                    return () -- ok, all exports are imported
                                                                                            else 
                    ioError (userError "Exporting symbol not in file")
                let exportedsyms = map (\s -> (filter (\(s2, t) -> s == s2) allsyms) !! 0) (uExports me)
                let astexports = filter (\(s, i) -> s `elem` uExports me) (map (\(TypedName t (Name s i)) -> (s, i)) (map (\(Plain p) -> p) (map (\d -> identifier d) ds)))
                let (msg2, result2) = runPass (AST ds) (pipeline2 astexports FileInfo { fiSrcFileName = (uPath me), fiFileId = (length files)})
                case result2 of
                    Nothing -> ioError (userError $ disp (msg <> msg2))
                    Just y -> do 
                        writeOutput (disp y) outfile target stage
                        return (msg <> msg2)
    else do 
        forM errs $ \y -> hPutStrLn stderr (ioeGetErrorString y)
        exitFailure


pipeline1 x = passLexer >>> 
              passParse >>>
              passYieldInj >>>
              passName x >>>
              passType

-- x = exported syms
pipeline2 x fi = passTypeCheck >>> 
              passLower x fi >>>  
              passDCall >>> 
              passHConv >>>
              passLLift >>>
              passGenLLVM


compile :: Bool -> Target -> UFile -> [PFile] -> Int -> IO PFile
compile dry target file processed idx = do
    inhandle <- openFile (uPath file) ReadMode
    hSetEncoding inhandle utf8
    contents <- hGetContents inhandle
    -- trick. lazy IO is dumb, so we force evaluation to actually close the handle.
    contents_sz <- evaluate (length contents)
    hClose inhandle
    let importedsyms = importedSyms file processed
    let (msg, result) = runPass contents (pipeline1 (importedSymsQ file processed))
    case result of
         Nothing -> ioError (userError $ disp (filterErrs msg))
         Just (AST ds) -> do
             
             let astsyms = map (\(TypedName t (Name s _)) -> (s, t)) (map (\(Plain p) -> p) (map (\d -> identifier d) ds))
             
             let allsyms = (astsyms ++ importedsyms)
             if allsyms /= nub allsyms then
                 ioError (userError "Conflicting symbols")
                                       else 
                 return ()
             if (filter (\s -> s `elem` (map (\(s2, t2) -> s2) allsyms)) (uExports file)) == (uExports file) then
                 return () -- ok, all exports are imported
                                                                                          else 
                 ioError (userError "Exporting symbol not in file")
             let exportedsyms = map (\s -> (filter (\(s2, t) -> s == s2) allsyms) !! 0) (uExports file)
             let astexports = filter (\(s, i) -> s `elem` uExports file) (map (\(TypedName t (Name s i)) -> (s, i)) (map (\(Plain p) -> p) (map (\d -> identifier d) ds)))
             if dry then
                 return $ PFile {
                     pLocation = (uPath file),
                     pObjLocation = "", 
                     pExports = exportedsyms, 
                     pImports = (uImports file), 
                     pMsgs = msg,
                     pFileInfo = FileInfo { fiSrcFileName = (uPath file), fiFileId = idx}
                 }
             else do
                 let (msg2, result2) = runPass (AST ds) (pipeline2 astexports FileInfo { fiSrcFileName = (uPath file), fiFileId = idx})
                 case result2 of
                     Nothing -> ioError (userError $ disp (filterErrs (msg <> msg2)))
                     Just y -> do 
                         outfile <- getTempFile
                         writeOutput (disp y) outfile target S_OBJ
                         return $ PFile {
                             pLocation = (uPath file),
                             pObjLocation = outfile, 
                             pExports = exportedsyms, 
                             pImports = (uImports file), 
                             pMsgs = (msg <> msg2),
                             pFileInfo = FileInfo { fiSrcFileName = (uPath file), fiFileId = idx}
                         }
    
        
importedSyms :: UFile -> [PFile] -> [(String, Type)]
importedSyms ufile allpfiles = foldl (++) [] $ map pExports (filter (\p -> (pLocation p) `elem` (uImports ufile)) allpfiles)

importedSymsQ :: UFile -> [PFile] -> [(String, Type, FileInfo)]
importedSymsQ ufile allpfiles = foldl (++) [] $ map (\f -> mgc (pExports f) (pFileInfo f) ) (filter (\p -> (pLocation p) `elem` (uImports ufile)) allpfiles)
    where mgc ((a, b):ds) c = (a, b, c): (mgc ds c)
          mgc [] c = []
