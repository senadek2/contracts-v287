// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./LiquidatefCash.sol";
import "../AccountContextHandler.sol";
import "../valuation/ExchangeRate.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../portfolio/PortfolioHandler.sol";
import "../balances/BalanceHandler.sol";
import "../../external/FreeCollateralExternal.sol";
import "../../math/SafeInt256.sol";

library LiquidationHelpers {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;

    /// @notice Settles accounts and returns liquidation factors for all of the liquidation actions.
    function preLiquidationActions(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency
    )
        internal
        returns (
            AccountContext memory,
            LiquidationFactors memory,
            PortfolioState memory
        )
    {
        require(localCurrency != 0);
        // Collateral currency must be unset or not equal to the local currency
        require(collateralCurrency == 0 || collateralCurrency != localCurrency);
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        ) =
            FreeCollateralExternal.getLiquidationFactors(
                liquidateAccount,
                localCurrency,
                collateralCurrency
            );

        PortfolioState memory portfolioState =
            PortfolioState({
                storedAssets: portfolio,
                newAssets: new PortfolioAsset[](0),
                lastNewAssetIndex: 0,
                storedAssetLength: portfolio.length
            });

        return (accountContext, factors, portfolioState);
    }

    /// @notice We allow liquidators to purchase up to Constants.MAX_LIQUIDATION_PORTION percentage of collateral
    /// assets during liquidation to recollateralize an account as long as it does not also put the account
    /// further into negative free collateral (i.e. constraints on local available and collateral available).
    /// Additionally, we allow the liquidator to specify a maximum amount of collateral they would like to
    /// purchase so we also enforce that limit here.
    function calculateMaxLiquidationAmount(
        int256 initialAmountToLiquidate,
        int256 maxTotalBalance,
        int256 userSpecifiedMaximum
    ) internal pure returns (int256) {
        int256 maxAllowedAmount =
            maxTotalBalance.mul(Constants.MAX_LIQUIDATION_PORTION).div(
                Constants.PERCENTAGE_DECIMALS
            );

        int256 result = initialAmountToLiquidate;

        if (initialAmountToLiquidate > maxTotalBalance) {
            result = maxTotalBalance;
        }

        if (initialAmountToLiquidate < maxAllowedAmount) {
            // Allow the liquidator to go up to the max allowed amount
            result = maxAllowedAmount;
        }

        if (userSpecifiedMaximum > 0 && result > userSpecifiedMaximum) {
            // Do not allow liquidation above the user specified maximum
            result = userSpecifiedMaximum;
        }

        return result;
    }

    /// @dev Calculates factors when liquidating across two currencies
    function calculateCrossCurrencyBenefitAndDiscount(LiquidationFactors memory factors)
        internal
        pure
        returns (int256, int256)
    {
        int256 liquidationDiscount;
        // This calculation returns the amount of benefit that selling collateral for local currency will
        // be back to the account.
        int256 benefitRequired =
            factors
                .collateralETHRate
                .convertETHTo(factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
            // If the haircut is zero here the transaction will revert, which is the correct result. Liquidating
            // collateral with a zero haircut will have no net benefit back to the liquidated account.
                .div(factors.collateralETHRate.haircut);

        if (
            factors.collateralETHRate.liquidationDiscount > factors.localETHRate.liquidationDiscount
        ) {
            liquidationDiscount = factors.collateralETHRate.liquidationDiscount;
        } else {
            liquidationDiscount = factors.localETHRate.liquidationDiscount;
        }

        return (benefitRequired, liquidationDiscount);
    }

    /// @notice Calculates the local to purchase in cross currency liquidations. Ensures that local to purchase
    /// is not so large that the account is put further into debt.
    function calculateLocalToPurchase(
        LiquidationFactors memory factors,
        int256 liquidationDiscount,
        int256 collateralPresentValue,
        int256 collateralBalanceToSell
    ) internal pure returns (int256, int256) {
        // Converts collateral present value to the local amount along with the liquidation discount.
        // localPurchased = collateralToSell / (exchangeRate * liquidationDiscount)
        int256 localToPurchase =
            collateralPresentValue
                .mul(Constants.PERCENTAGE_DECIMALS)
                .mul(factors.localETHRate.rateDecimals)
                .div(ExchangeRate.exchangeRate(factors.localETHRate, factors.collateralETHRate))
                .div(liquidationDiscount);

        if (localToPurchase > factors.localAvailable.neg()) {
            // If the local to purchase will put the local available into negative territory we
            // have to cut the collateral purchase amount back. Putting local available into negative
            // territory will force the liquidated account to incur more debt.
            collateralBalanceToSell = collateralBalanceToSell.mul(factors.localAvailable.neg()).div(
                localToPurchase
            );

            localToPurchase = factors.localAvailable.neg();
        }

        return (collateralBalanceToSell, localToPurchase);
    }

    function finalizeLiquidatorLocal(
        address liquidator,
        uint256 localCurrencyId,
        int256 netLocalFromLiquidator,
        int256 netLocalPerpetualTokens
    ) internal returns (AccountContext memory) {
        // Liquidator must deposit netLocalFromLiquidator, in the case of a repo discount then the
        // liquidator will receive some positive amount
        Token memory token = TokenHandler.getToken(localCurrencyId, false);
        AccountContext memory liquidatorContext =
            AccountContextHandler.getAccountContext(liquidator);
        // TODO: maybe reuse these...
        BalanceState memory liquidatorLocalBalance;
        liquidatorLocalBalance.loadBalanceState(liquidator, localCurrencyId, liquidatorContext);

        if (token.hasTransferFee && netLocalFromLiquidator > 0) {
            // If a token has a transfer fee then it must have been deposited prior to the liquidation
            // or else we won't be able to net off the correct amount. We also require that the account
            // does not have debt so that we do not have to run a free collateral check here
            require(
                liquidatorLocalBalance.storedCashBalance >= netLocalFromLiquidator &&
                    liquidatorContext.hasDebt == 0x00,
                "Token transfer unavailable"
            );
            liquidatorLocalBalance.netCashChange = netLocalFromLiquidator.neg();
        } else {
            liquidatorLocalBalance.netAssetTransferInternalPrecision = netLocalFromLiquidator;
        }
        liquidatorLocalBalance.netNTokenTransfer = netLocalPerpetualTokens;
        liquidatorLocalBalance.finalize(liquidator, liquidatorContext, false);

        return liquidatorContext;
    }

    function finalizeLiquidatorCollateral(
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 collateralCurrencyId,
        int256 netCollateralToLiquidator,
        int256 netCollateralPerpetualTokens,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) internal returns (AccountContext memory) {
        // TODO: maybe reuse these...
        BalanceState memory balance;
        balance.loadBalanceState(liquidator, collateralCurrencyId, liquidatorContext);

        if (withdrawCollateral) {
            balance.netAssetTransferInternalPrecision = netCollateralToLiquidator.neg();
        } else {
            balance.netCashChange = netCollateralToLiquidator;
        }
        balance.netNTokenTransfer = netCollateralPerpetualTokens;
        balance.finalize(liquidator, liquidatorContext, redeemToUnderlying);

        return liquidatorContext;
    }

    function finalizeLiquidatedLocalBalance(
        address liquidateAccount,
        uint256 localCurrency,
        AccountContext memory accountContext,
        int256 netLocalFromLiquidator
    ) internal {
        BalanceState memory balance;
        balance.loadBalanceState(liquidateAccount, localCurrency, accountContext);
        balance.netCashChange = netLocalFromLiquidator;
        balance.finalize(liquidateAccount, accountContext, false);
    }

    function transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        LiquidatefCash.fCashContext memory c
    ) internal {
        PortfolioAsset[] memory assets =
            _makeAssetArray(fCashCurrency, fCashMaturities, c.fCashNotionalTransfers);

        TransferAssets.placeAssetsInAccount(liquidator, liquidatorContext, assets);
        TransferAssets.invertNotionalAmountsInPlace(assets);

        if (c.accountContext.bitmapCurrencyId == 0) {
            c.portfolio.addMultipleAssets(assets);
            AccountContextHandler.storeAssetsAndUpdateContext(
                c.accountContext,
                liquidateAccount,
                c.portfolio,
                false // Although this is liquidation, we should not allow past max assets here
            );
        } else {
            BitmapAssetsHandler.addMultipleifCashAssets(liquidateAccount, c.accountContext, assets);
        }
    }

    function _makeAssetArray(
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        int256[] memory fCashNotionalTransfers
    ) private pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        for (uint256 i; i < assets.length; i++) {
            assets[i].currencyId = fCashCurrency;
            assets[i].assetType = Constants.FCASH_ASSET_TYPE;
            assets[i].notional = fCashNotionalTransfers[i];
            assets[i].maturity = fCashMaturities[i];
        }

        return assets;
    }
}