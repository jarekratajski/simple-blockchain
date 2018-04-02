> {-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
>
> {-# LANGUAGE OverloadedStrings #-}
>
> module BC where
>
> import qualified Control.Monad                        as CM
> import qualified Crypto.Hash.SHA256                   as SHA
> import qualified Data.Atomics                         as A
> import qualified Data.ByteString                      as BS
> import qualified Data.ByteString.Builder              as BSB
> import qualified Data.ByteString.Char8                as BSC8
> import qualified Data.ByteString.Lazy.Char8           as BSLC8
> import qualified Data.Hex                             as Hex
> import qualified Data.IORef                           as IOR
> import           Data.Monoid                          ((<>))
> import qualified Data.Text                            as T
> import qualified Data.Text.Encoding                   as TE
> import qualified Network.HTTP.Types                   as HTTP
> import qualified Network.HTTP.Client                  as HTTP
> import qualified Network.Wai                          as Wai
> import qualified Network.Wai.Handler.Warp             as Wai
> import qualified Network.Wai.Middleware.RequestLogger as Wai
> import qualified System.Log.Logger                    as Log

> lBC :: String
> lBC = "BC"

https://hackernoon.com/learn-blockchains-by-building-one-117428612f46
https://github.com/dvf/blockchain

> data Block = Block
>   { bPreviousHash :: BHash
>   , bIndex        :: BIndex
>   , bTimestamp    :: BTimestamp
>   , bTransactions :: [Transaction]
>   , bProof        :: Proof
>   } deriving (Eq, Read, Show)

> type BHash       = BS.ByteString
> type BIndex      = Int
> type BTimestamp  = T.Text
> type Transaction = T.Text
> type Proof       = Integer

> genesisBlock :: Block
> genesisBlock = Block
>   { bPreviousHash = "1"
>   , bIndex        = 0
>   , bTimestamp    = "2018-04-01"
>   , bTransactions = []
>   , bProof        = 100
>   }

> type Address = T.Text
> type Chain   = [Block]
>
> data Env = Env
>   { eCurrentTransactions :: [Transaction]
>   , eChain               :: Chain
>   , eNodes               :: [Address]
>   , eThisNode            :: Address
>   } deriving Show

> type IORefEnv = IOR.IORef Env

> initialize :: Address -> IO IORefEnv
> initialize thisNode =
>   IOR.newIORef (Env [] [genesisBlock] [] thisNode)

> -- | Add a new node to the list of nodes
> --   Example argument: "http://192.168.0.5:5000"
> registerNode :: IORefEnv -> Address -> IO ()
> registerNode env address =
>   A.atomicModifyIORefCAS_ env $ \e ->
>     e { eNodes = address:eNodes e }

> -- | Determine if a given blockchain is valid
> isValidChain :: Chain -> Either T.Text ()
> isValidChain bc = do
>   CM.when (null bc)                                   (Left "empty blockchain")
>   CM.when (length bc == 1 && head bc /= genesisBlock) (Left "invalid genesis block")
>   -- `sequence_` causes function to return on/with first `Left` value
>   sequence_ (map isValidBlock (Prelude.zip3 [1 .. ] bc (Prelude.tail bc)))
>   return ()

> -- | Given a valid previous block and a block to check.
> --   Returns `Just ()` if valid.
> --   Otherwise `Left reason`.
> isValidBlock :: (Int, Block, Block) -> Either T.Text ()
> isValidBlock (i, validBlock, checkBlock) = do
>   CM.when   (hashBlock validBlock /= bPreviousHash checkBlock)
>             (Left ("invalid bPrevHash at " <> T.pack (show i)))
>   CM.unless (validProof (bProof validBlock) (bProof checkBlock) (bPreviousHash validBlock))
>             (Left ("invalid bProof at "    <> T.pack (show i)))
>   return ()

> -- | CONSENSUS ALGORITHM
> --   Resolves conflicts by replacing chain with longest one in the network.
> --   Returns True if chain was replaced.
> resolveConflicts :: IORefEnv -> IO Bool
> resolveConflicts env = do
>   e <- IOR.readIORef env
>   chains <- CM.forM (eNodes e) $ \n -> do
>     manager  <- HTTP.newManager HTTP.defaultManagerSettings
>     request  <- HTTP.parseRequest ("http://" <> T.unpack n <> "/chain")
>     response <- HTTP.httpLbs request manager
>     if HTTP.statusCode (HTTP.responseStatus response) == 200 then
>       return (read (BSLC8.unpack (HTTP.responseBody response)))
>     else
>       return []
>   let chain' = foldr (\a b -> if length a > length b then a else b) (eChain e) chains
>   if eChain e /= chain' then
>     case isValidChain chain' of
>       Right _ -> do
>         A.atomicModifyIORefCAS_ env $ \e0 -> e0 { eChain = chain' }
>         return True
>       Left err -> do
>         Log.infoM lBC ("resolveConflicts: invalid chain " <> T.unpack err)
>         return False
>   else
>     return False

> -- | Create a new Block and add it to the Chain
> --   previousHash: Hash of previous Block
> --   proof: The proof given by the Proof of Work algorithm
> newBlock :: IORefEnv -> BHash -> Proof -> IO Block
> newBlock env pHash proof = do
>   A.atomicModifyIORefCAS_ env $ \e -> do
>     let b = Block
>          { bPreviousHash = pHash -- previous_hash or self.hash(self.chain[-1]),
>          , bIndex        = length (eChain e)
>          , bTimestamp    = "timestamp" -- TODO
>          , bTransactions = eCurrentTransactions e
>          , bProof        = proof
>          }
>     e { eCurrentTransactions = [], eChain = eChain e ++ [b] } -- TODO
>   getLastBlock env

> -- | Creates a new transaction to go into the next mined Block
> --   Returns index of the Block that will hold the transaction. -- TODO : necessary?
> newTransaction :: IORefEnv -> Transaction -> IO BIndex -- TODO rename addTransaction
> newTransaction env tx = do
>   A.atomicModifyIORefCAS_ env $ \e ->
>     e { eCurrentTransactions = eCurrentTransactions e ++ [tx] } -- TODO
>   c <- IOR.readIORef env
>   return (length (eChain c))

> -- | Creates a SHA-256 hash of a Block
> hash :: BS.ByteString -> BHash
> hash = SHA.hash
>
> hashBlock :: Block -> BHash
> hashBlock = hash . BSC8.pack . show

> -- | Simple Proof of Work Algorithm:
> --   - Find a number p' such that hash(pp') contains leading 4 zeroes
> --   - Where p is the previous proof, and p' is the new proof
> --   :param last_block: <dict> last Block
> --   :return: <int>
> proofOfWork :: Block -> Proof
> proofOfWork lastBlock =
>   let lastProof = bProof lastBlock
>       lastHash  = hash (BSC8.pack (show lastBlock))
>   in foldr (\proof acc -> if validProof lastProof proof lastHash then proof else acc) 0 [0 .. ]

> -- | Validates the Proof
> --   :param last_proof: <int> Previous Proof
> --   :param proof: <int> Current Proof
> --   :param last_hash: <str> The hash of the Previous Block
> --   :return: <bool> True if correct, False if not.
> validProof :: Proof -> Proof -> BHash -> Bool
> validProof lastProof proof0 lastHash =
>  let guess = BSC8.pack (show lastProof) <> BSC8.pack (show proof0) <> lastHash
>      ghash = Hex.hex (hash guess)
>   in BS.take 4 ghash == "0000"

> getLastBlock :: IORefEnv -> IO Block
> getLastBlock env = do
>   c <- IOR.readIORef env
>   return (last (eChain c))

> mine :: IORefEnv -> IO Block
> mine env = do
>   lastBlock <- getLastBlock env
>   let proof = proofOfWork lastBlock
>   tn <- fmap eThisNode (IOR.readIORef env)
>   -- miner receives a reward for finding the proof.
>   -- sender "0" signifies minted a new coin.
>   let tx = "sender=0;recipient=" <> tn <> ";amount=1"
>   newTransaction env tx
>   -- add new Block to chain
>   let pHash = hashBlock lastBlock
>   newBlock env pHash proof

> run :: [String] -> IO ()
> run args = do
>   Log.updateGlobalLogger lBC (Log.setLevel Log.DEBUG)
>   let port = case args of
>        ("-p":p:_) -> read p
>        ("-h":_)   -> error "'-p', '--port', default=5000, 'port to listen on'"
>        _          -> 3000
>   env <- initialize (T.pack (show port))
>   run' port env

> run' :: Int -> IORefEnv -> IO ()
> run' httpPort env = do
>   Log.infoM lBC ("starting httpServer on port " <> show httpPort)
>   tn <- fmap (T.unpack . eThisNode) (IOR.readIORef env)
>   Wai.run httpPort $ Wai.logStdoutDev $
>     \req s -> do
>       Log.infoM lBC (tn <> " received request " <> show req)
>       case Wai.rawPathInfo req of
>         "/mine" -> do
>           b <- fmap show (mine env)
>           let rsp = "mine " <> b
>           send s tn HTTP.status200 rsp
>         "/tx" -> -- POST
>           case getQ req of
>             Right tx -> do
>               i <- newTransaction env (TE.decodeUtf8 tx)
>               let rsp = "/tx " <> show tx <> " " <> show i
>               send s tn HTTP.status200 rsp
>             Left x ->
>               badQ s tn "/tx" x
>         "/chain" -> do
>           e <- IOR.readIORef env
>           let chain = eChain e
>               len   = length chain
>               rsp = "chain " <> show len <> " " <> show chain
>           send s tn HTTP.status200 rsp
>         "/register" ->
>           case getQ req of
>             Right n -> do
>               registerNode env (TE.decodeUtf8 n)
>               let rsp = "/register " <> show n
>               send s tn HTTP.status200 rsp
>             Left x ->
>               badQ s tn "/register" x
>         "/resolve" -> do
>           b <- resolveConflicts env
>           let rsp = "/resolve " <> show b
>           send s tn HTTP.status200 rsp
>         "/env" -> do
>           e <- IOR.readIORef env
>           send s tn HTTP.status200 (show e)
>         x -> do
>           let rsp = "received unknown " <> BSC8.unpack x
>           send s tn HTTP.status400 rsp
>  where
>   send s tn sc r = do
>     let rsp = tn <> " " <> r
>     Log.infoM lBC rsp
>     s $ Wai.responseBuilder sc [] (BSB.byteString (BSC8.pack rsp))
>   getQ r =
>     case Wai.queryString r of ((q,_):_) -> Right q; x -> Left x
>   badQ s tn msg q = do
>     let rsp = tn <> " " <> msg <> " with bad query" <> show q
>     Log.infoM lBC rsp
>     send s tn HTTP.status400 rsp
