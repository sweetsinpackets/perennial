module Interpreter
  ( interpret
  ) where

import Control.Monad (void)

import Proc
import qualified FilesysOps
import qualified DataOps
import qualified BaseLayer

import Filesys.Generic
import Control.Monad.IO.Class
import Control.Concurrent.Forkable
import Lib (coerceRet, coerceVoid)

interpret :: (MonadFilesys m, MonadIO m, ForkableMonad m) =>
             Coq_proc (BaseLayer.Op a) x -> m x
interpret (Call (BaseLayer.FilesysOp op)) = coerceRet $ FilesysOps.interpret op
interpret (Call (BaseLayer.DataOp op)) = coerceRet . liftIO $ DataOps.interpret op
interpret (Ret x) = return x
interpret (Bind x f) = interpret x >>= interpret . f
interpret (Spawn x) = do
  _ <- forkIO (void $ interpret x)
  coerceVoid $ return ()
interpret (Loop body x0) = do
  x <- interpret $ body x0
  case x of
    ContinueOutcome t -> interpret (Loop body t)
    DoneWithOutcome r -> return r