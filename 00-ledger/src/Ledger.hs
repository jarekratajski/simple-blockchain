{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module Ledger where

import qualified Control.Monad       as CM
import qualified Data.Atomics        as A
import qualified Data.ByteString     as BS
import qualified Data.Sequence       as Seq
import qualified Data.Text           as T
import           RIO
import           System.Log.Logger   as Log
import qualified System.Random       as Random
import qualified UnliftIO.Concurrent as CC
import qualified UnliftIO.IORef      as IOR
import qualified UnliftIO.MVar       as MV
------------------------------------------------------------------------------
import           Config
import           Logging

type Ledgerable a = Show a

data Ledger a = Ledger
  { lContents
      :: IO (Seq.Seq a)
  , lCommit
      :: Config
      -> a
      -> IO ()
  , lModify
      :: Int
      -> a
      -> IO ()
  , lCheck
      :: IO (Maybe T.Text)
  , fromByteString
      :: BS.ByteString
      -> a
  }

createLedgerCAS
  :: Ledgerable a
  => IO (Maybe T.Text)
  -> (BS.ByteString -> a)
  -> IO (Ledger a)
createLedgerCAS ck fbs = do
  r <- IOR.newIORef Seq.empty
  return Ledger
    { lContents = IOR.readIORef r
    , lCommit   = \_ a -> A.atomicModifyIORefCAS_ r $ \existing -> existing Seq.|> a
    , lModify   = \i a -> A.atomicModifyIORefCAS_ r $ \existing -> Seq.update i a existing
    , lCheck    = ck
    , fromByteString  = fbs
    }

createLedgerLocked
  :: Ledgerable a
  => IO (Maybe T.Text)
  -> (BS.ByteString -> a)
  -> IO (Ledger a)
createLedgerLocked ck fbs = do
  mv <- MV.newMVar Seq.empty
  return Ledger
    { lContents = MV.readMVar mv
    , lCommit = \e a -> do
        s <- MV.takeMVar mv
        CM.when (cDOSEnabled (getConfig e)) $ do
          d <- Random.randomRIO (cDOSRandomRange (getConfig e))
          CM.when (d == cDOSRandomHit (getConfig e)) $ do
            Log.infoM lLEDGER "BEGIN commitToLedger DOS"
            CC.threadDelay (1000000 * cDOSDelay (getConfig e))
            Log.infoM lLEDGER "END commitToLedger DOS"
        MV.putMVar mv (s Seq.|> a)
    , lModify = \i a -> do
        s <- MV.takeMVar mv
        MV.putMVar mv (Seq.update i a s)
    , lCheck = ck
    , fromByteString = fbs
    }
