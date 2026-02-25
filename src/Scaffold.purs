-- | This module contains a minimal contract that only prints public key
-- | info to the console.
module Scaffold (contract) where

import Cardano.Plutus.DataSchema
import Cardano.Transaction.Balancer
import Cardano.Transaction.Builder
import Contract.Prelude

import Cardano.AsCbor (decodeCbor)
import Cardano.FromData (class FromData, fromData, genericFromData)
import Cardano.ToData (class ToData, genericToData, toData)
import Cardano.Transaction.Balancer.FakeOutput (fakeOutputWithValue)
import Cardano.Types (Asset(..), AssetClass(..), BigInt, Coin(..), ScriptHash(..), Transaction(..), TransactionInput(..), TransactionOutput(..), TransactionUnspentOutput(..))
import Cardano.Types.AssetName as AssetName
import Cardano.Types.BigInt as BigInt
import Cardano.Types.BigNum as BigNum
import Cardano.Types.Int as Int
import Cardano.Types.OutputDatum (OutputDatum(..))
import Cardano.Types.PlutusData (pprintPlutusData)
import Cardano.Types.RedeemerDatum as RedeemerDatum
import Cardano.Types.ScriptHash as ScriptHash
import Cardano.Types.TransactionHash (TransactionHash(..))
import Cardano.Types.TransactionOutput as TransactionOutput
import Cardano.Types.Value (pprintValue)
import Cardano.Types.Value as Value
import Contract.Address as Address
import Contract.Log (logInfo, logInfo')
import Contract.Monad (Contract, liftContractE, liftContractM, throwContractError)
import Contract.Prim.ByteArray as ByteArray
import Contract.Transaction (CtlBalancerContext, defaultBalancer, defaultBalancerWithErr)
import Contract.Utxos as Utxos
import Data.Array as Array
import Data.Map as Map
import Data.UInt as UInt

-- | The datum type of the ticket counter
data TicketCounterDatum = TicketCounterDatum
  { count :: BigInt
  }

-- We derive FromData/ToData instances using Generic and a PlutusSchema
derive instance genericTicketCounterDatum :: Generic TicketCounterDatum _

instance
  HasPlutusSchema TicketCounterDatum
    ( "TicketCounterDatum"
        := ("count" := I BigInt :+ PNil)
        @@ Z
        :+ PNil
    )

instance FromData TicketCounterDatum where
  fromData = genericFromData

instance ToData TicketCounterDatum where
  toData = genericToData

instance Show TicketCounterDatum where
  show = genericShow

-- We don't need to define the redeemer types because (for our use case) they
-- are all encoded identically to unit.

-- | The contract returns the transaction + a fake output that can be used for testing
contract :: Contract Unit
contract = do
  logInfo' "Beginning Cardano Buidler Fest #3 registration ..."
  -----------------------------------------------------------------------------
  logInfo' "(0) Parse addresses, policies, assets, etc."
  -- Addresses
  issuerAddress <- Address.addressFromBech32 "addr1wywecz65rtwrqrqemhrtn7mrczl7x2c4pqc9hfjmsa3dc7cr5pvqw"
  treasuryAddress <- Address.addressFromBech32 "addr1qx0decp93g2kwym5cz0p68thamd2t9pehlxqe02qae5r6nycv42qmjppm2rr8fj6qlzfhm6ljkd5f0tjlgudtmt5kzyqmy8x82"
  -- Policies
  beaconScriptHash :: ScriptHash <- liftContractM "Could not decode beacon policy"
    $ decodeCbor
    $ wrap
    $ ByteArray.hexToByteArrayUnsafe "e1ddde8138579e255482791d9fba0778cb1f5c7b435be7b3e42069de"
  ticketScriptHash :: ScriptHash <- liftContractM "Could not decode ticket policy"
    $ decodeCbor
    $ wrap
    $ ByteArray.hexToByteArrayUnsafe "1d9c0b541adc300c19ddc6b9fb63c0bfe32b1508305ba65b8762dc7b"
  -- Asset names
  beaconAssetName <- liftContractM "Could not decode beacon asset name"
    $ AssetName.mkAssetName
    $ ByteArray.hexToByteArrayUnsafe "425549444c45524645535432303236"
  let
    beaconAsset = Asset beaconScriptHash beaconAssetName
    beaconAssetClass = AssetClass beaconScriptHash beaconAssetName
  -- Script ref
  issuerScriptRefTxId :: TransactionHash <- liftContractM "Could not decode transaction id of scriptref"
    $ decodeCbor
    $ wrap
    $ ByteArray.hexToByteArrayUnsafe "31596ecbdcf102c8e5c17e75c65cf9780996285879d18903f035964f3a749a8"
  let issuerScriptRef = TransactionInput { index: UInt.fromInt 0, transactionId: issuerScriptRefTxId }
  logInfo' "All addresses, policies, etc. parsed!"
  -----------------------------------------------------------------------------
  logInfo' "(1) Find issuer UTxO, parse TicketCounter datum"
  issuerUtxos <- Utxos.utxosAt issuerAddress
  let
    containsBeaconToken :: TransactionOutput -> Boolean
    containsBeaconToken = (_ == BigNum.one) <<< Value.valueOf beaconAsset <<< _.amount <<< unwrap
  stateTxIn /\ stateTxOut <- liftContractM "Could not find state UTxO at issuer address"
    $ Array.head
    $ Map.toUnfoldableUnordered
    $ Map.filter containsBeaconToken issuerUtxos
  let
    stateUnspentOutput = TransactionUnspentOutput { input: stateTxIn, output: stateTxOut }

  ticketCounterPd <- liftContractM "No inline datum found in TicketCounter UTxO" do
    outputDatum <- (unwrap stateTxOut).datum
    case outputDatum of
      OutputDatumHash _ -> Nothing
      OutputDatum pd -> Just pd

  ticketCounter@(TicketCounterDatum { count: currentCount }) :: TicketCounterDatum <- liftContractM "Could not parse TicketCounter datum" $ fromData ticketCounterPd

  logInfo' "Issuer UTxO found!"
  logInfo' $ "Ticket counter: " <> show ticketCounter
  logInfo (pprintPlutusData ticketCounterPd) "Ticket counter"
  logInfo (pprintValue (unwrap stateTxOut).amount) "Value in issuer UTxO"
  -----------------------------------------------------------------------------
  logInfo' "(2) Compute new datum and ticket name "
  let ticketCounter' = TicketCounterDatum { count: currentCount + BigInt.fromInt 1 }
  ticketAssetName <- liftContractM "Could not decode new ticket asset name" do
    nameBa <- ByteArray.byteArrayFromAscii $ "TICKET" <> show currentCount
    AssetName.mkAssetName nameBa
  -----------------------------------------------------------------------------
  logInfo' "(3) Build transaction"
  let
    steps :: Array TransactionBuilderStep
    steps =
      [
        -- We pay to the treasury the cost of the ticket
        Pay $ TransactionOutput
          { address: treasuryAddress
          , amount: Value.lovelaceValueOf $ BigNum.fromInt 500_000_000
          , datum: Nothing
          , scriptRef: Nothing
          }
      , -- We increase the value of the ticket counter
        SpendOutput stateUnspentOutput $ Just $ PlutusScriptOutput
          (ScriptReference issuerScriptRef ReferenceInput)
          RedeemerDatum.unit
          Nothing
      , Pay $ TransactionOutput
          { address: issuerAddress
          , amount: Value.empty
          , datum: Just $ OutputDatum $ toData $ ticketCounter'
          , scriptRef: Nothing
          }
      , -- We mint the ticket token (which will be placed as change into our wallet)
        MintAsset
          ticketScriptHash
          ticketAssetName
          Int.one
          (PlutusScriptCredential (ScriptReference issuerScriptRef ReferenceInput) RedeemerDatum.unit)
      ]

  tx <-
    either
      (throwContractError <<< explainTxBuildError)
      pure
      $ buildTransaction steps

  logInfo' "Transaction built succesfully!"
  log "(4) Create fake output for testing  and balance the Tx"
  ticketAdaAmount <- liftContractM "Could not multiply 500 by 1M" $
    BigNum.mul (BigNum.fromInt 500) (BigNum.fromInt 1_000_000)

  fakeInputTxId :: TransactionHash <- liftContractM "Could not decode fake transaction id for fake input"
    $ decodeCbor
    $ wrap
    $ ByteArray.hexToByteArrayUnsafe "bf54c9a70c4e81ae55813df4b5caa0d28080aad618989a0aef167960f6655b2"

  let
    fakeOutput1 = fakeOutputWithValue $ Value.lovelaceValueOf ticketAdaAmount
    fakeOutput2 = fakeOutputWithValue $ Value.lovelaceValueOf $ BigNum.fromInt 5_000_000
    fakeInput1 = TransactionInput { index: UInt.fromInt 0, transactionId: fakeInputTxId }
    fakeInput2 = TransactionInput { index: UInt.fromInt 1, transactionId: fakeInputTxId }

    balancerContext :: CtlBalancerContext
    balancerContext =
      { balancerConstraints: mempty
      , extraUtxos: Map.union (Map.singleton fakeInput1 fakeOutput1) (Map.singleton fakeInput2 fakeOutput2)
      }

  balancedTx <- liftContractE =<< defaultBalancerWithErr tx balancerContext
  logInfo' "Transaction balanced succesfully!"

  pure unit

