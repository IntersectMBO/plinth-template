{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE Strict                     #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_GHC -fno-full-laziness #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-spec-constr #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}
{-# OPTIONS_GHC -fno-unbox-strict-fields #-}
{-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.1.0 #-}

module AuctionMintingPolicy where

import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (PubKeyHash, ScriptContext (..), TxInfo (..), mintValueMinted)
import PlutusLedgerApi.V1.Value (flattenValue)
import PlutusLedgerApi.V3.Contexts (ownCurrencySymbol, txSignedBy)
import PlutusTx
import PlutusTx.Prelude qualified as PlutusTx

type AuctionMintingParams = PubKeyHash
type AuctionMintingRedeemer = ()

{-# INLINEABLE auctionTypedMintingPolicy #-}
auctionTypedMintingPolicy ::
  AuctionMintingParams ->
  ScriptContext ->
  Bool
auctionTypedMintingPolicy pkh ctx@(ScriptContext txInfo _ _) =
  txSignedBy txInfo pkh PlutusTx.&& mintedExactlyOneToken
  where
    -- Note: Redeemer is not needed for this minting policy, so we don't extract it
    mintedExactlyOneToken = case flattenValue (mintValueMinted (txInfoMint txInfo)) of
      [(currencySymbol, _tokenName, quantity)] ->
        currencySymbol PlutusTx.== ownCurrencySymbol ctx PlutusTx.&& quantity PlutusTx.== 1
      _ -> False

auctionUntypedMintingPolicy ::
  AuctionMintingParams ->
  BuiltinData ->
  PlutusTx.BuiltinUnit
auctionUntypedMintingPolicy pkh ctx =
  PlutusTx.check
    ( auctionTypedMintingPolicy
        pkh
        (PlutusTx.unsafeFromBuiltinData ctx)
    )

auctionMintingPolicyScript ::
  AuctionMintingParams ->
  CompiledCode (BuiltinData -> PlutusTx.BuiltinUnit)
auctionMintingPolicyScript pkh =
  $$(PlutusTx.compile [||auctionUntypedMintingPolicy||])
    `PlutusTx.unsafeApplyCode` PlutusTx.liftCode plcVersion110 pkh
