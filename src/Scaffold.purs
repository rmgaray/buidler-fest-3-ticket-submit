-- | This module contains a minimal contract that only prints public key
-- | info to the console.
module Scaffold (contract) where

-- we import unqualified for convenience

import Cardano.Plutus.DataSchema
import Cardano.Transaction.Builder
import Contract.Prelude

import Cardano.AsCbor (decodeCbor, encodeCbor)
import Cardano.FromData (class FromData, fromData, genericFromData)
import Cardano.ToData (class ToData, genericToData, toData)
import Cardano.Types (Asset(..), BigInt, ScriptHash, TransactionInput(..), TransactionOutput(..), TransactionUnspentOutput(..), _body, _ttl)
import Cardano.Types.AssetName as AssetName
import Cardano.Types.BigInt as BigInt
import Cardano.Types.BigNum as BigNum
import Cardano.Types.Int as Int
import Cardano.Types.OutputDatum (OutputDatum(..))
import Cardano.Types.PlutusData (pprintPlutusData)
import Cardano.Types.RedeemerDatum as RedeemerDatum
import Cardano.Types.TransactionHash (TransactionHash)
import Cardano.Types.Value (pprintValue)
import Cardano.Types.Value as Value
import Contract.Address as Address
import Contract.Log (logInfo, logInfo')
import Contract.Monad (Contract, liftContractE, liftContractM, throwContractError)
import Contract.Prim.ByteArray as ByteArray
import Contract.Time (getEraSummaries, getSystemStart, posixTimeToSlot)
import Contract.Transaction (CtlBalancerContext, awaitTxConfirmed, defaultBalancerWithErr, signTransaction, submit)
import Contract.Utxos as Utxos
import Data.Array as Array
import Data.DateTime.Instant (unInstant)
import Data.Lens ((%~), (.~))
import Data.Map as Map
import Data.UInt as UInt
import Effect.Now (now)

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
  scriptRefAddress <- Address.addressFromBech32 "addr1wy8ccvgzslpjf9yhrprvmqulpmjpkpxf8c0hvtjwvw8n6pqdcrnp0"
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
  -- Script ref
  issuerScriptRefTxId :: TransactionHash <- liftContractM "Could not decode transaction id of scriptref"
    $ decodeCbor
    $ wrap
    $ ByteArray.hexToByteArrayUnsafe "31596ecbdcf102c8e5c17e75c65cf9780996285879d18903f035964f3a7499a8"
  let
    issuerScriptRefInput = TransactionInput { index: UInt.fromInt 0, transactionId: issuerScriptRefTxId }
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
  logInfo' "(2) Find scriptRef UTxO"
  (Tuple _ issuerScriptRefOutput) <-
    liftContractM "Could not find scriptRef UTxO"
      =<< (Array.head <<< Map.toUnfoldable <<< Map.filterKeys (_ == issuerScriptRefInput))
      <$> Utxos.utxosAt scriptRefAddress
  logInfo' $ "Issuer script ref UTxO found!"
  -----------------------------------------------------------------------------
  logInfo' "(3) Compute new datum and ticket name"
  let ticketCounter' = TicketCounterDatum { count: currentCount + BigInt.fromInt 1 }
  ticketAssetName <- liftContractM "Could not decode new ticket asset name" do
    nameBa <- ByteArray.byteArrayFromAscii $ "TICKET" <> show currentCount
    AssetName.mkAssetName nameBa
  ----------------------------------------------------------------------------
  logInfo' "(4) Compute the TTL of the transaction"

  currentTime :: Number <- (unwrap <<< unInstant) <$> liftEffect now
  currentTimeBigInt :: BigInt <- liftContractM "Could not parse current time" $ BigInt.fromNumber currentTime
  eraSummaries <- getEraSummaries
  systemStart <- getSystemStart
  ttl <- liftContractE $ posixTimeToSlot eraSummaries systemStart (wrap $ currentTimeBigInt + BigInt.fromInt (1_000 * 60 * 10))
  logInfo' "TTL computed!"
  -----------------------------------------------------------------------------
  logInfo' "(5) Build transaction"
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
          (ScriptReference issuerScriptRefInput ReferenceInput)
          RedeemerDatum.unit
          Nothing
      , Pay $ TransactionOutput
          { address: issuerAddress
          , amount: Value.singleton beaconScriptHash beaconAssetName BigNum.one
          , datum: Just $ OutputDatum $ toData $ ticketCounter'
          , scriptRef: Nothing
          }
      , -- We mint the ticket token (which will be placed as change into our wallet)
        MintAsset
          ticketScriptHash
          ticketAssetName
          Int.one
          (PlutusScriptCredential (ScriptReference issuerScriptRefInput ReferenceInput) RedeemerDatum.unit)
      ]

  txNoTtl <-
    either
      (throwContractError <<< explainTxBuildError)
      pure
      $ buildTransaction steps
  -- We have to set a validity interval to make it succeed!
  let tx = txNoTtl # _body %~ _ttl .~ Just ttl

  logInfo' "Transaction built succesfully!"
  -----------------------------------------------------------------------------
  logInfo' "(5) Balance the Tx"

  let
    balancerContext :: CtlBalancerContext
    balancerContext =
      { balancerConstraints: mempty
      , extraUtxos: Map.union issuerUtxos (Map.singleton issuerScriptRefInput issuerScriptRefOutput)
      }

  balancedTx <- liftContractE =<< defaultBalancerWithErr tx balancerContext
  logInfo' "Transaction balanced succesfully!"

  logInfo' $ show $ encodeCbor balancedTx
  -----------------------------------------------------------------------------
  logInfo' "(6) Sign and submit the Tx"

  signedTx <- signTransaction balancedTx

  txHash <- submit signedTx
  logInfo' $ "Awaiting tx with id " <> show txHash
  awaitTxConfirmed txHash

  logInfo' "Transaction confirmed! Ticket acquired."

