-- | This module, when bundled, executes the default contract in the browser or
-- | the Node.
module Scaffold.Main (main) where

import Cardano.Transaction.Balancer
import Contract.Prelude

import BrowserFormatter (browserFormatter)
import Cardano.Transaction.Balancer.Types (Logging, BalanceTxM)
import Cardano.Types (Transaction(..), TransactionUnspentOutput(..))
import Contract.Config as Contract.Config
import Contract.Monad as Contract.Monad
import Contract.Transaction (CtlBalancerContext, defaultBalancer)
import Control.Monad.Except.Trans (runExceptT)
import Control.Monad.Reader.Trans (runReaderT)
import Data.Map as Map
import Effect.Aff (launchAff_)
import Effect.Exception (throw)
import Scaffold as Scaffold

foreign import blockfrostApiKey :: String

main :: Effect Unit
main = launchAff_ $ do
  Contract.Monad.runContract contractParams Scaffold.contract

contractParams :: Contract.Config.ContractParams
contractParams =
  Contract.Config.mainnetConfig
    { backendParams = Contract.Config.mkBlockfrostBackendParams
        { blockfrostApiKey: Just blockfrostApiKey
        , blockfrostConfig: Contract.Config.blockfrostPublicMainnetServerConfig
        , confirmTxDelay: Nothing
        }
    , walletSpec =
        Just $ Contract.Config.ConnectToGenericCip30 "eternl" { cip95: false }
    , customLogger = Just browserFormatter
    }

-- -- CtlBalancer
-- -- TxBalancer Contract err CtlBalancerContext
-- -- Transaction -> CtlBalancerContext -> Contract (Either err Transaction)
-- runBalancer' :: forall a. Transaction -> CtlBalancerContext -> Aff Transaction
-- runBalancer' tx context = either throw' pure =<< (flip runReaderT balanceParams $ runExceptT $ defaultBalancer tx context)
--   where
--   throw' = liftEffect <<< throw <<< show

-- balanceParams :: Logging
-- balanceParams = { customLogger: Just browserFormatter, logLevel: Trace }

