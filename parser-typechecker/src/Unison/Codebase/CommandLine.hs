{-# LANGUAGE DoAndIfThenElse     #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.Codebase.CommandLine (main) where

import           Control.Concurrent           (forkIO)
import           Control.Exception            (catch, finally)
import           Control.Monad                (forM_, forever, liftM2,
                                               void, when)
import           Control.Monad.STM            (STM, atomically)
import           Data.Foldable
import           Data.IORef                   (IORef, newIORef, writeIORef)
import           Data.List
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
-- import           Data.String
-- import           Data.Strings
import           Data.Text                    (Text, pack, unpack)
import qualified Data.Text.IO
import qualified System.Console.ANSI          as Console
import           System.FilePath              (FilePath)
import           System.IO.Error              (isEOFError)
-- import qualified Text.Read                    as Read
import           Unison.Codebase              (Codebase)
import qualified Unison.Codebase              as Codebase
import           Unison.Codebase.Branch       (Branch)
import qualified Unison.Codebase.Branch       as Branch
import           Unison.Codebase.Name         (Name)
import           Unison.Codebase.Runtime      (Runtime)
import qualified Unison.Codebase.Runtime      as RT
import qualified Unison.Codebase.Watch        as Watch
import           Unison.FileParsers           (parseAndSynthesizeFile)
import           Unison.Parser                (PEnv)
import qualified Unison.Parser                as Parser
import           Unison.PrintError            (parseErrorToAnsiString,
                                               prettyTopLevelComponents,
                                               printNoteWithSourceAsAnsi)
import           Unison.Result                (Result (Result))
import qualified Unison.Result                as Result
import qualified Unison.Typechecker.Context   as C
import qualified Unison.UnisonFile            as UF
import qualified Unison.Util.ColorText        as Color
-- import qualified Unison.Util.Menu             as Menu
import           Unison.Util.Monoid
import           Unison.Util.TQueue           (TQueue)
import qualified Unison.Util.TQueue           as TQueue
import           Unison.Var                   (Var)
import qualified Data.Map as Map

data Event
  = UnisonFileChanged FilePath Text
  | UnisonBranchChanged (Set Name)
  | EOF

allow :: FilePath -> Bool
allow = liftM2 (||) (".u" `isSuffixOf`) (".uu" `isSuffixOf`)

main :: forall v a. Var v => FilePath -> Name -> Maybe FilePath -> IO (Runtime v) -> Codebase IO v a -> IO ()
main dir currentBranchName initialFile startRuntime codebase = do
  queue <- TQueue.newIO
  lineQueue <- TQueue.newIO
  runtime <- startRuntime
  lastTypechecked <- newIORef (UF.TypecheckedUnisonFile Map.empty Map.empty [])
  let takeActualLine = atomically (takeLine lineQueue)

  -- load initial unison file if specified
  case initialFile of
    Just file | allow file -> do
      text <- Data.Text.IO.readFile file
      atomically . TQueue.enqueue queue $ UnisonFileChanged file text
    _ -> pure ()

  -- enqueue stdin into lineQueue
  void . forkIO . (`catch` eofHandler queue) . forever $
    getChar >>= atomically . TQueue.enqueue lineQueue

  -- watch for .u file changes
  void . forkIO $ do
    watcher <- Watch.watchDirectory dir allow
    forever $ do
      (filePath, text) <- watcher
      atomically . TQueue.enqueue queue $ UnisonFileChanged filePath text

  -- watch for external branch changes
  (cancelExternalBranchUpdates, externalBranchUpdates) <- Codebase.branchUpdates codebase
  void . forkIO . forever $ do
      updatedBranches <- externalBranchUpdates
      atomically . TQueue.enqueue queue . UnisonBranchChanged $ updatedBranches

  -- load current branch from disk
  branch <- Codebase.getBranch codebase currentBranchName
  (`finally` (RT.terminate runtime *> cancelExternalBranchUpdates)) $ case branch of
    Nothing -> do
      selectBranch codebase currentBranchName takeActualLine >>= \case
        Just (name, branch) -> go0 branch name queue lineQueue lastTypechecked runtime
        Nothing -> putStrLn "Exiting."
    Just b  -> go0 b currentBranchName queue lineQueue lastTypechecked runtime
  where
  eofHandler queue e =
    if isEOFError e then (atomically . TQueue.enqueue queue) EOF else ioError e
  go0 :: Branch -> Name -> TQueue Event -> TQueue Char
      -> IORef (UF.TypecheckedUnisonFile v Parser.Ann) -> Runtime v -> IO ()
  go0 branch branchName queue lineQueue lastTypechecked runtime = go branch branchName
    where

    -- print prompt and whatever input was on it / at it
    printPrompt :: Name -> IO ()
    printPrompt branchName = do
      incompleteLine <- atomically . peekIncompleteLine $ lineQueue
      putStr $ "\r" ++ unpack branchName ++ "> " ++ incompleteLine

    handleUnisonFile :: Runtime v -> Codebase IO v a -> PEnv v -> FilePath -> Text -> IO ()
    handleUnisonFile runtime codebase penv filePath src = do
      let Result notes r = parseAndSynthesizeFile penv filePath src
      case r of
        Nothing -> do -- parsing failed
          Console.setTitle "Unison \128721"
          forM_ notes $ \case
            Result.Parsing err ->
              putStrLn $ parseErrorToAnsiString (unpack src) err
            err ->
              error $"I was expecting a parsing error here but got:\n" ++ show err

        Just (errorEnv, r) -> case r of
          Nothing -> do -- typechecking failed
            Console.setTitle "Unison \128721"
            let showNote notes = intercalateMap
                  "\n\n" (printNoteWithSourceAsAnsi errorEnv (unpack src)) (filter notInfo notes)
                notInfo (Result.TypeInfo _) = False
                notInfo _                   = True
            putStrLn . showNote . toList $ notes
          Just unisonFile -> do
            Console.setTitle "Unison ✅"
            putStrLn "✅  Typechecked! Any watch expressions (lines starting with `>`) are shown below.\n"
            let components = [c | (Result.TypeInfo (C.TopLevelComponent c)) <- toList notes ]
            writeIORef lastTypechecked (
              UF.TypecheckedUnisonFile (UF.dataDeclarations unisonFile)
                                       (UF.effectDeclarations unisonFile)
                                       components)
            putStrLn . show . Color.renderDocANSI 6 $
              prettyTopLevelComponents components errorEnv
            RT.evaluate runtime unisonFile codebase

    go :: Branch -> Name -> IO ()
    go branch name = do
      printPrompt name

      -- wait for new lines from user or asynchronous events from filesystem
      TQueue.raceIO (TQueue.peek queue) (awaitCompleteLine lineQueue) >>= \case
        Right _ -> processLine branch name
        Left _ -> atomically (TQueue.dequeue queue) >>= \case
          EOF -> putStrLn "^D"
          UnisonFileChanged filePath text -> do
            Console.setTitle "Unison"
            Console.clearScreen
            Console.setCursorPosition 0 0
            handleUnisonFile runtime codebase Parser.penv0 filePath text -- todo: don't use penv0
            go branch name
          UnisonBranchChanged branches ->
            if Set.member name branches then do
              b' <- Codebase.getBranch codebase name
              case b' of
                Just b' -> do
                  when (branch /= b') $ do
                    putStrLn "I've merged some external changes to the branch."
                    putStrLn $ "TODO: tell the user what changed as a result of the merge"
                  go b' name
                Nothing -> do
                  putStrLn $ "The current branch was deleted by some external process, "
                              ++ "so I'm going to re-save what I have in memory."
                  branch' <- mergeBranchAndShowDiff codebase name branch
                  go branch' name
            else go branch name

    -- Looks at `lastTypechecked` for matching definitions and lets the user
    -- add them to the codebase. Present the user with a menu if args doesn't
    -- match what's in lastTypechecked.
    addDefinitions :: Branch -> Name -> [String] -> IO ()
    addDefinitions _branch _name args = case args of
      [] -> error "todo"
      _  -> error "todo"

    -- addMenu :: _ -> IO _
    -- addMenu topLevels =

    processLine :: Branch -> Name -> IO ()
    processLine branch name = do
      let takeActualLine = atomically $ takeLine lineQueue
      (Line line) <- takeActualLine
      case words line of
        "add" : args -> addDefinitions branch name args

        ["branch"] -> do
          branches <- sort <$> Codebase.branches codebase
          forM_ branches $ \name' ->
            if name' == name then putStrLn $ " * " ++ unpack name'
                             else putStrLn $ "   " ++ unpack name'
          -- idea: could instead prompt user and read directly from lineQueue to handle
          go branch name

        ["branch", name'] -> do
          branch' <- selectBranch codebase (pack name') takeActualLine
          case branch' of
            Just (name, branch) -> go branch name
            Nothing -> putStrLn "Ok, nevermind." *> go branch name

        ["fork", newName0] -> do
          let newName = pack newName0
          branchExists <- Codebase.branchExists codebase newName
          if branchExists then do
            putStrLn $ "Sorry, a branch by that name already exists."
            go branch name
          else do
            branch' <- mergeBranchAndShowDiff codebase newName branch
            go branch' newName

        ["merge", from] -> do
          branch' <- Codebase.getBranch codebase $ pack from
          case branch' of
            Nothing -> do
              putStrLn $ "Sorry, I can't find a branch by that name to merge from."
              go branch name
            Just branch' -> do
              branch'' <- mergeBranchAndShowDiff codebase name branch'
              putStrLn $ "Flawless victory!"
              go branch'' name

        -- rename a term/type/... in the current branch
        ["rename", from, to] ->
          let terms = Branch.termsNamed (pack from) branch
              types = Branch.typesNamed (pack from) branch
              renameTerm branch = do
                let branch' = Branch.renameTerm (pack from) (pack to) branch
                mergeBranchAndShowDiff codebase name branch'
              renameType branch = do
                let branch' = Branch.renameType (pack from) (pack to) branch
                mergeBranchAndShowDiff codebase name branch'
              go' b = go b name
          in case (toList terms, toList types) of
            ([], []) -> putStrLn "I couldn't find anything by that name."
            ([_term], []) -> renameTerm branch >>= go'
            ([], [_typ]) -> renameType branch >>= go'
            ([_term], [_typ]) -> do
              putStrLn "Do you want to rename the [term], [type], [both], or [neither]?"
              putStr ">> "
              (atomically . fmap words . fmap getKeyboardInput . takeLine) lineQueue >>= \case
                ["term"] -> renameTerm branch >>= go'
                ["type"] -> renameType branch >>= go'
                ["both"] -> renameTerm branch >>= renameType >>= go'
                _ -> go' branch
            (_terms, _types) -> do
              -- idea: print out _terms and _types, so user can view them
              putStrLn $ "There's more than one thing called " ++ from ++ "."
              putStrLn $ "Use `> <command to resolve conflicts> unname " ++ from ++ "` to resolve conflicts, then try again."
              go' branch
        [] -> go branch name
        x -> putStrLn ("I don't know how to " ++ unwords x ++ ".") *> go branch name

-- should never block
peekIncompleteLine :: TQueue Char -> STM String
peekIncompleteLine q = TQueue.tryPeekWhile (not . (`elem` "\n")) q

data KeyboardInput
  = Line { getKeyboardInput :: String }
  | Tab { getKeyboardInput :: String }
  | Esc

controlChars :: [Char]
controlChars = ['\LF','\HT','\ESC']

-- block until a full line is available
takeLine :: TQueue Char -> STM KeyboardInput
takeLine q = do
  line <- TQueue.takeWhile (not . (`elem` controlChars)) q
  ch <- TQueue.dequeue q
  case ch of
    '\LF' -> pure (Line line)
    '\HT' -> pure (Tab line)
    '\ESC' -> pure Esc
    x ->
      if x `elem` controlChars
      then error $ "control character " ++ show x ++ "not matched in takeLine"
      else error "unpossibility in takeLine"

-- blocks until a line ending in a control char is available
awaitCompleteLine :: TQueue Char -> STM ()
awaitCompleteLine q = void $ TQueue.peekWhile (not . (`elem` controlChars)) q

-- Merges `branch` into any the branch `name`, creating it if necessary.
mergeBranchAndShowDiff :: Monad m => Codebase m v a -> Name -> Branch -> m Branch
mergeBranchAndShowDiff codebase targetName sourceBranch = do
  branch' <- Codebase.mergeBranch codebase targetName sourceBranch
  -- when (branch' /= branch) $
  --   putStrLn $ "Some extra stuff appeared right when you forked, "
  --           ++ "and I went ahead and smashed it all together for you!"
  pure branch'

selectBranch :: a
selectBranch = error "todo"
